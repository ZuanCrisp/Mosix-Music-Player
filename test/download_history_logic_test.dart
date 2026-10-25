import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/providers/download_queue_provider.dart';

DownloadHistoryItem _historyItem({
  required String id,
  required String filePath,
  required DateTime downloadedAt,
  String albumName = 'Album',
}) {
  return DownloadHistoryItem(
    id: id,
    trackName: 'Same Song',
    artistName: 'Same Artist',
    albumName: albumName,
    filePath: filePath,
    service: 'test',
    downloadedAt: downloadedAt,
    spotifyId: 'source-track-same',
    isrc: 'SAMEISRC',
  );
}

void main() {
  group('download history identity', () {
    test('serializes download timestamps with an explicit UTC offset', () {
      final item = _historyItem(
        id: 'utc',
        filePath: '/music/Album/Same Song.flac',
        downloadedAt: DateTime(2026, 7, 22, 12, 30),
      );

      expect(item.toJson()['downloadedAt'], endsWith('Z'));
    });

    test('same track metadata does not merge files from different albums', () {
      final first = _historyItem(
        id: 'first',
        filePath: '/music/First Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 22),
        albumName: 'First Album',
      );
      final second = _historyItem(
        id: 'second',
        filePath: '/music/Second Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 23),
        albumName: 'Second Album',
      );

      expect(historyItemsReferToSameStoredFile(first, second), isFalse);
    });

    test('equivalent paths still update one stored file record', () {
      final original = _historyItem(
        id: 'original',
        filePath: '/music/Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 22),
      );
      final converted = _historyItem(
        id: 'converted',
        filePath: '/music/Album/Same Song.opus',
        downloadedAt: DateTime.utc(2026, 7, 23),
      );

      expect(historyItemsReferToSameStoredFile(original, converted), isTrue);
    });

    test('duplicate track identities keep the newest lookup item', () {
      final newest = _historyItem(
        id: 'newest',
        filePath: '/music/New Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 23),
        albumName: 'New Album',
      );
      final older = _historyItem(
        id: 'older',
        filePath: '/music/Old Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 22),
        albumName: 'Old Album',
      );

      final state = DownloadHistoryState(
        items: [newest, older],
        lookupItems: [newest, older],
        totalCount: 2,
      );

      expect(state.getBySpotifyId('source-track-same')?.id, 'newest');
      expect(state.getByIsrc('SAMEISRC')?.id, 'newest');
      expect(
        state.findByTrackAndArtist('Same Song', 'Same Artist')?.id,
        'newest',
      );
      expect(state.items, hasLength(2));
    });

    test('recent in-memory completion is visible during batch reload', () {
      final completed = _historyItem(
        id: 'completed',
        filePath: '/music/Album/Same Song.flac',
        downloadedAt: DateTime.utc(2026, 8, 27),
      );
      final state = DownloadHistoryState(
        items: [completed],
        lookupItems: [completed],
        totalCount: 1,
      );
      const completedLookup = HistoryLookupRequest(
        spotifyId: 'same',
        isrc: 'SAME-ISRC',
        trackName: 'Same Song',
        artistName: 'Same Artist',
      );
      const olderLookup = HistoryLookupRequest(
        spotifyId: 'older',
        trackName: 'Older Song',
        artistName: 'Same Artist',
      );

      final visible = mergeVisibleHistoryLookupKeys(
        state: state,
        request: const HistoryBatchLookupRequest([
          completedLookup,
          olderLookup,
        ]),
        persistedKeys: {olderLookup.lookupKey},
      );

      expect(visible, {completedLookup.lookupKey, olderLookup.lookupKey});
    });

    test('actual audio quality survives history serialization', () {
      final item =
          _historyItem(
            id: 'quality',
            filePath: '/music/Album/Hi-Res Song.flac',
            downloadedAt: DateTime.utc(2026, 7, 23),
          ).copyWith(
            quality: '24-bit/96kHz',
            bitDepth: 24,
            sampleRate: 96000,
            format: 'flac',
          );

      final restored = DownloadHistoryItem.fromJson(item.toJson());

      expect(restored.quality, '24-bit/96kHz');
      expect(restored.bitDepth, 24);
      expect(restored.sampleRate, 96000);
      expect(restored.format, 'flac');
    });

    test('explicit metadata survives history serialization', () {
      final item = _historyItem(
        id: 'explicit',
        filePath: '/music/Album/Explicit Song.flac',
        downloadedAt: DateTime.utc(2026, 7, 23),
      ).copyWith(explicit: true);

      expect(DownloadHistoryItem.fromJson(item.toJson()).explicit, isTrue);
    });

    test('placeholder refresh cannot erase an existing measured quality', () {
      expect(
        resolvePersistedHistoryQuality(
          incoming: 'HI_RES_LOSSLESS',
          existing: '24-bit/96kHz',
        ),
        '24-bit/96kHz',
      );
      expect(
        resolvePersistedHistoryQuality(
          incoming: '24-bit/192kHz',
          existing: '24-bit/96kHz',
        ),
        '24-bit/192kHz',
      );
    });
  });

  group('startup orphan reconciliation', () {
    test('requires consecutive missing checks before confirmation', () {
      final firstMissing = reconcileStartupOrphanSuspects(
        checkedIds: {'track'},
        missingIds: {'track'},
        previousSuspectIds: {},
      );
      expect(firstMissing.confirmedIds, isEmpty);
      expect(firstMissing.pendingIds, {'track'});

      final recovered = reconcileStartupOrphanSuspects(
        checkedIds: {'track'},
        missingIds: {},
        previousSuspectIds: firstMissing.pendingIds,
      );
      expect(recovered.confirmedIds, isEmpty);
      expect(recovered.pendingIds, isEmpty);

      final missingAgain = reconcileStartupOrphanSuspects(
        checkedIds: {'track'},
        missingIds: {'track'},
        previousSuspectIds: recovered.pendingIds,
      );
      expect(missingAgain.confirmedIds, isEmpty);
      expect(missingAgain.pendingIds, {'track'});

      final consecutiveMissing = reconcileStartupOrphanSuspects(
        checkedIds: {'track'},
        missingIds: {'track'},
        previousSuspectIds: missingAgain.pendingIds,
      );
      expect(consecutiveMissing.confirmedIds, {'track'});
      expect(consecutiveMissing.pendingIds, isEmpty);
    });

    test('ignores unchecked stale suspects', () {
      final decision = reconcileStartupOrphanSuspects(
        checkedIds: {'checked'},
        missingIds: {'unchecked'},
        previousSuspectIds: {'unchecked'},
      );

      expect(decision.confirmedIds, isEmpty);
      expect(decision.pendingIds, isEmpty);
    });
  });

  group('download completion persistence', () {
    test('publishes completion only after history persistence', () async {
      final events = <String>[];

      await persistBeforePublishingDownloadCompletion(
        persist: () async {
          events.add('persist');
        },
        publish: () => events.add('publish'),
      );

      expect(events, ['persist', 'publish']);
    });

    test(
      'does not publish completion when history persistence fails',
      () async {
        var published = false;

        await expectLater(
          persistBeforePublishingDownloadCompletion(
            persist: () =>
                Future<void>.error(StateError('database unavailable')),
            publish: () => published = true,
          ),
          throwsStateError,
        );

        expect(published, isFalse);
      },
    );
  });
}
