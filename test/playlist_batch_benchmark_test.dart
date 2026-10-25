import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/collection_track_batch.dart';

import 'support/library_collections_benchmark.dart';
import 'support/playlist_batch_benchmark.dart';

void main() {
  test(
    'compare playlist batch preparation with the original inline path',
    () async {
      final tracks = await playlistBatchFixture(12000);
      final root = await Directory.systemTemp.createTemp('playlist-benchmark-');
      addTearDown(() => root.delete(recursive: true));
      final samples = <Map<String, int>>[];
      final workers = <Map<String, int>>[];
      for (var index = 0; index < 5; index++) {
        for (final worker in index.isEven ? [false, true] : [true, false]) {
          if (worker) {
            final result = await measureCollectionOperation(
              () => prepareCollectionTrackBatch(
                tracks: tracks,
                existingKeys: const {},
                addedAt: DateTime.utc(2026, 10, 8),
                useNative: true,
                temporaryDirectory: root,
              ),
            );
            expect(result.value.entries.length, tracks.length);
            workers.add(result.timing);
            await result.value.dispose();
            continue;
          }
          final result = await measureCollectionOperation(
            () => inlinePlaylistBatch(
              tracks,
              const {},
              DateTime.utc(2026, 10, 8),
            ),
          );
          expect(result.value.rows.length, tracks.length);
          samples.add(result.timing);
        }
      }
      // Host diagnostics only; the device profile benchmark owns speed claims.
      // ignore: avoid_print
      print(
        jsonEncode({
          'rows': tracks.length,
          'host_inline': samples,
          'host_worker': workers,
        }),
      );
    },
    skip: !const bool.fromEnvironment('RUN_PLAYLIST_BATCH_BENCHMARK'),
  );
}
