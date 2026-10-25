import 'package:mosix/models/track.dart';
import 'package:mosix/providers/download_history_provider.dart';
import 'package:mosix/services/history_database.dart';

/// Retains derived lookups while the immutable source list is unchanged.
/// Callers replace their list for metadata, order, or filter changes.
class TrackHistorySnapshot {
  List<Track>? _source;
  HistoryBatchLookupRequest request = HistoryBatchLookupRequest.snapshot([]);

  List<HistoryLookupRequest> get lookups => request.tracks;

  void update(List<Track> tracks) {
    if (identical(tracks, _source)) return;
    _source = tracks;
    request = HistoryBatchLookupRequest.snapshot(
      tracks.map(historyLookupForTrack),
    );
  }
}
