import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/audio_format_utils.dart';

void main() {
  group('local library incremental scan', () {
    test('rescans legacy metadata rows exactly once', () {
      expect(
        libraryIncrementalSnapshotModTime(
          storedModTime: 1234,
          storedScanVersion: 0,
        ),
        -1,
      );
      expect(
        libraryIncrementalSnapshotModTime(
          storedModTime: 1234,
          storedScanVersion: LibraryDatabase.audioMetadataScanVersion,
        ),
        1234,
      );
    });

    test('keeps a local item current after an audio metadata probe', () {
      final item = LocalLibraryItem(
        id: 'local-1',
        sourceId: 'external-ssd',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/song.flac',
        scannedAt: DateTime(2026),
        bitDepth: 24,
        sampleRate: 96000,
        explicit: true,
      );

      final updated = item.withAudioMetadata(bitrate: 1840);

      expect(updated.bitrate, 1840);
      expect(updated.bitDepth, 24);
      expect(updated.sampleRate, 96000);
      expect(updated.explicit, isTrue);
      expect(updated.trackName, 'Song');
      expect(updated.filePath, '/music/song.flac');
      expect(updated.sourceId, 'external-ssd');
      expect(
        LocalLibraryItem.fromJson(updated.toJson()).sourceId,
        'external-ssd',
      );
      expect(LocalLibraryItem.fromJson(updated.toJson()).explicit, isTrue);
    });

    test('recognizes a retained external source index', () {
      final offlineSource = LocalLibrarySource(
        id: 'external-ssd',
        path: 'content://music/tree/SSD%3AMusic',
        displayName: 'SSD/Music',
        isRemovable: true,
        available: false,
        trackCount: 1200,
      );

      expect(offlineSource.isIndexed, isTrue);
      expect(offlineSource.available, isFalse);
      expect(offlineSource.copyWith(available: true).trackCount, 1200);
    });
  });

  group('ReplayGain metadata availability', () {
    test(
      'recognizes track or album gain including zero, but not peak alone',
      () {
        for (final value in ['0.00 dB', '-7.25 dB', ' +2.1 DB ', 0, -4.5]) {
          expect(
            metadataHasReplayGain({'replaygain_track_gain': value}),
            isTrue,
          );
          expect(
            metadataHasReplayGain({'replaygain_album_gain': value}),
            isTrue,
          );
        }
        for (final value in [null, '', 'dB', 'NaN', 'Infinity', 'not a gain']) {
          expect(
            metadataHasReplayGain({'replaygain_track_gain': value}),
            isFalse,
          );
        }
        expect(
          metadataHasReplayGain({'replaygain_track_peak': '0.99'}),
          isFalse,
        );
      },
    );

    test('unreadable or filename-only metadata is not a confirmed absence', () {
      expect(replayGainMetadataWasRead({}), isFalse);
      expect(
        replayGainMetadataWasRead({
          'error': 'permission denied',
          'format': 'FLAC',
        }),
        isFalse,
      );
      expect(
        replayGainMetadataWasRead({
          'metadataFromFilename': true,
          'format': 'FLAC',
        }),
        isFalse,
      );
      expect(replayGainMetadataWasRead({'audio_codec': 'flac'}), isTrue);
      expect(replayGainMetadataWasRead({'replaygain_track_gain': ''}), isTrue);
    });

    test('history round-trip preserves known absence after removing gain', () {
      final item = DownloadHistoryItem(
        id: 'gain',
        trackName: 'Track',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/music/track.flac',
        service: 'test',
        downloadedAt: DateTime.utc(2026),
        hasReplayGain: true,
        replayGainMetadataScanVersion: 1,
      );
      final tagged = DownloadHistoryItem.fromJson(item.toJson());
      expect(tagged.hasReplayGain, isTrue);
      final removed = DownloadHistoryItem.fromJson(
        tagged.copyWith(hasReplayGain: false).toJson(),
      );
      expect(removed.hasReplayGain, isFalse);
      expect(removed.replayGainMetadataScanVersion, 1);
      final legacy = item.toJson()
        ..remove('hasReplayGain')
        ..remove('replayGainMetadataScanVersion');
      expect(
        DownloadHistoryItem.fromJson(legacy).replayGainMetadataScanVersion,
        0,
      );
    });

    test('local scan flags survive serialization and tag removal', () {
      final item = LocalLibraryItem.fromJson({
        'id': 'local-gain',
        'trackName': 'Track',
        'artistName': 'Artist',
        'albumName': 'Album',
        'filePath': '/music/track.flac',
        'scannedAt': DateTime.utc(2026).toIso8601String(),
        'replaygain_album_gain': '-6.2 dB',
        'hasLyrics': true,
      });
      expect(LocalLibraryItem.fromJson(item.toJson()).hasReplayGain, isTrue);
      final removed = item.withAudioMetadata(hasReplayGain: false);
      expect(removed.hasReplayGain, isFalse);
      expect(removed.hasLyrics, isTrue);
    });
  });

  group('missing lyrics filter', () {
    test(
      'requires a completed lyrics scan before treating false as missing',
      () {
        final predicate = confirmedMissingLyricsSqlPredicate(
          hasLyricsExpr: 'item.has_lyrics',
          lyricsKnownExpr: 'item.lyrics_scan_version >= 1',
        );

        expect(predicate, contains('item.lyrics_scan_version >= 1'));
        expect(predicate, contains('COALESCE(item.has_lyrics, 0) = 0'));
      },
    );
  });

  group('Library collections', () {
    test('keeps playlist membership without eagerly loading track JSON', () {
      final playlist = UserPlaylistCollection(
        id: 'playlist-1',
        name: 'Playlist',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        tracks: const [],
        previewCover: 'https://example.test/cover.jpg',
        tracksLoaded: false,
        trackKeys: {'track:a', 'track:b'},
      );

      expect(playlist.tracks, isEmpty);
      expect(playlist.tracksLoaded, isFalse);
      expect(playlist.trackCount, 2);
      expect(playlist.containsTrackKey('track:a'), isTrue);
      expect(playlist.previewCover, 'https://example.test/cover.jpg');

      final loaded = playlist.copyWith(
        tracks: [
          CollectionTrackEntry(
            key: 'track:a',
            track: const Track(
              id: 'a',
              name: 'A',
              artistName: 'Artist',
              albumName: 'Album',
              duration: 1000,
            ),
            addedAt: DateTime.utc(2026),
          ),
        ],
      );
      expect(loaded.tracksLoaded, isTrue);
      expect(loaded.trackCount, 1);
    });
  });
}
