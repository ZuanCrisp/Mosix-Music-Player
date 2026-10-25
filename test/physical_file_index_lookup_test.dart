import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/sqlite_helpers.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:sqflite/sqflite.dart';

class _SqliteRows implements DatabaseExecutor {
  _SqliteRows(this.table, this.paths);

  final String table;
  final Map<String, String> paths;
  int queries = 0;

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    queries++;
    expect(arguments!.length, lessThanOrEqualTo(450));
    final result = await Process.run('python3', [
      '-c',
      r'''
import json, sqlite3, sys
table, rows, sql, args = json.loads(sys.argv[1])
db = sqlite3.connect(':memory:')
db.row_factory = sqlite3.Row
db.executescript(f"""
CREATE TABLE {table}(id TEXT PRIMARY KEY, file_path TEXT);
CREATE TABLE {table}_path_keys(item_id TEXT, path_key TEXT, PRIMARY KEY(item_id, path_key));
""")
for row in rows:
    db.execute(f'INSERT INTO {table} VALUES (?,?)', (row['id'], row['path']))
    db.executemany(f'INSERT INTO {table}_path_keys VALUES (?,?)', [(row['id'], key) for key in row['keys']])
print(json.dumps([dict(row) for row in db.execute(sql, args)]))
''',
      jsonEncode([
        table,
        [
          for (final entry in paths.entries)
            {
              'id': entry.key,
              'path': entry.value,
              'keys': buildPathMatchKeys(entry.value).toList(),
            },
        ],
        sql,
        arguments,
      ]),
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    return (jsonDecode(result.stdout as String) as List)
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'legacy history markers delete the actual file before index cleanup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'library-delete-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/song.flac',
      ).writeAsString('audio');
      expect(await deleteFile('EXISTS:${file.path}'), isTrue);
      expect(await file.exists(), isFalse);
      expect(await deleteFile('EXISTS:'), isFalse);
    },
  );

  const root = 'content://example.nas/tree/music';
  const album = 'content://example.nas/tree/music%2Falbum';
  const document = '/document/music%2Falbum%2Fsong.flac';
  for (final table in ['history', 'library']) {
    test(
      '$table finds every alias without removing other audio files',
      () async {
        final db = _SqliteRows(table, {
          'download': '$root$document',
          'scan': '$album$document',
          'variant': '$album/document/music%2Falbum%2Fsong.opus',
          'another-folder': '$root/document/music%2Fother%2Fsong.flac',
          'another-server': 'content://other.nas/tree/music$document',
        });
        final ids = await findPhysicalFileRowIds(db, table, [
          'EXISTS:$root$document',
        ]);
        expect(ids.toSet(), {'download', 'scan'});
        expect(db.queries, 1);
      },
    );
  }

  test('large removals keep all IDs and stay within SQLite limits', () async {
    final paths = {
      for (var i = 0; i < 600; i++) 'id-$i': '/music/song-$i.flac',
    };
    final db = _SqliteRows('library', paths);
    final ids = await findPhysicalFileRowIds(db, 'library', paths.values);
    expect(ids.toSet(), paths.keys.toSet());
    expect(db.queries, greaterThan(1));
    final queryCount = db.queries;
    await findPhysicalFileRowIds(db, 'library', []);
    expect(db.queries, queryCount, reason: 'empty paths do not query storage');
  });
}
