import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';

import 'support/fixed_settings.dart';
import 'support/virtual_time.dart';

const _earlyTrack = Track(
  id: 'example:early',
  name: 'Immediate addition',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The waits run on virtual time, including the 350 ms persistence debounce
  // they must outlast.
  test(
    'startup restores, merges and retries only complete owned snapshots',
    () => VirtualTime().run(() async {
      SharedPreferences.setMockInitialValues({
        'app_state_migrated_queue_to_sqlite_v1': true,
        'download_queue_user_paused_v1': true,
      });
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactorySqflitePlugin;
      addTearDown(() => databaseFactory = previousFactory);
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const sqlite = MethodChannel('com.tekartik.sqflite');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        paths,
        (_) async => '/fixture/documents',
      );
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      final items = List.generate(
        128,
        (index) => DownloadItem(
          id: 'queue-$index',
          track: Track(
            id: 'example:$index',
            name: 'Song $index',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
          ),
          // Avoid extension/native download work; the persisted queue is paused.
          service: '',
          createdAt: DateTime.utc(2026).add(Duration(seconds: index)),
        ),
      );
      final rows = <String, Map<String, Object?>>{
        for (final item in items)
          item.id: {
            'id': item.id,
            'item_json': encodeDownloadQueueItemForPersistence(item),
            'status': 'queued',
            'created_at': item.createdAt.toIso8601String(),
            'updated_at': item.createdAt.toIso8601String(),
          },
      };
      var started = Completer<void>();
      var release = Completer<void>();
      var queueReads = 0;
      var deletes = 0;
      var writes = 0;
      var failRead = false;
      messenger.setMockMethodCallHandler(sqlite, (call) async {
        if (call.method == 'openDatabase') return {'id': 1};
        final arguments = call.arguments as Map? ?? {};
        final sql = arguments['sql'] as String? ?? '';
        if (call.method == 'query') {
          if (sql.toLowerCase().contains('pragma user_version')) {
            return {
              'columns': ['user_version'],
              'rows': [
                [4],
              ],
            };
          }
          if (!sql.contains('download_queue_items')) {
            return {'columns': <String>[], 'rows': <List<Object?>>[]};
          }
          queueReads++;
          final snapshot = rows.values.toList();
          started.complete();
          await release.future;
          if (failRead) {
            throw PlatformException(code: 'sqlite_error', message: 'Try again');
          }
          const columns = [
            'id',
            'item_json',
            'status',
            'created_at',
            'updated_at',
          ];
          return {
            'columns': columns,
            'rows': [
              for (final row in snapshot)
                [for (final column in columns) row[column]],
            ],
          };
        }
        if (call.method == 'batch') {
          for (final raw in arguments['operations'] as List) {
            final operation = raw as Map;
            final statement = operation['sql'] as String;
            final values = operation['arguments'] as List;
            if (statement.startsWith('DELETE FROM download_queue_items')) {
              rows.remove(values.first as String);
              deletes++;
            } else if (statement.startsWith('INSERT')) {
              const columns = [
                'id',
                'item_json',
                'status',
                'created_at',
                'updated_at',
              ];
              rows[values.first as String] = {
                for (var i = 0; i < columns.length; i++) columns[i]: values[i],
              };
              writes++;
            } else {
              fail('Unexpected queue mutation: $statement');
            }
          }
          return null;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
      ProviderContainer scope() => ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              const AppSettings(downloadDirectory: '/fixture/output'),
            ),
          ),
        ],
      );

      final container = scope();
      final queue = container.read(downloadQueueProvider.notifier);
      await started.future;
      expect(container.read(downloadQueueProvider).items, isEmpty);
      var flushed = false;
      final background = queue.flushQueuePersistence().then(
        (_) => flushed = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(flushed, false);
      expect([writes, deletes], [0, 0]);
      release.complete();
      await background;
      expect(
        container.read(downloadQueueProvider).items.map((item) => item.id),
        items.map((item) => item.id),
      );
      expect(rows.keys, items.map((item) => item.id));
      expect(
        [writes, deletes],
        [0, 0],
        reason:
            'restored canonical rows must survive the first background flush',
      );
      expect(queueReads, 1);
      container.dispose();

      // Disposal completes the restore gate but must not access provider state
      // or persist an empty snapshot after ownership has ended.
      started = Completer();
      release = Completer();
      final disposed = scope();
      final disposedQueue = disposed.read(downloadQueueProvider.notifier);
      await started.future;
      final pending = disposedQueue.flushQueuePersistence();
      disposed.dispose();
      await pending;
      expect(rows.keys, items.map((item) => item.id));
      expect([writes, deletes], [0, 0]);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // All public add paths publish immediately, but neither processing nor
      // the 350 ms debounce may act on this incomplete startup snapshot.
      started = Completer();
      release = Completer();
      final additions = scope();
      final additionsQueue = additions.read(downloadQueueProvider.notifier);
      await started.future;
      final singleId = additionsQueue.addToQueue(
        items.first.track,
        '',
        qualityOverride: 'lossless',
      );
      additionsQueue.addMultipleToQueue(
        [items.first.track, _earlyTrack],
        '',
        qualityOverride: 'high',
        playlistName: 'Immediate playlist',
        playlistPositions: [7, 9],
      );
      additionsQueue.addIndividualTracksToQueue([_earlyTrack, _earlyTrack], '');
      final earlyItems = additions.read(downloadQueueProvider).items.toList();
      expect(earlyItems.length, 5);
      expect(earlyItems.map((item) => item.id).toSet(), hasLength(5));
      expect(earlyItems.first.id, singleId);
      expect(earlyItems.map((item) => item.qualityOverride), [
        'lossless',
        'high',
        'high',
        null,
        null,
      ]);
      final additionsFlush = additionsQueue.flushQueuePersistence();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(additions.read(downloadQueueProvider).isProcessing, false);
      expect(
        additions.read(downloadQueueProvider).items.map((item) => item.status),
        everyElement(DownloadStatus.queued),
      );
      expect([writes, deletes], [0, 0]);
      release.complete();
      await additionsFlush;
      final merged = additions.read(downloadQueueProvider);
      expect(merged.items.map((item) => item.id), [
        ...items.map((item) => item.id),
        ...earlyItems.map((item) => item.id),
      ]);
      for (var index = 0; index < earlyItems.length; index++) {
        expect(merged.items[items.length + index], same(earlyItems[index]));
      }
      expect(merged.items[items.length + 2].playlistPosition, 9);
      expect(merged.items[items.length + 2].fromBatch, true);
      expect(merged.items.last.playlistPosition, isNull);
      expect(merged.items.last.fromBatch, false);
      expect(merged.isPaused, true);
      expect(rows.keys, merged.items.map((item) => item.id));
      expect([writes, deletes], [5, 0]);
      additions.dispose();

      // Even disposal cannot flush an early add over the restored disk rows.
      final savedIds = rows.keys.toList();
      started = Completer();
      release = Completer();
      final earlyDisposed = scope();
      final earlyDisposedQueue = earlyDisposed.read(
        downloadQueueProvider.notifier,
      );
      await started.future;
      earlyDisposedQueue.addIndividualTracksToQueue([_earlyTrack], '');
      final disposeFlush = earlyDisposedQueue.flushQueuePersistence();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      earlyDisposed.dispose();
      await disposeFlush;
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rows.keys, savedIds);
      expect([writes, deletes], [5, 0]);

      // A failed restore retains the new UI item and existing disk contents.
      // A subsequent add starts one fresh attempt shared by concurrent flushes.
      started = Completer();
      release = Completer();
      failRead = true;
      final recovery = scope();
      final recoveryQueue = recovery.read(downloadQueueProvider.notifier);
      await started.future;
      final firstRecoveryId = recoveryQueue.addToQueue(_earlyTrack, '');
      recoveryQueue.pauseQueue();
      final failedFlush = expectLater(
        recoveryQueue.flushQueuePersistence(),
        throwsA(isA<StateError>()),
      );
      release.complete();
      await failedFlush;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(rows.keys, savedIds);
      expect([writes, deletes], [5, 0]);
      expect(
        recovery.read(downloadQueueProvider).items.single.id,
        firstRecoveryId,
      );
      expect(recovery.read(downloadQueueProvider).isProcessing, false);

      started = Completer();
      release = Completer();
      failRead = false;
      final readsBeforeRetry = queueReads;
      recoveryQueue.addIndividualTracksToQueue([_earlyTrack], '');
      final secondRecoveryId = recovery
          .read(downloadQueueProvider)
          .items
          .last
          .id;
      await started.future;
      recoveryQueue.resumeQueue();
      expect(recovery.read(downloadQueueProvider).isPaused, false);
      final retryFlushes = Future.wait([
        recoveryQueue.flushQueuePersistence(),
        recoveryQueue.flushQueuePersistence(),
      ]);
      bool? resumedPublication;
      final subscription = recovery.listen(downloadQueueProvider, (_, next) {
        if (resumedPublication == null &&
            next.items.length == savedIds.length + 2) {
          resumedPublication = next.isPaused;
          // Pause immediately after observing the merged publication so the
          // fixture never starts extension/download work after gate release.
          recoveryQueue.pauseQueue();
        }
      });
      release.complete();
      await retryFlushes;
      subscription.close();
      expect(
        resumedPublication,
        false,
        reason: 'newer resume overrides the persisted paused preference',
      );
      final recovered = recovery.read(downloadQueueProvider);
      expect(recovered.items.map((item) => item.id), [
        ...savedIds,
        firstRecoveryId,
        secondRecoveryId,
      ]);
      expect(
        recovered.isPaused,
        true,
        reason: 'the latest pause while publishing also wins',
      );
      expect(rows.keys, recovered.items.map((item) => item.id));
      expect(queueReads, readsBeforeRetry + 1);
      expect([writes, deletes], [7, 0]);
      recovery.dispose();

      // Explicit flush and resume also retry a failed startup without needing
      // another addition. Failed attempts may not touch the saved queue.
      final recoveredIds = rows.keys.toList();
      started = Completer();
      release = Completer();
      failRead = true;
      final explicitRetry = scope();
      final explicitQueue = explicitRetry.read(downloadQueueProvider.notifier);
      await started.future;
      explicitQueue.pauseQueue();
      final firstFailure = expectLater(
        explicitQueue.flushQueuePersistence(),
        throwsA(isA<StateError>()),
      );
      release.complete();
      await firstFailure;
      expect(rows.keys, recoveredIds);
      expect([writes, deletes], [7, 0]);

      started = Completer();
      release = Completer();
      final flushRetryReads = queueReads;
      final secondFailure = expectLater(
        explicitQueue.flushQueuePersistence(),
        throwsA(isA<StateError>()),
      );
      await started.future;
      release.complete();
      await secondFailure;
      expect(queueReads, flushRetryReads + 1);
      expect(rows.keys, recoveredIds);
      expect([writes, deletes], [7, 0]);

      started = Completer();
      release = Completer();
      failRead = false;
      final resumeRetryReads = queueReads;
      explicitQueue.resumeQueue();
      await started.future;
      final resumedFlush = explicitQueue.flushQueuePersistence();
      bool? explicitResumePublication;
      final resumedSubscription = explicitRetry.listen(downloadQueueProvider, (
        _,
        next,
      ) {
        if (explicitResumePublication == null &&
            next.items.length == recoveredIds.length) {
          explicitResumePublication = next.isPaused;
          explicitQueue.pauseQueue();
        }
      });
      release.complete();
      await resumedFlush;
      resumedSubscription.close();
      expect(explicitResumePublication, false);
      expect(queueReads, resumeRetryReads + 1);
      expect(rows.keys, recoveredIds);
      expect([writes, deletes], [7, 0]);
      explicitRetry.dispose();
      await (await AppStateDatabase.instance.database).close();
    }),
  );
}
