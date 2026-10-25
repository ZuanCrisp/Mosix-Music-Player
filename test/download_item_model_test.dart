import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';

void main() {
  group('DownloadItem', () {
    Track sampleTrack() => const Track(
      id: 'track-1',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 1000,
    );

    test('uses defaults and preserves fields through copyWith', () {
      final createdAt = DateTime.utc(2026, 5, 4, 10);
      final item = DownloadItem(
        id: 'download-1',
        track: sampleTrack(),
        service: 'provider-a',
        createdAt: createdAt,
      );

      final updated = item.copyWith(
        status: DownloadStatus.downloading,
        progress: 0.5,
        speedMBps: 1.25,
        bytesReceived: 512,
        bytesTotal: 1024,
        qualityOverride: 'HI_RES',
        playlistName: 'Favorites',
        preparationStage: 'resolving_stream',
        preserveQualityVariant: true,
      );

      expect(item.status, DownloadStatus.queued);
      expect(item.progress, 0);
      expect(updated.id, item.id);
      expect(updated.track, item.track);
      expect(updated.status, DownloadStatus.downloading);
      expect(updated.progress, 0.5);
      expect(updated.speedMBps, 1.25);
      expect(updated.bytesReceived, 512);
      expect(updated.bytesTotal, 1024);
      expect(updated.qualityOverride, 'HI_RES');
      expect(updated.playlistName, 'Favorites');
      expect(updated.preparationStage, 'resolving_stream');
      expect(updated.preserveQualityVariant, isTrue);
    });

    test('maps typed errors to user-facing messages', () {
      final base = DownloadItem(
        id: 'download-1',
        track: sampleTrack(),
        service: 'provider-b',
        createdAt: DateTime.utc(2026),
        filePath: '/music/stale.flac',
        error: 'raw backend failure',
      );

      expect(base.errorMessage, 'raw backend failure');
      expect(
        base.copyWith(errorType: DownloadErrorType.notFound).errorMessage,
        'Song not found on any service',
      );
      expect(
        base.copyWith(errorType: DownloadErrorType.rateLimit).errorMessage,
        'Service rate limit reached. Wait before retrying.',
      );
      expect(
        base.copyWith(errorType: DownloadErrorType.network).errorMessage,
        'Connection failed, check your internet',
      );
      expect(
        base.copyWith(errorType: DownloadErrorType.permission).errorMessage,
        'Cannot write to folder, check storage permission',
      );
      expect(base.copyWith(error: null).errorMessage, isEmpty);
      expect(base.copyWith().filePath, '/music/stale.flac');
      expect(base.copyWith(filePath: null).filePath, isNull);
      expect(
        base
            .copyWith(errorType: DownloadErrorType.network)
            .copyWith(errorType: null)
            .errorType,
        isNull,
      );
    });

    test('decodes json defaults and enums', () {
      final item = DownloadItem.fromJson({
        'id': 'download-1',
        'track': {
          'id': 'track-1',
          'name': 'Song',
          'artistName': 'Artist',
          'albumName': 'Album',
          'duration': 1000,
        },
        'service': 'provider-a',
        'status': 'failed',
        'errorType': 'network',
        'createdAt': '2026-05-04T10:00:00.000Z',
      });

      expect(item.status, DownloadStatus.failed);
      expect(item.errorType, DownloadErrorType.network);
      expect(item.progress, 0);
      expect(item.bytesReceived, 0);
      expect(item.preparationStage, isEmpty);
      expect(item.preserveQualityVariant, isFalse);
      expect(item.toJson()['status'], 'failed');
      expect(item.toJson()['errorType'], 'network');
      expect(item.toJson()['preparationStage'], isEmpty);
    });

    test('persists restart-safe state without transient transfer progress', () {
      final item = DownloadItem(
        id: 'download-active',
        track: sampleTrack(),
        service: 'provider-a',
        createdAt: DateTime.utc(2026),
        status: DownloadStatus.finalizing,
        progress: 0.97,
        speedMBps: 3.5,
        bytesReceived: 970,
        bytesTotal: 1000,
        preparationStage: 'embedding_metadata',
      );

      final persisted =
          jsonDecode(encodeDownloadQueueItemForPersistence(item))
              as Map<String, dynamic>;

      expect(persisted['id'], item.id);
      expect(persisted['status'], DownloadStatus.queued.name);
      expect(persisted['progress'], 0.0);
      expect(persisted['speedMBps'], 0.0);
      expect(persisted['bytesReceived'], 0);
      expect(persisted['bytesTotal'], 0);
      expect(persisted['preparationStage'], isEmpty);
    });
  });

  group('Download queue processing gate', () {
    test('allows only one asynchronous startup at a time', () {
      final gate = QueueProcessingGate();

      expect(gate.tryEnter(), isTrue);
      expect(gate.tryEnter(), isFalse);
      expect(gate.leave(), isTrue);
      expect(gate.tryEnter(), isTrue);
      expect(gate.leave(), isFalse);
    });
  });

  group('Download queue lookup', () {
    test('updates counters while sharing unchanged index structures', () {
      DownloadItem item(String id, DownloadStatus status) => DownloadItem(
        id: id,
        track: Track(
          id: 'track-$id',
          name: 'Song $id',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1000,
        ),
        service: 'extension.test',
        createdAt: DateTime.utc(2026),
        status: status,
      );

      final previous = [
        item('queued', DownloadStatus.queued),
        item('active', DownloadStatus.downloading),
        item('finalizing', DownloadStatus.finalizing),
      ];
      final lookup = DownloadQueueLookup.fromItems(previous);
      expect(lookup.queuedCount, 3);
      expect(lookup.activeDownloadsCount, 1);
      expect(lookup.finalizingCount, 1);
      expect(lookup.notCompletedItemIds, ['queued', 'active', 'finalizing']);

      final next = List<DownloadItem>.from(previous);
      next[2] = previous[2].copyWith(status: DownloadStatus.completed);
      final updated = lookup.updatedForIndices(
        previousItems: previous,
        nextItems: next,
        changedIndices: const [2],
      );

      expect(updated.queuedCount, 2);
      expect(updated.completedCount, 1);
      expect(updated.finalizingCount, 0);
      expect(identical(updated.indexByItemId, lookup.indexByItemId), isTrue);
      expect(identical(updated.itemIds, lookup.itemIds), isTrue);
      expect(updated.notCompletedItemIds, ['queued', 'active']);

      final progressOnly = List<DownloadItem>.from(next);
      progressOnly[1] = next[1].copyWith(progress: 0.5);
      final progressUpdated = updated.updatedForIndices(
        previousItems: next,
        nextItems: progressOnly,
        changedIndices: const [1],
      );
      expect(
        identical(
          progressUpdated.notCompletedItemIds,
          updated.notCompletedItemIds,
        ),
        isTrue,
      );
    });
  });
}
