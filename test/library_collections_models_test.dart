import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/library_database.dart';

Track _track(String id, {String? source, String? isrc}) => Track(
  id: id,
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  source: source,
  isrc: isrc,
);

void main() {
  test('catalog and library collection identity agree across sources', () {
    for (final isrc in [null, '', ' ', ' us-example-1 ']) {
      for (final service in ['example', ' Example ', ' ']) {
        final downloaded = UnifiedLibraryItem.fromDownloadHistory(
          DownloadHistoryItem(
            id: 'song',
            trackName: 'Song',
            artistName: 'Artist',
            albumName: 'Album',
            filePath: '/music/song.flac',
            downloadedAt: DateTime.utc(2026),
            service: service,
            isrc: isrc,
          ),
        );
        expect(
          downloaded.collectionKey,
          trackCollectionKey(_track('song', source: service, isrc: isrc)),
        );
      }
      final local = UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem(
          id: 'song',
          trackName: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: '/music/song.flac',
          scannedAt: DateTime.utc(2026),
          isrc: isrc,
        ),
      );
      expect(
        local.collectionKey,
        trackCollectionKey(_track('song', source: 'local', isrc: isrc)),
      );
    }
    expect(trackCollectionKey(_track('song')), 'builtin:song');
    expect(
      trackCollectionKey(_track('song', isrc: ' us-example-1 ')),
      'isrc:US-EXAMPLE-1',
    );
    expect(
      trackCollectionKey(_track('song', source: 'example')),
      isNot(trackCollectionKey(_track('song', source: 'local'))),
    );
  });

  test(
    'picker requests remain stable keys after deduplication and sorting',
    () {
      final request = PlaylistPickerSummaryRequest.fromTracks([
        _track('second', source: 'example'),
        _track('first', isrc: 'shared'),
        _track('third', isrc: ' SHARED '),
      ]);
      final equivalent = PlaylistPickerSummaryRequest.fromTracks([
        _track('other-id', isrc: 'shared'),
        _track('second', source: 'example'),
      ]);
      expect(request, equivalent);
      expect(request.hashCode, equivalent.hashCode);
      final hash = request.hashCode;
      expect(() => request.trackKeys[0] = 'changed', throwsUnsupportedError);
      expect(request.hashCode, hash);
      expect(request, equivalent);
    },
  );

  test('unloaded playlist membership survives metadata-only copies', () {
    final playlist = UserPlaylistCollection(
      id: 'playlist',
      name: 'Playlist',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      tracks: const [],
      tracksLoaded: false,
      trackKeys: {'example:song'},
    );
    final renamed = playlist.copyWith(name: 'Renamed');
    expect(renamed.tracksLoaded, isFalse);
    expect(renamed.trackCount, 1);
    expect(renamed.containsTrackKey('example:song'), isTrue);
    expect(() => renamed.trackKeys.clear(), throwsUnsupportedError);
    final state = LibraryCollectionsState(playlists: [renamed]);
    expect(state.isTrackInAnyPlaylist('example:song'), isTrue);
    expect(state.copyWith(isLoaded: true).hasPlaylistTracks, isTrue);
    final loaded = renamed.copyWith(tracks: []);
    expect(loaded.tracksLoaded, isTrue);
    expect(loaded.trackCount, 0);
  });

  test(
    'membership remains correct after metadata copies and playlist changes',
    () {
      UserPlaylistCollection playlist(String id, String key) =>
          UserPlaylistCollection(
            id: id,
            name: id,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
            tracks: const [],
            tracksLoaded: false,
            trackKeys: {key},
          );
      final first = playlist('first', 'example:first');
      final second = playlist('second', 'example:second');
      final state = LibraryCollectionsState(playlists: [first, second]);
      final renamed = state.copyWith(
        playlists: [
          second.copyWith(name: 'Renamed'),
          first,
        ],
      );
      expect(renamed.isTrackInAnyPlaylist('example:first'), isTrue);
      expect(renamed.isTrackInAnyPlaylist('example:second'), isTrue);
      final replaced = renamed.copyWith(playlists: [first, first]);
      expect(replaced.isTrackInAnyPlaylist('example:first'), isTrue);
      expect(replaced.isTrackInAnyPlaylist('example:second'), isFalse);
      final removed = renamed.copyWith(playlists: [second]);
      expect(removed.isTrackInAnyPlaylist('example:first'), isFalse);
      expect(removed.isTrackInAnyPlaylist('example:second'), isTrue);
    },
  );
}
