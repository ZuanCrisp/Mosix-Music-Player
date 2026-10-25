import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';

void main() {
  group('Track', () {
    test('preserves a generic extension explicit flag', () {
      final track = Track.fromBackendMap({
        'id': 'extension-track-1',
        'name': 'Explicit Song',
        'artists': 'Artist',
        'album_name': 'Album',
        'duration_ms': 180000,
        'provider_id': 'extension.example',
        'explicit': true,
      });

      expect(track.source, 'extension.example');
      expect(track.explicit, isTrue);
      expect(track.isExplicit, isTrue);
    });

    test('preserves extension tagging metadata', () {
      final track = Track.fromBackendMap({
        'id': 'extension-track-1',
        'name': 'Song',
        'artists': 'Artist',
        'album_name': 'Album',
        'duration_ms': 180000,
        'genre': 'Pop',
        'label': 'Label',
        'copyright': 'Copyright',
        'composer': 'Composer',
        'comment': 'https://example.test/album/1',
        'explicit': true,
        'album_type': 'compilation',
        'upc': '0012345678901',
      });

      expect(track.genre, 'Pop');
      expect(track.label, 'Label');
      expect(track.copyright, 'Copyright');
      expect(track.composer, 'Composer');
      expect(track.comment, 'https://example.test/album/1');
      expect(track.toJson()['comment'], 'https://example.test/album/1');
      expect(track.explicit, isTrue);
      expect(track.albumType, 'compilation');
      expect(track.upc, '0012345678901');
      expect(track.toJson()['upc'], '0012345678901');
    });

    test('does not treat a playlist container name as a track album', () {
      final playlistTrack = Track.fromBackendMap({
        'id': 'playlist-track-1',
        'name': 'Song',
        'artists': 'Artist',
        'album_name': ' Road Trip ',
        'duration_ms': 180000,
      }, playlistName: 'road trip');
      final releaseTrack = Track.fromBackendMap({
        'id': 'playlist-track-2',
        'name': 'Song',
        'artists': 'Artist',
        'album_name': 'Real Album',
        'duration_ms': 180000,
      }, playlistName: 'Road Trip');

      expect(playlistTrack.albumName, isEmpty);
      expect(releaseTrack.albumName, 'Real Album');
    });

    test('exposes collection, source, and quality flags', () {
      const album = Track(
        id: 'album-1',
        name: 'Album',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 0,
        itemType: 'album',
        source: 'extension.example',
        audioQuality: 'FLAC 1411kbps',
        audioModes: 'STEREO,DOLBY_ATMOS',
      );

      expect(album.isAlbumItem, isTrue);
      expect(album.isPlaylistItem, isFalse);
      expect(album.isArtistItem, isFalse);
      expect(album.isCollection, isTrue);
      expect(album.isDolbyAtmos, isTrue);
    });

    test('detects singles and eps case-insensitively', () {
      const single = Track(
        id: 'track-1',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Single',
        duration: 210000,
        albumType: 'SINGLE',
      );
      const ep = Track(
        id: 'track-2',
        name: 'Song 2',
        artistName: 'Artist',
        albumName: 'EP',
        duration: 180000,
        albumType: 'ep',
      );
      const album = Track(
        id: 'track-3',
        name: 'Song 3',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 240000,
        albumType: 'album',
      );

      expect(single.isSingle, isTrue);
      expect(ep.isSingle, isTrue);
      expect(album.isSingle, isFalse);
    });

    test('round-trips json with service availability', () {
      final track = Track.fromJson({
        'id': 'source-track-1',
        'name': 'Song',
        'artistName': 'Artist',
        'albumName': 'Album',
        'duration': 123456,
        'availability': {'tidal': true, 'deezer': true, 'deezerId': '31337'},
      });

      expect(track.availability?.tidal, isTrue);
      expect(track.availability?.qobuz, isFalse);
      expect(track.availability?.deezerId, '31337');
      expect(track.toJson()['id'], 'source-track-1');
      expect(track.availability!.toJson()['deezer'], isTrue);
    });
  });
}
