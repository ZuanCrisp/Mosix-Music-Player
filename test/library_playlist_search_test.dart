import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/services/library_playlist_search.dart';
import 'package:mornye/services/library_search.dart';

List<PlaylistSearchEntry> _referencePage(PlaylistSearchRequest request) {
  final query = LibrarySearchQuery(request.query);
  final matches =
      request.entries.where((entry) => query.matches(entry.name)).toList()
        ..sort((a, b) {
          final rank = query.rank(a.name).compareTo(query.rank(b.name));
          if (rank != 0) return rank;
          final title = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return title != 0 ? title : a.id.compareTo(b.id);
        });
  return matches.skip(request.offset).take(request.limit).toList();
}

void main() {
  test(
    'bounded search has identical ranking and pages across Unicode/ties',
    () {
      final random = Random(620);
      const names = [
        '  rock  ',
        'ROCK',
        'rock mix',
        'my rock',
        'mix rock',
        'Röck café',
        '歌 music',
        'rock % mix',
        'mix, rock',
        'not a match',
      ];
      final entries = List.generate(
        4000,
        (index) => (
          id: '$index',
          name: names[random.nextInt(names.length)],
          cover: 'cover-$index',
          trackCount: index,
        ),
      );
      for (final query in [
        'rock',
        'rock mix',
        'mix rock',
        'röck',
        '歌',
        'missing',
      ]) {
        for (final offset in [0, 1, 30, 400, 5000]) {
          for (final limit in [0, 1, 40, 5000]) {
            final request = (
              entries: entries,
              query: query,
              offset: offset,
              limit: limit,
            );
            final expected = _referencePage(request);
            final actual = rankPlaylistSearchPage(request);
            expect(
              actual.map((hit) => hit.id),
              expected.map((entry) => entry.id),
            );
            expect(
              actual.map((hit) => hit.title),
              expected.map((entry) => entry.name),
            );
            expect(
              actual.map((hit) => hit.cover),
              expected.map((entry) => entry.cover),
            );
            expect(
              actual.map((hit) => hit.trackCount),
              expected.map((entry) => entry.trackCount),
            );
          }
        }
      }
    },
  );

  test(
    'playlist worker transfers only summary and preserves cover precedence',
    () async {
      final playlists = List.generate(
        300,
        (index) => UserPlaylistCollection(
          id: '$index',
          name: 'Playlist $index',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          tracks: const [],
          tracksLoaded: false,
          trackKeys: {'example:$index'},
          previewCover: 'preview-$index',
          coverImagePath: index.isEven ? 'custom-$index' : null,
        ),
      );
      final hits = await searchLibraryPlaylists(
        playlists: playlists,
        query: 'playlist',
        offset: 0,
        limit: 300,
      );
      expect(hits.length, 300);
      for (final hit in hits) {
        final index = int.parse(hit.id);
        expect(hit.trackCount, 1);
        expect(hit.cover, index.isEven ? 'custom-$index' : 'preview-$index');
      }
      expect(
        () => rankPlaylistSearchPage((
          entries: const [],
          query: 'x',
          offset: -1,
          limit: 1,
        )),
        throwsRangeError,
      );
      expect(
        rankPlaylistSearchPage((
          entries: const [],
          query: '',
          offset: -1,
          limit: -1,
        )),
        isEmpty,
      );
    },
  );
}
