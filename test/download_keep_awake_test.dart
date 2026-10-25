import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/download_keep_awake.dart';
import 'package:mornye/utils/desktop_platform.dart';

final _events = <String>[];

class _Recorder implements DownloadKeepAwake {
  @override
  Future<void> begin() async => _events.add('begin');

  @override
  Future<void> end() async => _events.add('end');
}

class _Settings extends SettingsNotifier {
  _Settings(this._directory);
  final String _directory;

  @override
  AppSettings build() => AppSettings(
    downloadDirectory: _directory,
    embedMetadata: false,
    saveDownloadHistory: false,
  );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      Extension.fromJson({
        'id': 'example-provider',
        'name': 'Example Provider',
        'enabled': true,
        'has_download_provider': true,
        'skip_metadata_enrichment': true,
      }),
    ],
  );

  @override
  Future<void> ensureInitialized() async {}
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(
      items: [
        for (final id in ['first', 'second'])
          DownloadItem(
            id: id,
            track: Track(
              id: 'extension:example:$id',
              name: id,
              artistName: 'Artist',
              albumName: 'Album',
              duration: 180,
            ),
            service: 'example-provider',
            createdAt: DateTime.utc(2026),
          ),
      ],
    );
  }
}

class _FakeTransport implements NativeBackendTransport {
  final methods = <String>[];
  bool fail = false;
  late NativeMessageListener listener;

  @override
  void init(Uint8List configJson, NativeMessageListener listener) =>
      this.listener = listener;

  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    methods.add(method);
    final kind = fail ? NativeMessageKind.error : NativeMessageKind.result;
    final payload = fail
        ? {'code': 'failure', 'message': 'no power management'}
        : method == 'beginKeepAwake';
    scheduleMicrotask(
      () => listener(id, kind, utf8.encode(jsonEncode(payload))),
    );
  }

  @override
  void subscribe(int kind) {}

  @override
  void unsubscribe(int kind) {}
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  group('backend keep awake', () {
    final transport = _FakeTransport();

    setUp(() {
      transport
        ..methods.clear()
        ..fail = false;
      debugDesktopPlatformOverride = true;
      RustFfiBackend.debugShared = RustFfiBackend(
        openTransport: () => transport,
        loadConfig: () async => const DesktopBackendConfig(
          appSupportDir: '/support',
          documentsDir: '/documents',
          tempDir: '/tmp',
        ),
      );
    });

    tearDown(() {
      debugDesktopPlatformOverride = null;
      RustFfiBackend.debugShared = null;
    });

    test('desktop begins and ends the backend sleep inhibitor', () async {
      const keepAwake = BackendDownloadKeepAwake();
      await keepAwake.begin();
      await keepAwake.end();
      expect(transport.methods, ['beginKeepAwake', 'endKeepAwake']);
    });

    test('backend failures never reach the queue', () async {
      transport.fail = true;
      const keepAwake = BackendDownloadKeepAwake();
      await keepAwake.begin();
      await keepAwake.end();
      expect(transport.methods, ['beginKeepAwake', 'endKeepAwake']);
    });

    test('mobile has no sleep inhibitor call', () async {
      debugDesktopPlatformOverride = false;
      const keepAwake = BackendDownloadKeepAwake();
      await keepAwake.begin();
      await keepAwake.end();
      expect(transport.methods, isEmpty);
    });
  });

  test('the queue holds the inhibitor from start until it stops', () async {
    final directory = await Directory.systemTemp.createTemp('keep-awake-');
    addTearDown(() => directory.delete(recursive: true));
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() => databaseFactory = previousFactory);
    debugDownloadKeepAwake = _Recorder();
    addTearDown(() => debugDownloadKeepAwake = null);
    _events.clear();
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
    });
    const backend = MethodChannel('com.zarz.mornye/backend');
    const sqlite = MethodChannel('com.tekartik.sqflite');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const notifications = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    const connectivity = MethodChannel(
      'dev.fluttercommunity.plus/connectivity_status',
    );
    const progress = MethodChannel('com.zarz.mornye/download_progress_stream');
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(connectivity, (_) async => null);
    messenger.setMockMethodCallHandler(progress, (_) async => null);
    messenger.setMockMethodCallHandler(notifications, (call) async {
      return call.method == 'initialize' ? true : null;
    });
    messenger.setMockMethodCallHandler(sqlite, (call) async {
      if (call.method == 'openDatabase') return {'id': 1};
      if (call.method != 'query') return null;
      final sql = (call.arguments as Map)['sql'] as String;
      return sql.toLowerCase().contains('pragma user_version')
          ? {
              'columns': ['user_version'],
              'rows': [
                [4],
              ],
            }
          : {'columns': <String>[], 'rows': <List<Object?>>[]};
    });
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method != 'downloadByStrategy') return null;
      final request = jsonDecode(call.arguments as String) as Map;
      _events.add('download ${request['item_id']}');
      return {
        'success': false,
        'error': 'Fixture track unavailable',
        'error_type': 'not_found',
      };
    });
    addTearDown(() {
      for (final channel in [
        backend,
        sqlite,
        paths,
        notifications,
        connectivity,
        progress,
      ]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });

    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _Settings(directory.path)),
        extensionProvider.overrideWith(_Extensions.new),
        downloadQueueProvider.overrideWith(_Queue.new),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    queue.pauseQueue(persistAcrossRestarts: false);
    await queue.flushQueuePersistence();
    final finished = Completer<void>();
    container.listen(downloadQueueProvider, (previous, next) {
      if (previous?.isProcessing == true &&
          !next.isProcessing &&
          !finished.isCompleted) {
        finished.complete();
      }
    });

    queue.resumeQueue();
    await finished.future.timeout(const Duration(seconds: 10));
    // The state flips before the stop path releases the inhibitor.
    await pumpEventQueue();

    expect(_events, ['begin', 'download first', 'download second', 'end']);
    await queue.flushQueuePersistence();
    await (await AppStateDatabase.instance.database).close();
  });
}
