import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';

import '../test/support/queue_removal_benchmark.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this._path);
  final String _path;
  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

class _Settings extends SettingsNotifier {
  _Settings(this._directory);
  final String _directory;
  @override
  AppSettings build() => AppSettings(
    downloadDirectory: _directory,
    nativeDownloadWorkerEnabled: false,
  );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this._initial);
  final DownloadQueueState _initial;
  @override
  DownloadQueueState build() {
    super.build();
    return _initial;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final results = <Map<String, dynamic>>[];
  late Directory root;
  late Database db;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('queue-removal-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
      'download_queue_user_paused_v1': true,
    });
    db = await AppStateDatabase.instance.database;
    expect(db.path, '${root.path}/app_state.db');
  });
  tearDownAll(() async {
    await db.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
    binding.reportData ??= {};
    binding.reportData!['queue_removal'] = {
      'platform': Platform.operatingSystem,
      'completed_cases': results.length,
      'note':
          'Five alternating pairs of 100 consecutive completed-prefix removals. Model timing excludes persistence and rendering. Separate real notifier checks retain one publication per removal and verify private SQLite. iOS debug is correctness only.',
      'cases': results,
    };
  });
  for (final count in [1000, 10000]) {
    testWidgets('remove 100 completed items from $count', (tester) async {
      final initial = await queueRemovalFixture(count);
      queueRemovalRun(initial, incremental: false);
      queueRemovalRun(initial, incremental: true);
      final samples = <String, List<int>>{'rebuild': [], 'incremental': []};
      for (var pair = 0; pair < 5; pair++) {
        for (final incremental in pair.isEven ? [false, true] : [true, false]) {
          final result = queueRemovalRun(initial, incremental: incremental);
          samples[incremental ? 'incremental' : 'rebuild']!.add(
            result.microseconds,
          );
          expect(result.state.items, initial.items.skip(100));
          final rebuilt = DownloadQueueLookup.fromItems(result.state.items);
          expect(result.state.lookup.byItemId, rebuilt.byItemId);
          expect(result.state.lookup.byTrackId, rebuilt.byTrackId);
          expect(result.state.lookup.itemIds, rebuilt.itemIds);
          expect(
            result.state.lookup.notCompletedItemIds,
            rebuilt.notCompletedItemIds,
          );
          expect(result.state.lookup.completedCount, 0);
          expect(result.state.lookup.queuedCount, count - 100);
        }
      }
      expect(initial.items.length, count);
      results.add({'initial_count': count, 'samples': samples});
    });

    testWidgets('notifier removal publishes immediately and persists $count', (
      tester,
    ) async {
      await db.delete('download_queue_items');
      final initial = await queueRemovalFixture(count);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(root.path)),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(() => _Queue(initial)),
        ],
      );
      try {
        final queue = container.read(downloadQueueProvider.notifier);
        queue.pauseQueue(persistAcrossRestarts: false);
        await queue.flushQueuePersistence();
        expect(container.read(downloadQueueProvider).items, initial.items);
        var publications = 0;
        final subscription = container.listen(downloadQueueProvider, (
          old,
          next,
        ) {
          if (!identical(old?.items, next.items)) publications++;
        });
        final watch = Stopwatch()..start();
        for (var i = 0; i < 100; i++) {
          queue.removeItem('item-$i');
          expect(
            container.read(downloadQueueProvider).items.length,
            count - i - 1,
          );
        }
        watch.stop();
        expect(publications, 100);
        final beforeMissing = container.read(downloadQueueProvider);
        queue.removeItem('absent');
        expect(container.read(downloadQueueProvider), same(beforeMissing));
        expect(publications, 100);
        queue.removeItem('item-100');
        expect(publications, 101);
        subscription.close();
        await queue.flushQueuePersistence();
        final rows = await AppStateDatabase.instance
            .getPendingDownloadQueueRows();
        expect(rows.map((row) => row['id']), [
          for (var i = 101; i < count; i++) 'item-$i',
        ]);
        results.add({
          'initial_count': count,
          'actual_notifier_us': watch.elapsedMicroseconds,
          'publications': publications,
          'persisted_survivors': rows.length,
        });
      } finally {
        container.dispose();
      }
    });
  }
}
