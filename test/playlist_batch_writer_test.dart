import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/collection_track_batch.dart';

import 'support/playlist_batch_benchmark.dart';

class _InvalidTrack extends Track {
  _InvalidTrack()
    : super(
        id: 'invalid',
        name: 'Invalid',
        artistName: '',
        albumName: '',
        duration: 0,
      );

  @override
  Map<String, dynamic> toJson() => {'value': double.nan};
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('playlist-batch-test-');
  });
  tearDown(() => root.delete(recursive: true));
  final now = DateTime.utc(2026, 10, 8);

  for (final count in [12, 1024, 2500]) {
    test(
      'preparation preserves order, metadata and duplicate counts ($count)',
      () async {
        final fixture = await playlistBatchFixture(count);
        final tracks = [...fixture, fixture[1], fixture[3]];
        final keys = {'example:0', 'example:1'};
        final baseline = inlinePlaylistBatch(tracks, keys, now);
        final prepared = await prepareCollectionTrackBatch(
          tracks: tracks,
          existingKeys: keys,
          addedAt: now,
          useNative: true,
          temporaryDirectory: root,
        );
        try {
          expect(
            prepared.entries.map((entry) => entry.key),
            baseline.entries.map((entry) => entry.key),
          );
          expect(prepared.duplicates, baseline.duplicates);
          expect(prepared.entries.every((entry) => entry.addedAt == now), true);
          expect(keys, {'example:0', 'example:1'});
          if (prepared.rowsPath == null) {
            expect(prepared.rows, baseline.rows);
          } else {
            expect(prepared.rows, isEmpty);
            final rows = await File(prepared.rowsPath!).readAsLines();
            expect(rows.length, baseline.rows.length);
            for (var index = 0; index < rows.length; index++) {
              final row = jsonDecode(rows[index]) as Map;
              expect(row['key'], baseline.rows[index]['track_key']);
              expect(
                jsonEncode(row['track']),
                baseline.rows[index]['track_json'],
              );
            }
          }
        } finally {
          await prepared.dispose();
        }
        expect(await root.list().toList(), isEmpty);
      },
    );
  }

  test('ISRC wins across providers and first batch metadata wins', () async {
    Track track(String id, String source, String isrc) => Track(
      id: id,
      source: source,
      isrc: isrc,
      name: id,
      artistName: 'Artist',
      albumName: 'Album',
      duration: 1,
    );
    final prepared = await prepareCollectionTrackBatch(
      tracks: [
        track('first', 'one', ' xx001 '),
        track('second', 'two', 'XX001'),
        track('third', 'two', 'xx002'),
      ],
      existingKeys: {'isrc:XX002'},
      addedAt: now,
    );
    expect(prepared.duplicates, 2);
    expect(prepared.entries.single.track.id, 'first');
    expect(prepared.entries.single.key, 'isrc:XX001');
  });

  test('mostly duplicate batches retain the small persistence route', () async {
    final fixture = await playlistBatchFixture(12);
    final prepared = await prepareCollectionTrackBatch(
      tracks: [for (var index = 0; index < 256; index++) ...fixture],
      existingKeys: const {},
      addedAt: now,
      useNative: true,
      temporaryDirectory: root,
    );
    expect(prepared.rowsPath, isNull);
    expect(prepared.entries.length, 12);
    expect(prepared.duplicates, 3060);
    await prepared.dispose();
    expect(await root.list().toList(), isEmpty);
  });

  test('failed encoding removes its partial row file', () async {
    final fixture = await playlistBatchFixture(2500);
    await expectLater(
      prepareCollectionTrackBatch(
        tracks: [...fixture, _InvalidTrack()],
        existingKeys: const {},
        addedAt: now,
        useNative: true,
        temporaryDirectory: root,
      ),
      throwsA(anything),
    );
    expect(await root.list().toList(), isEmpty);
  });
}
