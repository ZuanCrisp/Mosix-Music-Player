import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

Map<String, dynamic> nativeLibraryTrack(
  String id, {
  String? path,
  int? timestamp = 1770000000000,
  int version = 4,
}) => {
  'id': id,
  'trackName': 'Track $id',
  'artistName': ' CAFÉ İ 音楽 ',
  'albumName': 'Album',
  'albumArtist': null,
  'filePath': path ?? '/music/$id.flac',
  'scannedAt': '2026-10-07T12:00:00.000Z',
  'fileModTime': timestamp,
  'audioMetadataScanVersion': version,
  'explicit': true,
  'hasLyrics': true,
  'hasReplayGain': true,
  'bitDepth': 24,
  'sampleRate': 96000,
};

Future<void> createNativeLibraryFixture(
  Database db, {
  String historyPath = ':memory:',
}) async {
  await LibrarySchema.create(db, LibrarySchema.version);
  await db.execute('PRAGMA user_version = ${LibrarySchema.version}');
  await db.execute('PRAGMA recursive_triggers = ON');
  await db.execute('ATTACH DATABASE ? AS history_db', [historyPath]);
  await db.execute(
    'CREATE TABLE history_db.history_path_keys('
    'item_id TEXT NOT NULL,path_key TEXT NOT NULL,PRIMARY KEY(item_id,path_key))',
  );
  await db.execute(
    'CREATE INDEX history_db.history_key_index '
    'ON history_path_keys(path_key)',
  );
  for (final source in ['source', 'other']) {
    await db.insert('library_sources', {
      'id': source,
      'path': source == 'source' ? '/music' : '/other',
      'display_name': source,
    });
  }
}

Future<void> addNativeLibraryTrack(
  DatabaseExecutor db,
  Map<String, dynamic> track, {
  String source = 'source',
}) async {
  await db.insert(
    'library',
    LibraryRowMapper.encode(track, sourceId: source),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  await db.delete(
    'library_path_keys',
    where: 'item_id = ?',
    whereArgs: [track['id']],
  );
  final batch = db.batch();
  sqlite.putPathKeysInBatch(
    batch,
    'library_path_keys',
    track['id'] as String,
    track['filePath'] as String,
  );
  await batch.commit(noResult: true);
}

Future<void> addNativeLibraryDownload(DatabaseExecutor db, String path) async {
  final batch = db.batch();
  sqlite.putPathKeysInBatch(
    batch,
    'history_db.history_path_keys',
    'download-$path',
    path,
  );
  await batch.commit(noResult: true);
}

Future<Map<String, Object?>> nativeLibraryDigest(DatabaseExecutor db) async => {
  'rows': await db.rawQuery('SELECT * FROM library ORDER BY id'),
  'keys': await db.rawQuery(
    'SELECT * FROM library_path_keys ORDER BY item_id,path_key',
  ),
  'lookup': await db.rawQuery(
    'SELECT * FROM library_lookup_summary ORDER BY source_id,kind,value',
  ),
  if ((await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE name='library_search_fts'",
  )).isNotEmpty)
    'fts': await db.rawQuery(
      "SELECT rowid FROM library_search_fts WHERE library_search_fts MATCH 'track' ORDER BY rowid",
    ),
};
