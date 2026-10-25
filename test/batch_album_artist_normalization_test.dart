import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';

Track albumTrack({
  required String id,
  required String artist,
  required String albumArtist,
  String albumId = 'album:1',
  String albumName = 'Popular Monster',
}) {
  return Track(
    id: id,
    name: 'Track $id',
    artistName: artist,
    albumName: albumName,
    albumArtist: albumArtist,
    albumId: albumId,
    duration: 180,
    source: 'test-provider',
  );
}

void main() {
  test('uses the shared album artist across collaboration tracks', () {
    final tracks = <Track>[
      albumTrack(
        id: '1',
        artist: 'Falling In Reverse',
        albumArtist: 'Falling In Reverse',
      ),
      albumTrack(
        id: '2',
        artist: 'Falling In Reverse, Jelly Roll',
        albumArtist: 'Falling In Reverse, Jelly Roll',
      ),
      albumTrack(
        id: '3',
        artist: 'Falling In Reverse, Marilyn Manson',
        albumArtist: 'Falling In Reverse, Marilyn Manson',
      ),
    ];

    final normalized = normalizeBatchAlbumArtists(tracks);

    expect(
      normalized.map((track) => track.albumArtist),
      everyElement('Falling In Reverse'),
    );
    expect(normalized.map((track) => track.artistName), <String>[
      'Falling In Reverse',
      'Falling In Reverse, Jelly Roll',
      'Falling In Reverse, Marilyn Manson',
    ]);
  });

  test('preserves a stable joint album credit', () {
    final tracks = <Track>[
      albumTrack(id: '1', artist: 'Artist A', albumArtist: 'Artist A & B'),
      albumTrack(id: '2', artist: 'Artist B', albumArtist: 'Artist A & B'),
    ];

    final normalized = normalizeBatchAlbumArtists(tracks);

    expect(
      normalized.map((track) => track.albumArtist),
      everyElement('Artist A & B'),
    );
  });

  test('does not combine credits from different albums in one batch', () {
    final tracks = <Track>[
      albumTrack(
        id: '1',
        artist: 'Artist A, Guest',
        albumArtist: 'Artist A, Guest',
        albumId: 'album:a',
        albumName: 'Shared title',
      ),
      albumTrack(
        id: '2',
        artist: 'Artist B, Guest',
        albumArtist: 'Artist B, Guest',
        albumId: 'album:b',
        albumName: 'Shared title',
      ),
    ];

    final normalized = normalizeBatchAlbumArtists(tracks);

    expect(normalized[0].albumArtist, 'Artist A, Guest');
    expect(normalized[1].albumArtist, 'Artist B, Guest');
  });
}
