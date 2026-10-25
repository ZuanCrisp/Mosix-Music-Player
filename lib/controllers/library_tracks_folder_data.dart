import 'package:mornye/models/track.dart';
import 'package:mornye/controllers/track_history_snapshot.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/history_database.dart';

/// Collection providers replace their track list when its contents change.
/// Keep derived data across selection/layout rebuilds of the same snapshot.
class LibraryTracksFolderData {
  List<CollectionTrackEntry>? _entries;
  Set<String> keys = const {};
  List<Track> tracks = const [];
  final _history = TrackHistorySnapshot();
  HistoryBatchLookupRequest get historyRequest => _history.request;

  void update(List<CollectionTrackEntry> entries) {
    if (identical(entries, _entries)) return;
    _entries = entries;
    keys = Set.unmodifiable(entries.map((entry) => entry.key));
    tracks = List.unmodifiable(entries.map((entry) => entry.track));
    _history.update(tracks);
  }
}
