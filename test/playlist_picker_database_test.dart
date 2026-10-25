import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_collections_database.dart';

// Exercises the database boundary's bounded requests and aggregation without
// requiring a platform SQLite plugin. The production SQL is passed unchanged.
class _PickerDatabase implements DatabaseExecutor {
  final List<Map<String, Object?>> playlistRows;
  final Map<String, Set<String>> membership;
  final batches = <List<Object?>>[];
  int summaryQueries = 0;

  _PickerDatabase(this.playlistRows, this.membership);

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    if (arguments == null) {
      summaryQueries++;
      expect(sql, contains('preview_track_json'));
      return playlistRows;
    }
    // Emulate a database with a conservative parameter budget. Regressing to
    // one unbounded query must fail even on hosts with a larger SQLite limit.
    if (arguments.length > 500) throw StateError('too many SQL variables');
    expect('?'.allMatches(sql).length, arguments.length);
    batches.add(List.of(arguments));
    return [
      for (final entry in membership.entries)
        {
          'playlist_id': entry.key,
          'matched_count': arguments.where(entry.value.contains).length,
        },
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object?> _playlist(String id, {String? cover, String? preview}) => {
  'id': id,
  'name': id,
  'cover_image_path': cover,
  'preview_track_json': preview,
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-02T00:00:00Z',
  'track_count': 1205,
};

void main() {
  test(
    'large selections aggregate across batches and deduplicate keys',
    () async {
      final keys = List.generate(1205, (i) => 'track-$i');
      final db = _PickerDatabase(
        [
          _playlist('partial'),
          _playlist(
            'full',
            preview: jsonEncode({'coverUrl': 'https://example.test/cover'}),
          ),
          _playlist('empty'),
        ],
        {'full': keys.toSet(), 'partial': keys.take(1204).toSet(), 'empty': {}},
      );
      final rows = await readPlaylistPickerSummaries(db, [
        ...keys,
        ...keys.take(10),
        '',
        ' ',
      ]);
      expect(db.batches.map((batch) => batch.length), [500, 500, 205]);
      expect(db.batches.expand((batch) => batch).toList(), keys);
      expect(db.summaryQueries, 1);
      expect(rows.map((row) => row.id), ['partial', 'full', 'empty']);
      expect(rows.map((row) => row.containsAllRequestedTracks), [
        false,
        true,
        false,
      ]);
      expect(rows[1].previewCover, 'https://example.test/cover');
      expect(rows[1].trackCount, 1205);
    },
  );

  test(
    'empty selection performs no matching query or implicit all-match',
    () async {
      final db = _PickerDatabase([_playlist('playlist')], {});
      final rows = await readPlaylistPickerSummaries(db, ['', ' ']);
      expect(db.batches, isEmpty);
      expect(rows.single.containsAllRequestedTracks, isFalse);
    },
  );

  test(
    'many playlist previews need no parameter list and tolerate bad JSON',
    () async {
      final db = _PickerDatabase([
        for (var i = 0; i < 1200; i++) _playlist('$i'),
        _playlist('custom', cover: '/local/cover.jpg'),
        _playlist('bad', preview: '{broken'),
        _playlist('blank', preview: '{"coverUrl":""}'),
      ], {});
      final rows = await readPlaylistPickerSummaries(db, []);
      expect(rows, hasLength(1203));
      expect(db.summaryQueries, 1);
      expect(db.batches, isEmpty);
      expect(rows[1200].coverImagePath, '/local/cover.jpg');
      expect(rows.map((row) => row.previewCover), everyElement(isNull));
    },
  );
}
