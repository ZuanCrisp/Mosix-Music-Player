import 'package:flutter/foundation.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/services/library_search.dart';

typedef PlaylistSearchEntry = ({
  String id,
  String name,
  String? cover,
  int trackCount,
});

typedef PlaylistSearchRequest = ({
  List<PlaylistSearchEntry> entries,
  String query,
  int limit,
  int offset,
});

/// Only lightweight metadata is sent to the worker, never loaded tracks or
/// playlist membership sets. Retain just the requested ranked prefix.
Future<List<LibrarySearchHit>> searchLibraryPlaylists({
  required List<UserPlaylistCollection> playlists,
  required String query,
  required int limit,
  required int offset,
}) async {
  final request = (
    entries: [
      for (final playlist in playlists)
        (
          id: playlist.id,
          name: playlist.name,
          cover: playlist.coverImagePath ?? playlist.previewCover,
          trackCount: playlist.trackCount,
        ),
    ],
    query: query,
    limit: limit,
    offset: offset,
  );
  if (playlists.length < 256) return rankPlaylistSearchPage(request);
  return compute(
    rankPlaylistSearchPage,
    request,
    debugLabel: 'library playlist search',
  );
}

typedef _RankedPlaylist = ({PlaylistSearchEntry entry, String title, int rank});

List<LibrarySearchHit> rankPlaylistSearchPage(PlaylistSearchRequest request) {
  final query = LibrarySearchQuery(request.query);
  if (query.terms.isEmpty) return const [];
  RangeError.checkNotNegative(request.offset, 'offset');
  RangeError.checkNotNegative(request.limit, 'limit');
  if (request.limit == 0) return const [];
  final capacity = request.offset + request.limit;
  final heap = <_RankedPlaylist>[];
  for (final entry in request.entries) {
    final title = entry.name.toLowerCase();
    if (!query.terms.every(title.contains)) continue;
    final trimmed = title.trim();
    final rank = trimmed == query.text
        ? 0
        : trimmed.startsWith(query.text)
        ? 1
        : trimmed.contains(query.text)
        ? 2
        : 3;
    final candidate = (entry: entry, title: title, rank: rank);
    if (heap.length < capacity) {
      heap.add(candidate);
      var child = heap.length - 1;
      while (child > 0) {
        final parent = (child - 1) ~/ 2;
        if (_compareRankedPlaylists(heap[parent], candidate) >= 0) break;
        heap[child] = heap[parent];
        child = parent;
      }
      heap[child] = candidate;
    } else if (_compareRankedPlaylists(candidate, heap.first) < 0) {
      var parent = 0;
      while (parent * 2 + 1 < heap.length) {
        var child = parent * 2 + 1;
        if (child + 1 < heap.length &&
            _compareRankedPlaylists(heap[child + 1], heap[child]) > 0) {
          child++;
        }
        if (_compareRankedPlaylists(candidate, heap[child]) >= 0) break;
        heap[parent] = heap[child];
        parent = child;
      }
      heap[parent] = candidate;
    }
  }
  heap.sort(_compareRankedPlaylists);
  return [
    for (final candidate in heap.skip(request.offset))
      LibrarySearchHit(
        kind: LibrarySearchKind.playlists,
        id: candidate.entry.id,
        title: candidate.entry.name,
        cover: candidate.entry.cover,
        trackCount: candidate.entry.trackCount,
      ),
  ];
}

int _compareRankedPlaylists(_RankedPlaylist a, _RankedPlaylist b) {
  final rank = a.rank.compareTo(b.rank);
  if (rank != 0) return rank;
  final title = a.title.compareTo(b.title);
  return title != 0 ? title : a.entry.id.compareTo(b.entry.id);
}
