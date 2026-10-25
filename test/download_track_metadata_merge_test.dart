import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/models/track.dart';
import 'package:mosix/providers/download_queue_provider.dart';

void main() {
  const track = Track(
    id: 'extension:123',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 100,
    albumArtist: 'Album Artist',
    artistId: 'artist-id',
    albumId: 'album-id',
    coverUrl: 'https://example.test/cover',
    previewUrl: 'https://example.test/preview',
    upc: '012345678905',
    source: 'extension',
    audioQuality: 'LOSSLESS',
    audioModes: 'STEREO',
    explicit: false,
    genre: 'Rock',
    label: 'Label',
    copyright: 'Copyright',
    comment: 'Comment',
    availability: ServiceAvailability(deezer: true),
  );

  test('identifier enrichment preserves every untouched Track field', () {
    final resolved = copyTrackWithResolvedMetadata(
      track,
      resolvedIsrc: ' USAAA2400001 ',
      deezerId: '123',
      composer: ' Composer ',
    );
    expect(resolved.toJson(), {
      ...track.toJson(),
      'isrc': 'USAAA2400001',
      'deezerId': '123',
      'composer': 'Composer',
    });
  });

  test('existing numbering wins, missing numbering is filled', () {
    final original = track.copyWith(
      trackNumber: 2,
      discNumber: 0,
      totalTracks: 12,
      composer: 'Original composer',
      isrc: 'USAAA2400001',
    );
    final resolved = copyTrackWithResolvedMetadata(
      original,
      resolvedIsrc: 'invalid',
      trackNumber: 9,
      totalTracks: 20,
      discNumber: 1,
      composer: 'Replacement',
    );
    expect(resolved.toJson(), {...original.toJson(), 'discNumber': 1});
  });

  test('embedding fallbacks retain preview, UPC, and source metadata', () {
    final merged = buildTrackForMetadataEmbedding(track, {
      'track_number': 3,
      'total_tracks': 10,
      'isrc': 'USAAA2400001',
      'composer': 'Composer',
      'upc': '999999999999',
      'comment': 'Backend comment',
    }, track.albumArtist);
    expect(merged.toJson(), {
      ...track.toJson(),
      'trackNumber': 3,
      'totalTracks': 10,
      'isrc': 'USAAA2400001',
      'composer': 'Composer',
      'comment': 'Backend comment',
    });
  });

  test(
    'embedding preserves valid source numbering and fixes invalid indices',
    () {
      final original = track.copyWith(
        trackNumber: 2,
        totalTracks: 10,
        discNumber: 9,
        totalDiscs: 2,
      );
      final merged = buildTrackForMetadataEmbedding(original, {
        'track_number': 5,
        'disc_number': 1,
        'total_tracks': 20,
        'total_discs': 3,
      }, original.albumArtist);
      expect(merged.toJson(), {...original.toJson(), 'discNumber': 1});
    },
  );

  test('embedding without overrides reuses the original track', () {
    expect(
      identical(
        buildTrackForMetadataEmbedding(track, {}, track.albumArtist),
        track,
      ),
      isTrue,
    );
  });
}
