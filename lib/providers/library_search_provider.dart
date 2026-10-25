import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_playlist_search.dart';
import 'package:mornye/services/library_search.dart';

typedef LibrarySearchRequest = ({
  String query,
  LibrarySearchKind kind,
  int limit,
  int offset,
});

/// Resolve the selected record by its source and ID, without matching titles
/// that may also belong to another edition or remix.
final librarySearchTrackProvider = FutureProvider.autoDispose
    .family<UnifiedLibraryItem?, ({String source, String id})>((
      ref,
      key,
    ) async {
      if (key.source == 'local') {
        final row = await LibraryDatabase.instance.getById(key.id);
        return row == null
            ? null
            : UnifiedLibraryItem.fromLocalLibrary(
                LocalLibraryItem.fromJson(row),
              );
      }
      final row = await HistoryDatabase.instance.getById(key.id);
      return row == null
          ? null
          : UnifiedLibraryItem.fromDownloadHistory(
              DownloadHistoryItem.fromJson(row),
            );
    });

final librarySearchProvider = FutureProvider.autoDispose
    .family<List<LibrarySearchHit>, LibrarySearchRequest>((ref, request) async {
      final query = LibrarySearchQuery(request.query);
      if (query.terms.isEmpty) return const [];
      if (request.kind == LibrarySearchKind.playlists) {
        final playlists = ref.watch(
          libraryCollectionsProvider.select((state) => state.playlists),
        );
        return searchLibraryPlaylists(
          playlists: playlists,
          query: request.query,
          limit: request.limit,
          offset: request.offset,
        );
      }
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
      if (includeLocal) {
        ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
      }
      return LibraryDatabase.instance.searchLibrary(
        query: request.query,
        kind: request.kind,
        includeLocal: includeLocal,
        limit: request.limit,
        offset: request.offset,
      );
    });
