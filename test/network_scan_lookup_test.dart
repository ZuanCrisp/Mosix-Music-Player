import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_ingestion_store.dart';

import 'support/library_native_fixture.dart';
import 'support/sqlite_process_database.dart';

class _LookupDatabase implements Database {
  _LookupDatabase(this._database);

  final Database _database;
  List<Map<String, Object?>> plan = [];

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    plan = await _database.rawQuery('EXPLAIN QUERY PLAN $sql', arguments);
    return _database.rawQuery(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => rawQuery('SELECT * FROM $table WHERE $where', whereArgs);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'network cache batches seek file paths instead of scanning a source',
    () async {
      final database = await SqliteProcessDatabase.open();
      addTearDown(database.close);
      await createNativeLibraryFixture(database);
      await database.execute('''
      WITH RECURSIVE tracks(n) AS (
        SELECT 1 UNION ALL SELECT n + 1 FROM tracks WHERE n < 2000
      )
      INSERT INTO library (
        id, source_id, file_path, track_name, artist_name, album_name, scanned_at
      )
      SELECT 'track-' || n, 'source', 'network://nas/' || n || '.flac',
             'Track ' || n, 'Artist', 'Album', '2026-10-20T00:00:00.000'
      FROM tracks
    ''');
      final lookup = _LookupDatabase(database);
      final store = LibraryIngestionStore(
        openDatabase: () async => lookup,
        ensureHistoryAttached: (_) async {},
      );

      for (final count in [1, 64]) {
        final paths = List.generate(
          count,
          (i) => 'network://nas/${i + 1}.flac',
        );
        final rows = await store.readNetworkScanRows('source', paths);
        expect(rows.keys, unorderedEquals(paths));
        expect(rows[paths.first]!['trackName'], 'Track 1');
        expect(
          lookup.plan.map((row) => row['detail']).join('\n'),
          contains('(file_path=?)'),
          reason: 'Each batch must seek its paths, not all rows of the source.',
        );
        expect(await store.readNetworkScanRows('other', paths), isEmpty);
      }
      expect(
        await store.readNetworkScanRows('source', [
          'network://nas/missing.flac',
        ]),
        isEmpty,
      );
    },
  );
}
