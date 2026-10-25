import 'dart:isolate';

import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_state.dart';

String legacyAlbumReplayGainKey(Track track) {
  if (track.albumId != null && track.albumId!.isNotEmpty) {
    return 'id:${track.albumId}';
  }
  return 'name:${track.albumName}|${track.albumArtist ?? ''}';
}

bool legacyAlbumReplayGainBlocked(List<DownloadItem> items, String key) {
  final albumItems = items
      .where((item) => legacyAlbumReplayGainKey(item.track) == key)
      .toList();
  final pending = albumItems.where(
    (item) =>
        item.status == DownloadStatus.queued ||
        item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.finalizing,
  );
  if (pending.isNotEmpty) return true;
  final retryable = albumItems.where(
    (item) =>
        item.status == DownloadStatus.failed ||
        item.status == DownloadStatus.skipped,
  );
  return retryable.isNotEmpty;
}

// Original retrigger/check selection. Return each key that reaches the
// computation, including present single-entry albums that are only cleaned up.
List<String> legacyReadyReplayGainAlbums(
  List<DownloadItem> items,
  Map<String, int> entryCounts,
) {
  final ready = <String>[];
  for (final key in entryCounts.keys.toList()) {
    final count = entryCounts[key]!;
    if (count == 0) continue;
    final albumItems = items
        .where((item) => legacyAlbumReplayGainKey(item.track) == key)
        .toList();
    if (albumItems.isEmpty) {
      if (count > 1) ready.add(key);
      continue;
    }
    if (!legacyAlbumReplayGainBlocked(items, key)) ready.add(key);
  }
  return ready;
}

Future<({List<DownloadItem> items, Map<String, int> entries})>
albumReplayGainFixture(int count) => Isolate.run(() {
  final items = List.generate(count, (index) {
    final album = index ~/ 10;
    return DownloadItem(
      id: 'item-$index',
      track: Track(
        id: 'track-$index',
        name: 'Track $index — 音楽',
        artistName: 'Artist',
        albumName: 'Album $album',
        albumId: album.isEven ? '$album' : null,
        albumArtist: 'Artist',
        duration: 180,
      ),
      service: 'example',
      createdAt: DateTime.utc(2026),
      status: index % 10 != 9 || album % 3 == 2
          ? DownloadStatus.completed
          : album % 3 == 0
          ? DownloadStatus.failed
          : DownloadStatus.queued,
    );
  });
  final entries = <String, int>{
    for (var i = 0; i < count; i += 10)
      legacyAlbumReplayGainKey(items[i].track): 10,
    'id:absent-single': 1,
    'id:absent-multiple': 2,
    'id:empty': 0,
  };
  return (
    items: const DownloadQueueState().copyWith(items: items).items,
    entries: entries,
  );
});
