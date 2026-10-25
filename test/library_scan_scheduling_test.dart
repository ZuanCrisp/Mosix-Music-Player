import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/local_library_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/services/platform_bridge.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {}
}

class _Database implements LibraryDatabase {
  _Database(this.sources);

  List<LocalLibrarySource> sources;
  Future<List<LocalLibrarySource>> Function()? sourceRead;
  bool failLookup = false;
  int? countOverride;
  Future<({int inserted, int skipped})> Function()? fullReplacement;

  @override
  Future<List<LocalLibrarySource>> getSources() async =>
      sourceRead == null ? List.of(sources) : await sourceRead!();

  @override
  Future<LocalLibrarySource?> getSourceByPath(String path) async {
    if (failLookup) throw StateError('source lookup failed');
    return sources.where((source) => source.path == path).firstOrNull;
  }

  @override
  Future<int> getCount() async =>
      countOverride ??
      sources.where((source) => source.enabled && source.available).length;

  @override
  Future<({int inserted, int skipped})> replaceSourceScanFile(
    String sourceId,
    LibraryScanNDJSONFile scan, {
    required String requestId,
    required bool Function() isCancelled,
  }) => fullReplacement!();

  @override
  Future<LocalLibraryLookupIndex> getLookupIndex() async =>
      const LocalLibraryLookupIndex();

  @override
  Future<int> getSourceCount(String sourceId) async => 1;

  @override
  Future<Map<String, int>> getFileModTimes({String? sourceId}) async => {
    '/music/song.flac': 1,
  };

  @override
  Future<void> removeSource(String sourceId) async {
    sources.removeWhere((source) => source.id == sourceId);
  }

