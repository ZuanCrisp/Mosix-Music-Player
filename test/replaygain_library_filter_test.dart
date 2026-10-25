import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_database.dart';

String _tableDefinition(String path, String table) {
  final source = File(path).readAsStringSync();
  return RegExp(
    'CREATE TABLE $table\\s*\\([\\s\\S]*?\\n\\s*\\)',
  ).firstMatch(source)!.group(0)!;
}

void main() {
  test(
    'ReplayGain filter includes unindexed candidates and follows tag add/remove in both databases',
    () async {
      final historyPredicate = missingReplayGainSqlPredicate(
        hasReplayGainExpr: 'has_replaygain',
      );
      final localPredicate = missingReplayGainSqlPredicate(
        hasReplayGainExpr: 'has_replaygain',
      );
      // Use the production table definitions and filter predicates with real
      // SQLite. This catches missing schema columns and NULL/default semantics.
      final result = await Process.run('python3', [
        '-c',
        r'''
import json, sqlite3, sys
data = json.loads(sys.argv[1])
db = sqlite3.connect(':memory:')
db.execute(data['history'])
db.execute(data['library'])
for table, version, known, predicate in [
    ('history', 'replaygain_metadata_scan_version', 1, data['historyPredicate']),
    ('library', 'audio_metadata_scan_version', data['scanVersion'], data['localPredicate']),
]:
    for name, gain, scanned in [('unknown', 0, 0), ('legacy', 0, known - 1),
                                ('tagged', 1, known), ('missing', 0, known),
                                ('legacy-tagged', 1, 0)]:
        db.execute(f'INSERT INTO {table} (id, track_name, artist_name, album_name, file_path, '
                   + ('downloaded_at, service' if table == 'history' else 'scanned_at, source_id')
                   + f', has_replaygain, {version}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                   (name, 'Track', 'Artist', 'Album', '/'+name+'.flac', '2026-01-01', 'test', gain, scanned))
    def matches():
        return [row[0] for row in db.execute(f'SELECT id FROM {table} WHERE {predicate} ORDER BY id')]
    assert matches() == ['legacy', 'missing', 'unknown'], (table, matches())
    db.execute(f"UPDATE {table} SET has_replaygain = 1 WHERE id = 'missing'")
    assert matches() == ['legacy', 'unknown'], (table, matches())
    db.execute(f"UPDATE {table} SET has_replaygain = 0 WHERE id = 'tagged'")
    assert matches() == ['legacy', 'tagged', 'unknown'], (table, matches())
    # An entirely unindexed collection without ReplayGain must not look empty.
    db.execute(f'UPDATE {table} SET has_replaygain = 0, {version} = 0')
    assert len(matches()) == 5, (table, matches())
print('both databases passed')
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
          'historyPredicate': historyPredicate,
          'localPredicate': localPredicate,
          'scanVersion': LibraryDatabase.audioMetadataScanVersion,
        }),
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('both databases passed'));
    },
  );
}
