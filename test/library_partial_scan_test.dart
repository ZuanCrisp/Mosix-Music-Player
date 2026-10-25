import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_cleanup.dart';
import 'package:sqflite/sqflite.dart';

class _Statements implements DatabaseExecutor {
  final statements = <Map<String, Object?>>[];

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async {
    statements.add({'sql': sql, 'args': arguments});
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final partial in [false, true]) {
    for (final empty in [false, true]) {
      test(
        'scan replacement preserves unreadable rows only on partial scans ($partial, empty=$empty)',
        () async {
          final db = _Statements();
          await deleteReplacedLibraryScanRows(
            db,
            'sd-card',
            stageTable: 'staged',
            preserveMissing: partial,
          );
          // Run the actual generated SQL in SQLite, including path-key cleanup.
          final result = await Process.run('python3', [
            '-c',
            r'''
import json, sqlite3, sys
args = json.loads(sys.argv[1])
db = sqlite3.connect(':memory:')
db.executescript("""
CREATE TABLE library(id TEXT PRIMARY KEY, file_path TEXT UNIQUE, source_id TEXT);
CREATE TABLE library_path_keys(item_id TEXT, path_key TEXT);
CREATE TABLE staged(id TEXT, file_path TEXT);
INSERT INTO library VALUES ('readable', '/sd/readable.flac', 'sd-card'),
 ('old-id', '/sd/changed.flac', 'sd-card'),
 ('unreadable', '/sd/unreadable.flac', 'sd-card'),
 ('other', '/internal/track.flac', 'internal');
INSERT INTO library_path_keys SELECT id, file_path FROM library;
""")
if not args['empty']:
    db.executescript("INSERT INTO staged VALUES ('readable', '/sd/readable.flac'), ('new-id', '/sd/changed.flac');")
with db:
    for statement in args['statements']:
        db.execute(statement['sql'], statement['args'])
print(json.dumps({
    'rows': [row[0] for row in db.execute('SELECT id FROM library ORDER BY id')],
    'keys': [row[0] for row in db.execute('SELECT item_id FROM library_path_keys ORDER BY item_id')]
}))
''',
            jsonEncode({'statements': db.statements, 'empty': empty}),
          ]);
          expect(result.exitCode, 0, reason: result.stderr.toString());
          final data =
              jsonDecode(result.stdout as String) as Map<String, dynamic>;
          final expected = partial
              ? (empty
                    ? ['old-id', 'other', 'readable', 'unreadable']
                    : ['other', 'unreadable'])
              : ['other'];
          expect(data['rows'], expected);
          expect(data['keys'], expected);
        },
      );
    }
  }
}