  @override
  Future<void> updateSourceState(
    String sourceId, {
    bool? enabled,
    bool? available,
    DateTime? lastScannedAt,
    DateTime? lastSeenAt,
    String? lastScanError,
    bool clearLastScanError = false,
  }) async {
    sources = [
      for (final source in sources)
        source.id == sourceId
            ? source.copyWith(enabled: enabled, available: available)
            : source,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zuancrisp.mosix/backend');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late _Database database;
  late ProviderContainer container;
  late LocalLibraryNotifier library;
  late Map<String, bool> available;
  late LocalLibraryAvailabilityProbe probe;
  late List<(String, Completer<String>)> scans;
  late List<String> calls;
  var completeOnCancel = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('library-scheduling-');
    database = _Database([
      for (final id in ['active', 'reconnect'])
        LocalLibrarySource(
          id: id,
          path: '${directory.path}/$id',
          displayName: id,
          trackCount: 1,
          available: id == 'active',
        ),
    ]);
    available = {
      for (final source in database.sources) source.path: source.available,
    };
    probe = (path, {bookmark}) async => available[path];
    scans = [];
    calls = [];
    completeOnCancel = false;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(
      notifications,
      (call) async => call.method == 'initialize' ? true : null,
    );
    messenger.setMockMethodCallHandler(backend, (call) async {
      calls.add(call.method);
      if (call.method == 'scanLibraryFolderIncremental') {
        final result = Completer<String>();
        scans.add(((call.arguments as Map)['folder_path'] as String, result));
        return result.future;
      }
      if (call.method == 'cancelLibraryScan' && completeOnCancel) {
        for (final (_, response) in scans) {
          if (!response.isCompleted) response.complete('{"cancelled":true}');
        }
      }
      return null;
    });
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localLibraryProvider.overrideWith(
          () => LocalLibraryNotifier(
            database: database,
            availabilityProbe: (path, {bookmark}) =>
                probe(path, bookmark: bookmark),
          ),
        ),
      ],
    );
    library = container.read(localLibraryProvider.notifier);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
  });

  tearDown(() async {
    container.dispose();
    for (final (_, response) in scans) {
      if (!response.isCompleted) response.complete('{"cancelled":true}');
    }
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(backend, null);
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(notifications, null);
    await directory.delete(recursive: true);
  });

  Future<void> reconnect() async {
    available['${directory.path}/reconnect'] = true;
    await library.refreshSourceAvailability(scanReconnected: true);
  }

  test('concurrent starts own one preflight and one native scan', () async {
    final pending = Completer<bool?>();
    var probes = 0;
    probe = (path, {bookmark}) {
      probes++;
      return pending.future;
    };
    final first = library.startSourceScan('active');
    await _waitFor(() => probes == 1);
    await library.startSourceScan('active');
    expect(probes, 1);
    pending.complete(true);
    await _waitFor(() => scans.length == 1);
    scans.single.$2.complete('{"cancelled":true}');
    await first;
    expect(scans, hasLength(1));
  });

  for (final dispose in [false, true]) {
    test('${dispose ? 'disposal' : 'cancel'} stops owned preflight', () async {
      final pending = Completer<bool?>();
      final started = Completer<void>();
      probe = (path, {bookmark}) {
        started.complete();
        return pending.future;
      };
      final scan = library.startSourceScan('active');
      await started.future;
      if (dispose) {
        container.dispose();
      } else {
        await library.cancelScan();
      }
      pending.complete(true);
      await scan;
      expect(scans, isEmpty);
      if (!dispose) {
        expect(container.read(localLibraryProvider).scanWasCancelled, isTrue);
        probe = (path, {bookmark}) async => available[path];
        final retry = library.startSourceScan('active');
        await _waitFor(() => scans.length == 1);
        scans.single.$2.complete('{"cancelled":true}');
        await retry;
      }
    });
  }

  for (final remove in [false, true]) {
    for (final duringProbe in [false, true]) {
      test(
        '${remove ? 'remove' : 'disable'} supersedes ${duringProbe ? 'probe' : 'source read'}',
        () async {
          final started = Completer<void>();
          final pending = Completer<bool?>();
          final snapshot = Completer<List<LocalLibrarySource>>();
          final oldSources = List.of(database.sources);
          if (duringProbe) {
            probe = (path, {bookmark}) {
              started.complete();
              return pending.future;
            };
          } else {
            database.sourceRead = () {
              started.complete();
              return snapshot.future;
            };
          }
          final scan = library.startSourceScan('active');
          await started.future;
          database.sourceRead = null;
          if (remove) {
            await library.removeSource('active');
          } else {
            await library.setSourceEnabled('active', false);
          }
          if (duringProbe) {
            pending.complete(true);
          } else {
            snapshot.complete(oldSources);
          }
          await scan;
          expect(scans, isEmpty);
        },
      );
    }
  }

  test('paused scan retains reconnect work until it completes', () async {
    final active = library.startSourceScan('active');
    await _waitFor(() => scans.length == 1);
    await library.pauseScan();
    await reconnect();
    await reconnect();
    expect(scans, hasLength(1));
    await library.resumeScan();
    scans.first.$2.complete('{"cancelled":true}');
    await active;
    await _waitFor(() => scans.length == 2);
    expect(scans.last.$1, '${directory.path}/reconnect');
    scans.last.$2.complete('{"cancelled":true}');
    await _waitFor(() => !container.read(localLibraryProvider).isScanning);
  });

  test('cancel drops queued and pending-refresh reconnect work', () async {
    final active = library.startSourceScan('active');
    await _waitFor(() => scans.length == 1);
    await reconnect();
    final pending = Completer<bool?>();
    final started = Completer<void>();
    probe = (path, {bookmark}) {
      if (path.endsWith('/reconnect') && !started.isCompleted) {
        started.complete();
        return pending.future;
      }
      return Future<bool?>.value(available[path]);
    };
    // Make a second source transition pending rather than reusing the queue.
    await database.updateSourceState('reconnect', available: false);
    final refresh = library.refreshSourceAvailability(scanReconnected: true);
    await started.future;
    await library.cancelScan();
    pending.complete(true);
    await refresh;
    scans.first.$2.complete('{"cancelled":true}');
    await active;
    await Future<void>.delayed(Duration.zero);
    expect(scans, hasLength(1));
  });

  test('disposing a paused scan cancels native ownership', () async {
    final active = library.startSourceScan('active');
    await _waitFor(() => scans.length == 1);
    await library.pauseScan();
    await reconnect();
    completeOnCancel = true;
    container.dispose();
    await active;
    expect(calls, contains('cancelLibraryScan'));
    expect(scans, hasLength(1));
  });

  test('setup failure releases admission for a later scan', () async {
    database.failLookup = true;
    await library.startScan('${directory.path}/active');
    database.failLookup = false;
    final retry = library.startSourceScan('active');
    await _waitFor(() => scans.length == 1);
    scans.single.$2.complete(jsonEncode({'cancelled': true}));
    await retry;
    expect(container.read(localLibraryProvider).isScanning, isFalse);
  });

  test(
    'cancel after incremental native commit publishes the changed index',
    () async {
      final version = container.read(localLibraryProvider).loadedIndexVersion;
      final active = library.startSourceScan('active');
      await _waitFor(() => scans.length == 1);
      await library.cancelScan();
      database.countOverride = 7;
      scans.single.$2.complete(jsonEncode({'committed': true, 'skipped': 2}));
      await active;
      final state = container.read(localLibraryProvider);
      expect(state.totalCount, 7);
      expect(state.loadedIndexVersion, greaterThan(version));
      expect(state.excludedDownloadedCount, 2);
      expect(state.scanWasCancelled, isTrue);
      expect(state.isScanning, isFalse);
    },
  );

  test('cancel after full replacement publishes the committed index', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    database.fullReplacement = () async {
      entered.complete();
      await release.future;
      database.countOverride = 7;
      return (inserted: 7, skipped: 2);
    };
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'scanLibraryFolderToNDJSONFile') {
        final path = (call.arguments as Map)['output_path'] as String;
        await File(path).writeAsString('');
        return {'path': path, 'count': 0, 'error_count': 0};
      }
      return null;
    });
    final version = container.read(localLibraryProvider).loadedIndexVersion;
    final active = library.startSourceScan('active', forceFullScan: true);
    await entered.future;
    await library.cancelScan();
    release.complete();
    await active;
    final state = container.read(localLibraryProvider);
    expect(state.totalCount, 7);
    expect(state.loadedIndexVersion, greaterThan(version));
    expect(state.excludedDownloadedCount, 2);
    expect(state.scanWasCancelled, isTrue);
    expect(state.isScanning, isFalse);
  });
}
