import 'package:mornye/models/download_item.dart';
import 'package:mornye/services/download_queue_codec.dart';

/// Original snapshot/diff/encode pipeline for the device benchmark. Benchmark
/// callers flush serially and do not invoke restore, scheduling or pause writes.
class LegacyQueueSnapshot {
  LegacyQueueSnapshot({required this.currentItems, required this.applyChanges});
  final List<DownloadItem> Function() currentItems;
  final Future<void> Function({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  })
  applyChanges;
  Map<String, DownloadQueueSavedItem> _saved = {};
  Future<void> _write = Future<void>.value();
  final Future<void> _pauseWrite = Future<void>.value();

  Future<void> flush() async {
    final items = currentItems();
    await (_write = _write.then((_) async {
      final nextSaved = <String, DownloadQueueSavedItem>{};
      final upserts = <Map<String, dynamic>>[];
      final now = DateTime.now().toIso8601String();
      final changed = <DownloadItem>[];
      for (final item in items) {
        if (item.status == DownloadStatus.completed ||
            item.status == DownloadStatus.failed) {
          continue;
        }
        final saved = _saved[item.id];
        final cached = identical(saved?.item, item) && saved?.payload != null;
        nextSaved[item.id] = (
          item: item,
          payload: cached ? saved!.payload : null,
        );
        if (!cached) changed.add(item);
      }
      final encoded = await encodeDownloadQueueItems(changed);
      for (var index = 0; index < changed.length; index++) {
        final item = changed[index];
        final saved = _saved[item.id];
        final payload = encoded[index];
        if (identical(nextSaved[item.id]?.item, item)) {
          nextSaved[item.id] = (item: item, payload: payload);
        }
        if (saved?.payload == payload) continue;
        upserts.add({
          'id': item.id,
          'item_json': payload,
          'status': downloadQueuePersistenceStatus(item.status).name,
          'created_at': item.createdAt.toIso8601String(),
          'updated_at': now,
        });
      }
      final deletedIds = _saved.keys
          .where((id) => !nextSaved.containsKey(id))
          .toList(growable: false);
      if (upserts.isNotEmpty || deletedIds.isNotEmpty) {
        await applyChanges(upserts: upserts, deletedIds: deletedIds);
      }
      _saved = nextSaved;
    }));
    await _pauseWrite;
  }
}
