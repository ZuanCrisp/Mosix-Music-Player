import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';

String albumReplayGainKey(Track track) {
  if (track.albumId != null && track.albumId!.isNotEmpty) {
    return 'id:${track.albumId}';
  }
  return 'name:${track.albumName}|${track.albumArtist ?? ''}';
}

/// Failed/skipped requests may still be retried; every non-completed member
/// blocks writing album gain. Completed members may already have been removed.
bool albumReplayGainBlocked(Iterable<DownloadItem> items, String albumKey) =>
    items.any(
      (item) =>
          item.status != DownloadStatus.completed &&
          albumReplayGainKey(item.track) == albumKey,
    );

/// Keys whose accumulated scans can be finalized, in accumulator order.
/// A present single-entry album is finalized to clear its accumulator; an
/// absent single-entry album is retained, matching the queue's existing policy.
List<String> readyReplayGainAlbums(
  Iterable<DownloadItem> items,
  Map<String, int> entryCounts,
) {
  if (entryCounts.isEmpty) return const [];
  final present = <String>{};
  final blocked = <String>{};
  for (final item in items) {
    final key = albumReplayGainKey(item.track);
    if ((entryCounts[key] ?? 0) == 0) continue;
    present.add(key);
    if (item.status != DownloadStatus.completed) blocked.add(key);
  }
  return [
    for (final entry in entryCounts.entries)
      if (entry.value > 0 &&
          !blocked.contains(entry.key) &&
          (entry.value > 1 || present.contains(entry.key)))
        entry.key,
  ];
}
