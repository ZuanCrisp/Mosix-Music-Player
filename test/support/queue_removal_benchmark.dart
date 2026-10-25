import 'dart:isolate';

import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_state.dart';
import 'package:mornye/utils/chunked_list.dart';

Future<DownloadQueueState> queueRemovalFixture(int count) => Isolate.run(() {
  return const DownloadQueueState().copyWith(
    items: [
      for (var i = 0; i < count; i++)
        DownloadItem(
          id: 'item-$i',
          track: Track(
            id: 'track-${i ~/ 2}',
            name: 'Track $i',
            artistName: 'Artist',
            albumName: 'Album ${i ~/ 12}',
            duration: 180,
          ),
          service: 'example.audio',
          createdAt: DateTime.utc(2026),
          status: i < 100 ? DownloadStatus.completed : DownloadStatus.queued,
        ),
    ],
  );
});

// Exact list/index work in removeItem before optimization. Persistence and
// ReplayGain scheduling are measured separately through the actual notifier.
DownloadQueueState legacyRemoveQueueItem(DownloadQueueState state, String id) {
  final removed = state.items.where((item) => item.id == id).firstOrNull;
  final items = state.items.where((item) => item.id != id).toList();
  final result = state.copyWith(items: items);
  if (removed != null && result.items.length >= state.items.length) {
    throw StateError('Item was not removed');
  }
  return result;
}

Map<String, int> queueRemovalPhases(DownloadQueueState initial, int count) {
  var state = initial;
  var filtering = 0;
  var chunks = 0;
  var lookup = 0;
  final total = Stopwatch()..start();
  for (var i = 0; i < count; i++) {
    final watch = Stopwatch()..start();
    final id = 'item-$i';
    final removed = state.items.where((item) => item.id == id).firstOrNull;
    final items = state.items.where((item) => item.id != id).toList();
    filtering += watch.elapsedMicroseconds;
    watch.reset();
    final snapshot = ChunkedList<DownloadItem>.from(items);
    chunks += watch.elapsedMicroseconds;
    watch.reset();
    final index = DownloadQueueLookup.fromItems(snapshot);
    lookup += watch.elapsedMicroseconds;
    state = state.copyWith(items: snapshot, lookup: index);
    if (removed == null) throw StateError('Missing fixture item');
  }
  return {
    'total_us': total.elapsedMicroseconds,
    'filter_us': filtering,
    'chunks_us': chunks,
    'lookup_us': lookup,
    'remaining': state.items.length,
  };
}

({int microseconds, DownloadQueueState state}) queueRemovalRun(
  DownloadQueueState initial, {
  required bool incremental,
}) {
  var state = initial;
  final watch = Stopwatch()..start();
  for (var i = 0; i < 100; i++) {
    final id = 'item-$i';
    if (incremental) {
      // Keep the notifier's lookup of the removed item in the timed operation.
      final removed = state.items.where((item) => item.id == id).firstOrNull;
      state = state.withoutItem(id);
      if (removed == null) throw StateError('Missing fixture item');
    } else {
      state = legacyRemoveQueueItem(state, id);
    }
  }
  watch.stop();
  return (microseconds: watch.elapsedMicroseconds, state: state);
}
