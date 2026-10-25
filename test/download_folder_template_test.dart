import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';

import 'support/fixed_settings.dart';

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
        DownloadItem(
          id: 'example-item',
          track: const Track(
            id: 'extension:example:track',
            name: 'Song',
            artistName: 'Track Artist',
            albumArtist: 'Album Artist',
            albumName: 'Album',
            duration: 180,
            releaseDate: '2026-05-04',
            discNumber: 2,
          ),
          service: 'example-provider',
          createdAt: DateTime.utc(2026),
        ),
      ],
    );
  }
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  test(
    'download queue creates the custom folders and sends the resolved destination',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'download-folder-template-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactorySqflitePlugin;
      addTearDown(() => databaseFactory = previousFactory);
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
      const progress = MethodChannel(
        'com.zarz.mornye/download_progress_stream',
      );
      final requests = <Map<String, dynamic>>[];
      final formatted = <String>[];
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      messenger.setMockMethodCallHandler(connectivity, (_) async => null);
      messenger.setMockMethodCallHandler(progress, (_) async => null);
      messenger.setMockMethodCallHandler(
        notifications,
        (call) async => call.method == 'initialize' ? true : null,
      );
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
        if (call.method == 'buildFilename') {
          final arguments = call.arguments as Map;
          final metadata = jsonDecode(arguments['metadata'] as String) as Map;
          expect(metadata['artist'], 'Album Artist');
          expect(metadata['date'], '2026-05-04');
          expect(metadata['disc'], 2);
          final template = arguments['template'] as String;
          formatted.add(template);
          return switch (template) {
            '{artist}' => 'Album Artist',
            '{date:%Y-%m-%d} - {album}' => '2026-05-04 - Album',
            'Disc {disc:02}' => 'Disc 02',
            _ => throw StateError('Unexpected folder component: $template'),
          };
        }
        if (call.method != 'downloadByStrategy') return null;
        requests.add(
          (jsonDecode(call.arguments as String) as Map).cast<String, dynamic>(),
        );
        // Stop before network transfer; this test exercises queue path planning.
        return {
          'success': false,
          'error': 'Fixture unavailable',
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
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              AppSettings(
                downloadDirectory: directory.path,
                embedMetadata: false,
                saveDownloadHistory: false,
                folderOrganization: 'custom',
                folderPathTemplate:
                    '{artist}/{date:%Y-%m-%d} - {album}/Disc {disc:02}',
              ),
            ),
          ),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(_Queue.new),
        ],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier);
      addTearDown(() async {
        await queue.flushQueuePersistence();
        await (await AppStateDatabase.instance.database).close();
      });
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
      expect(formatted, [
        '{artist}',
        '{date:%Y-%m-%d} - {album}',
        'Disc {disc:02}',
      ]);
      expect(requests, hasLength(1));
      final expected = p.join(
        directory.path,
        'Album Artist',
        '2026-05-04 - Album',
        'Disc 02',
      );
      expect(requests.single['output_dir'], expected);
      expect(requests.single, isNot(contains('album_folder_template')));
      expect(await Directory(expected).exists(), isTrue);
    },
  );
}
