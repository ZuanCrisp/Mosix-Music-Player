import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/album_completeness.dart';

String _tableDefinition(String path, String table) => RegExp(
  'CREATE TABLE $table\\s*\\([\\s\\S]*?\\n\\s*\\)',
).firstMatch(File(path).readAsStringSync())!.group(0)!;

void main() {
  test(
    'album assessment counts unique positions and rejects uncertain tags',
    () async {
      final result = await Process.run('python3', [
        '-c',
        r'''
import json, sqlite3, sys
query = json.loads(sys.argv[1])
db = sqlite3.connect(':memory:')
db.row_factory = sqlite3.Row
db.execute('CREATE TABLE tracks (album_key TEXT, title TEXT, track_number INTEGER, '
           'total_tracks INTEGER, disc_number INTEGER, total_discs INTEGER, unavailable INTEGER)')
def add(album, positions, total, disc=1, discs=1, unavailable=0):
    for track in positions:
        db.execute('INSERT INTO tracks VALUES (?,?,?,?,?,?,?)',
                   (album, 'Song '+str(track), track, total, disc, discs, unavailable))
add('complete', [1,2,3], 3)
add('gap', [1,3], 3)
add('one-track-album', [1], 12)
add('duplicate-incomplete', [1,1,2], 3)
add('duplicate-complete', [1,1,2], 2)
add('conflicting-total', [1], 3)
add('conflicting-total', [2], 4)
add('missing-total', [1,2], None)
add('missing-number', [0,1], 3)
add('out-of-range', [1,4], 3)
add('offline', [1,2], 3, unavailable=1)
add('disc-gap', [1,2], 2, disc=1, discs=2)
add('multi-incomplete', [1,2], 2, disc=1, discs=2)
add('multi-incomplete', [1], 3, disc=2, discs=2)
add('multi-complete', [1,2], 2, disc=1, discs=2)
add('multi-complete', [1,2,3], 3, disc=2, discs=2)
add('ambiguous', [1], 2, disc=1, discs=2)
add('ambiguous', [1], 2, disc=2, discs=2)
add('ambiguous-but-missing', [1], 10, disc=1, discs=2)
add('ambiguous-but-missing', [1], 10, disc=2, discs=2)
add('conflicting-discs', [1], 3, disc=1, discs=1)
add('conflicting-discs', [2], 3, disc=1, discs=2)
add('invalid-total', [1], 3)
add('invalid-total', [2], -1)
add('invalid-disc-total', [1], 3)
add('invalid-disc-total', [2], 3, discs=-1)
add('missing-disc-number', [1], 3, disc=0, discs=2)
add('conflicting-position', [1], 3)
db.execute("INSERT INTO tracks VALUES ('conflicting-position','Other title',1,3,1,1,0)")
rows = {row['album_key']: dict(row) for row in db.execute(query)}
def check(album, status, present, expected):
    row = rows[album]
    assert row['album_completeness'] == status, (album, row)
    assert row['album_present_tracks'] == present, (album, row)
    assert row['album_expected_tracks'] == expected, (album, row)
check('complete', 'complete', 3, 3)
check('gap', 'incomplete', 2, 3)
check('one-track-album', 'incomplete', 1, 12)
check('duplicate-incomplete', 'incomplete', 2, 3)
check('duplicate-complete', 'complete', 2, 2)
check('multi-incomplete', 'incomplete', 3, 5)
check('multi-complete', 'complete', 5, 5)
check('disc-gap', 'incomplete', 2, None)
check('ambiguous-but-missing', 'incomplete', 2, None)
for album in ['conflicting-total','missing-total','missing-number','out-of-range',
              'offline','ambiguous','conflicting-discs','missing-disc-number','conflicting-position',
              'invalid-total','invalid-disc-total']:
    assert rows[album]['album_completeness'] == 'unknown', (album, rows[album])
    assert rows[album]['album_expected_tracks'] is None, (album, rows[album])
# Filter membership must follow changes to tags and the inventory.
db.execute("INSERT INTO tracks VALUES ('gap','Song 2',2,3,1,1,0)")
missing = [row[0] for row in db.execute('SELECT album_key FROM ('+query+") WHERE album_completeness = 'incomplete'")]
assert 'gap' not in missing and 'one-track-album' in missing, missing
print('assessment passed')
''',
        jsonEncode(albumCompletenessSql('SELECT * FROM main.tracks')),
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('assessment passed'));
    },
  );

  test(
    'inventory combines both databases, deduplicates stored paths and retains offline evidence',
    () async {
      final result = await Process.run('python3', [
        '-c',
        r'''
import json, sqlite3, sys
data = json.loads(sys.argv[1])
db = sqlite3.connect(':memory:')
db.row_factory = sqlite3.Row
db.execute("ATTACH DATABASE ':memory:' AS history_db")
db.execute(data['history'].replace('CREATE TABLE history', 'CREATE TABLE history_db.history', 1))
db.execute(data['library'])
db.execute('CREATE TABLE library_sources (id TEXT PRIMARY KEY, enabled INTEGER, available INTEGER)')
for table in ['library_path_keys', 'history_db.history_path_keys']:
    db.execute('CREATE TABLE '+table+' (item_id TEXT, path_key TEXT)')
db.execute("INSERT INTO library_sources VALUES ('internal',1,1)")
db.execute("INSERT INTO library_sources VALUES ('sd',1,0)")
def add(local, id, album, number, path=None, source='internal'):
    table = 'library' if local else 'history_db.history'
    path = path or '/'+id+'.flac'
    fields = dict(id=id, track_name='Song '+str(number), artist_name='Artist',
                  album_name=album, album_key=album, file_path=path, track_number=number,
                  total_tracks=4, disc_number=1, total_discs=1)
    fields.update(dict(scanned_at='2026-01-01', source_id=source) if local
                  else dict(downloaded_at='2026-01-01', service='example-provider'))
    db.execute('INSERT INTO '+table+' ('+','.join(fields)+') VALUES ('+','.join('?' for _ in fields)+')', list(fields.values()))
    keys = 'library_path_keys' if local else 'history_db.history_path_keys'
    db.execute('INSERT INTO '+keys+' VALUES (?,?)', (id,path))
add(False, 'dl1', 'mixed', 1)
add(False, 'dl2', 'mixed', 2)
add(True, 'local1', 'mixed', 1, '/dl1.flac')
add(True, 'local3', 'mixed', 3)
add(True, 'local4', 'mixed', 4)
add(True, 'offline1', 'offline', 1, source='sd')
add(False, 'dl-offline', 'offline', 1, '/offline1.flac')
add(True, 'offline2', 'offline', 2, source='sd')
def rows(query):
    return {row['album_key']: dict(row) for row in db.execute(query)}
combined = rows(data['combined'])
assert combined['mixed']['album_completeness'] == 'complete', combined
assert combined['mixed']['album_present_tracks'] == 4, combined
assert combined['offline']['album_completeness'] == 'unknown', combined
downloads = rows(data['downloads'])
assert downloads['mixed']['album_completeness'] == 'incomplete', downloads
assert downloads['mixed']['album_present_tracks'] == 2, downloads
db.execute("DELETE FROM library WHERE id = 'local4'")
assert rows(data['combined'])['mixed']['album_completeness'] == 'incomplete'
print('inventory passed')
''',
        jsonEncode({
          'history': _tableDefinition(
            'lib/services/history_schema.dart',
            'history',
          ),
          'library': _tableDefinition(
            'lib/services/library_schema.dart',
            'library',
          ),
          'combined': albumCompletenessSql(
            albumInventorySql(includeLocal: true),
          ),
          'downloads': albumCompletenessSql(
            albumInventorySql(includeLocal: false),
          ),
        }),
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('inventory passed'));
    },
  );

  test(
    'badge distinguishes a known count, missing disc and unknown metadata',
    () {
      expect(
        const AlbumCompleteness(
          status: 'incomplete',
          present: 8,
          expected: 12,
        ).badge,
        '8/12',
      );
      expect(
        const AlbumCompleteness(status: 'incomplete', present: 8).badge,
        '8/?',
      );
      expect(const AlbumCompleteness(status: 'unknown', present: 8).badge, '?');
      expect(AlbumCompleteness.fromRow({}), isNull);
    },
  );
}
