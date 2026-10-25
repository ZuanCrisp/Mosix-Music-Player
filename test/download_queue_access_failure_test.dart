import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/models/download_item.dart';
import 'package:mosix/models/track.dart';
import 'package:mosix/providers/download_queue_provider.dart';

class _Queue extends DownloadQueueNotifier {
  _Queue(this._initial);
  final DownloadQueueState _initial;
  @override
  DownloadQueueState build() {
    // Preserve production restore/disposal. These synchronous tests dispose
    // before the startup microtask can perform storage or network work.
    super.build();
    return _initial;
  }
}

DownloadItem _item(int index, DownloadStatus status) => DownloadItem(
  id: 'item-$index',
  track: Track(
    id: 'track-${index ~/ 2}',
    name: 'Track $index — 音楽',
    artistName: 'Artist & Guest',
    albumName: 'Album',
    albumArtist: 'Artist',
    duration: 180,
    coverUrl: 'https://example.test/cover.jpg',
    isrc: 'XX0000000001',
  ),
  service: 'example',
  createdAt: DateTime.utc(2026),
  status: status,
  progress: 0.25,
  speedMBps: 1.5,
  bytesReceived: 4,
  bytesTotal: 16,
  filePath: '/old/$index',
  error: 'old error',
  errorType: DownloadErrorType.network,
  preparationStage: 'old stage',
  playlistName: 'Playlist',
  playlistPosition: index + 1,
  qualityOverride: 'HIGH',
  fromBatch: true,
  preserveQualityVariant: true,
  networkDownloadFolder: index.isEven ? 'smb://example.test/music' : '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer scope(DownloadQueueState state) => ProviderContainer(
    overrides: [downloadQueueProvider.overrideWith(() => _Queue(state))],
  );

  for (final type in [DownloadErrorType.permission, null]) {
    test('bulk failure matches per-item updates (type: $type)', () {
      final items = List.generate(
        140,
        (i) =>
            _item(i, DownloadStatus.values[i % DownloadStatus.values.length]),
      );
      final initial = const DownloadQueueState(
        isProcessing: true,
        isPaused: true,
        outputDir: '/selected',
        audioQuality: 'HIGH',
        autoFallback: false,
      ).copyWith(items: items, currentDownload: items[1]);
      final loop = scope(initial);
      final bulk = scope(initial);
      try {
        final baseline = loop.read(downloadQueueProvider.notifier);
        for (final item in initial.items) {
          if (item.status == DownloadStatus.queued) {
            baseline.updateItemStatus(
              item.id,
              DownloadStatus.failed,
              error: 'Folder inaccessible',
              errorType: type,
            );
          }
        }
        final queue = bulk.read(downloadQueueProvider.notifier);
        var publications = 0;
        bulk.listen(downloadQueueProvider, (_, next) {
          publications++;
          expect(
            next.items.any((item) => item.status == DownloadStatus.queued),
            false,
          );
        });
        queue.failQueuedDownloads(
          error: 'Folder inaccessible',
          errorType: type,
        );
        final after = bulk.read(downloadQueueProvider);
        final expected = loop.read(downloadQueueProvider);
        expect(publications, 1);
        expect(
          jsonEncode(after.items.map((item) => item.toJson()).toList()),
          jsonEncode(expected.items.map((item) => item.toJson()).toList()),
        );
        for (var i = 0; i < items.length; i++) {
          if (items[i].status != DownloadStatus.queued) {
            expect(after.items[i], same(items[i]));
          }
          expect(after.items[i].track, same(items[i].track));
        }
        expect(after.currentDownload, same(initial.currentDownload));
        expect(after.isProcessing, initial.isProcessing);
        expect(after.isPaused, initial.isPaused);
        expect(after.outputDir, initial.outputDir);
        expect(after.audioQuality, initial.audioQuality);
        expect(after.autoFallback, initial.autoFallback);
        for (final (actualIndex, expectedIndex) in [
          (after.lookup.byItemId, expected.lookup.byItemId),
          (after.lookup.byTrackId, expected.lookup.byTrackId),
        ]) {
          expect(
            actualIndex.map(
              (id, item) => MapEntry(id, jsonEncode(item.toJson())),
            ),
            expectedIndex.map(
              (id, item) => MapEntry(id, jsonEncode(item.toJson())),
            ),
          );
        }
        expect(after.lookup.queuedCount, expected.lookup.queuedCount);
        expect(after.lookup.failedCount, expected.lookup.failedCount);
        expect(after.lookup.completedCount, expected.lookup.completedCount);
        expect(
          after.lookup.activeDownloadsCount,
          expected.lookup.activeDownloadsCount,
        );
        expect(after.lookup.finalizingCount, expected.lookup.finalizingCount);
        expect(after.lookup.itemIds, same(initial.lookup.itemIds));
        expect(
          after.lookup.notCompletedItemIds,
          same(initial.lookup.notCompletedItemIds),
        );
        expect(initial.items, items);
        queue.failQueuedDownloads(error: 'Different error');
        expect(bulk.read(downloadQueueProvider), same(after));
        expect(publications, 1);
      } finally {
        bulk.dispose();
        loop.dispose();
      }
    });
  }

  test('empty queue failure is a no-op', () {
    const initial = DownloadQueueState();
    final container = scope(initial);
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      var publications = 0;
      container.listen(downloadQueueProvider, (_, _) => publications++);
      queue.failQueuedDownloads(error: 'Folder inaccessible');
      expect(container.read(downloadQueueProvider), same(initial));
      expect(publications, 0);
    } finally {
      container.dispose();
    }
  });
}
