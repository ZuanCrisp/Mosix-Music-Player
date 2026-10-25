import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/platform_bridge.dart';

import '../test/support/playlist_batch_benchmark.dart';

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
    storageMode: Platform.isAndroid ? 'saf' : 'app',
    downloadTreeUri: 'content://example.test/tree/missing',
    downloadDirectoryBookmark: 'invalid-bookmark',
    nativeDownloadWorkerEnabled: false,
  );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this._items);
  final List<DownloadItem> _items;
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(items: _items);
  }
}

class _LoopQueue extends _Queue {
  _LoopQueue(super.items);
  @override
  void failQueuedDownloads({
    required String error,
    DownloadErrorType? errorType,
  }) {
    // The original preflight failure transition, including persistence
    // scheduling for every item. All setup/validation remains identical.
    for (final item in state.items) {
      if (item.status == DownloadStatus.queued) {
        updateItemStatus(
          item.id,
          DownloadStatus.failed,
          error: error,
          errorType: errorType,
        );
      }
    }
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'Five alternating old/new pairs per size of real queue preflight with an inaccessible Android SAF tree or invalid iOS bookmark. Timing covers resume through failure publication, including platform validation. Private platform SQLite persistence verified outside timing. iOS debug is correctness only.',
  };
  var completed = 0;
  late Directory root;
  late Directory output;
  late Database db;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('queue-access-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
    });
    db = await AppStateDatabase.instance.database;
    expect(db.path, '${root.path}/app_state.db');
    final extensions = await Directory('${root.path}/extensions').create();
    final data = await Directory('${root.path}/data').create();
    output = await Directory('${root.path}/output').create();
    await PlatformBridge.initExtensionSystem(
      extensions.path,
      data.path,
      masterKey: base64Encode(List<int>.filled(32, 1)),
      lyricsProviders: const [],
      lyricsFetchOptions: const {},
      allowedDirectories: [output.path],
    );
  });
  tearDownAll(() async {
    await PlatformBridge.cleanupExtensions();
    await db.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['queue_access_failure'] = report;
  });
  setUp(() {
    // testWidgets resets lifecycle state between cases. The production queue
    // correctly refuses Android foreground work unless the app is resumed.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  for (final count in [1000, 2000]) {
    testWidgets('denied folder fails $count queued requests only', (
      tester,
    ) async {
      final tracks = await playlistBatchFixture(count + 5);
      final initial = [
        for (var i = 0; i < tracks.length; i++)
          DownloadItem(
            id: 'item-$i',
            track: tracks[i],
            service: 'example',
            createdAt: DateTime.utc(2026),
            status: i < count
                ? DownloadStatus.queued
                : [
                    DownloadStatus.downloading,
                    DownloadStatus.finalizing,
                    DownloadStatus.completed,
                    DownloadStatus.failed,
                    DownloadStatus.skipped,
                  ][i - count],
            progress: 0.25,
            speedMBps: 1.5,
            bytesReceived: 4,
            bytesTotal: 16,
            filePath: '/old/$i',
            error: 'old error',
            errorType: DownloadErrorType.network,
            preparationStage: 'old stage',
            playlistName: 'Playlist',
            playlistPosition: i + 1,
            qualityOverride: 'HIGH',
            fromBatch: true,
            preserveQualityVariant: true,
          ),
      ];
      final samples = <String, List<Map<String, int>>>{
        'per_item': [],
        'bulk': [],
      };
      for (var sample = 0; sample < 5; sample++) {
        for (final bulk in sample.isEven ? [false, true] : [true, false]) {
          await db.delete('download_queue_items');
          final container = ProviderContainer(
            overrides: [
              settingsProvider.overrideWith(() => _Settings(output.path)),
              extensionProvider.overrideWith(_Extensions.new),
              downloadQueueProvider.overrideWith(
                () => bulk ? _Queue(initial) : _LoopQueue(initial),
              ),
            ],
          );
          try {
            final queue = container.read(downloadQueueProvider.notifier);
            queue.pauseQueue(persistAcrossRestarts: false);
            await queue.flushQueuePersistence();
            final before = container.read(downloadQueueProvider);
            expect(before.isPaused, true);
            expect(before.items, initial);
            final done = Completer<void>();
            var publications = 0;
            final watch = Stopwatch();
            final subscription = container.listen(downloadQueueProvider, (
              previous,
              next,
            ) {
              if (!identical(previous?.items, next.items)) publications++;
              if (next.failedCount == count + 1 && !next.isProcessing) {
                watch.stop();
                if (!done.isCompleted) done.complete();
              }
            });
            watch.start();
            queue.resumeQueue();
            await done.future.timeout(
              const Duration(seconds: 20),
              onTimeout: () {
                final state = container.read(downloadQueueProvider);
                throw StateError(
                  'Queue did not fail: lifecycle=${binding.lifecycleState}, '
                  'paused=${state.isPaused}, processing=${state.isProcessing}, '
                  'failed=${state.failedCount}, publications=$publications',
                );
              },
            );
            subscription.close();
            samples[bulk ? 'bulk' : 'per_item']!.add({
              'microseconds': watch.elapsedMicroseconds,
              'item_publications': publications,
            });
            expect(publications, bulk ? 1 : count);
            final after = container.read(downloadQueueProvider);
            expect(after.isPaused, false);
            expect(after.isProcessing, false);
            expect(after.outputDir, output.path);
            final message = Platform.isAndroid
                ? safPermissionLostErrorMessage
                : downloadFolderAccessLostErrorMessage;
            final type = Platform.isAndroid
                ? DownloadErrorType.permission
                : null;
            for (var i = 0; i < initial.length; i++) {
              final expected = i < count
                  ? initial[i].copyWith(
                      status: DownloadStatus.failed,
                      filePath: null,
                      error: message,
                      errorType: type,
                    )
                  : initial[i];
              expect(
                jsonEncode(after.items[i].toJson()),
                jsonEncode(expected.toJson()),
              );
              if (i >= count) expect(after.items[i], same(initial[i]));
            }
            await queue.flushQueuePersistence();
            final rows = await AppStateDatabase.instance
                .getPendingDownloadQueueRows();
            expect(rows.map((row) => row['id']), [
              'item-$count',
              'item-${count + 1}',
              'item-${count + 4}',
            ]);
            expect(before.items, initial);
            if (bulk && sample == 0 && count == 1000) {
              // Retrying one failed request must still enter preflight again.
              // Keep the folder inaccessible so no provider/network is used.
              var requeued = false;
              final retried = Completer<void>();
              final retrySubscription = container.listen(
                downloadQueueProvider,
                (_, next) {
                  final status = next.items.first.status;
                  if (status == DownloadStatus.queued) requeued = true;
                  if (requeued &&
                      status == DownloadStatus.failed &&
                      !next.isProcessing &&
                      !retried.isCompleted) {
                    retried.complete();
                  }
                },
              );
              try {
                await queue.retryItem(initial.first.id);
                expect(requeued, true, reason: 'Native reset must allow retry');
                await retried.future.timeout(const Duration(seconds: 20));
                final retryState = container.read(downloadQueueProvider);
                expect(retryState.items.first.error, message);
                expect(retryState.items.first.errorType, type);
                expect(retryState.items.first.progress, 0);
                for (var i = 1; i < initial.length; i++) {
                  expect(retryState.items[i], same(after.items[i]));
                }
                await queue.flushQueuePersistence();
                expect(
                  (await AppStateDatabase.instance
                          .getPendingDownloadQueueRows())
                      .map((row) => row['id']),
                  rows.map((row) => row['id']),
                );
              } finally {
                retrySubscription.close();
              }
            }
          } finally {
            container.dispose();
          }
        }
      }
      report['queued_$count'] = samples;
      completed++;
    });
  }
}
