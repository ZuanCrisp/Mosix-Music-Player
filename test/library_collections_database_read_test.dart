import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_collections_hydration.dart';

import 'support/sqlite_process_database.dart';

// Host parity executes the production keyset SQL against real SQLite. Device
// integration separately covers the sqflite channel and Rust read route.
class _ReadDatabase implements Database, Transaction {
  _ReadDatabase(this.database);
  @override
  final SqliteProcessDatabase database;
  @override
  String get path => database.path;
  final pageSizes = <int>[];
  bool failProjection = false;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) => database.transaction((_) => action(this), exclusive: exclusive);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) {
    if (failProjection && sql.startsWith('CREATE TABLE collection_read_')) {
      throw StateError('projection failed');
    }
    return database.execute(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    final rows = await database.rawQuery(sql, arguments);
    pageSizes.add(rows.length);
    return rows;
  }

  @override
  Future<void> close() => database.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_ReadDatabase> _fixture(String path, int count) async {
  final result = await Process.run('python3', [
    '-c',
    r"""
import json,sqlite3,sys
db=sqlite3.connect(sys.argv[1]); count=int(sys.argv[2])
db.executescript('''PRAGMA user_version=2;
CREATE TABLE wishlist_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL);
CREATE TABLE loved_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL);
CREATE TABLE favorite_artists(artist_key TEXT PRIMARY KEY,artist_json TEXT NOT NULL,added_at TEXT NOT NULL);
CREATE TABLE playlists(id TEXT PRIMARY KEY,name TEXT NOT NULL,cover_image_path TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL);
CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL,track_key TEXT NOT NULL,track_json TEXT NOT NULL,added_at TEXT NOT NULL,PRIMARY KEY(playlist_id,track_key));''')
for p in range(4):
 db.execute('INSERT INTO playlists VALUES(?,?,?,?,?)',(str(p),'音楽 '+str(p),'/custom.jpg' if p==1 else None,'2026-10-01','2026-10-01'))
for i in range(count):
 track=json.dumps(dict(id=str(i),name='Track '+str(i),artistName='Artist',albumName='Album',duration=180,coverUrl='cover-'+str(i)),ensure_ascii=False)
 date='2026-10-0'+str(i%3+1)
 db.execute('INSERT INTO wishlist_tracks VALUES(?,?,?)',('example:'+str(i),track,date))
 db.execute('INSERT INTO playlist_tracks VALUES(?,?,?,?)',(str(i%4),'example:'+str(i),track,date))
db.execute('INSERT INTO loved_tracks VALUES(?,?,?)',('corrupt','{','2026-10-01'))
db.execute('INSERT INTO favorite_artists VALUES(?,?,?)',('example:artist',json.dumps(dict(artistId='artist',providerId='example',name='İstanbul')),'2026-10-01'))
db.commit()
""",
    path,
    '$count',
  ]);
  if (result.exitCode != 0) throw StateError(result.stderr.toString());
  final db = _ReadDatabase(await SqliteProcessDatabase.open(path: path));
  addTearDown(db.close);
  return db;
}

Future<LibraryCollectionsSnapshot> _legacy(
  _ReadDatabase db,
) async => LibraryCollectionsSnapshot(
  wishlistRows: await db.rawQuery(
    'SELECT * FROM wishlist_tracks ORDER BY added_at DESC,rowid DESC',
  ),
  lovedRows: await db.rawQuery(
    'SELECT * FROM loved_tracks ORDER BY added_at DESC,rowid DESC',
  ),
  favoriteArtistRows: await db.rawQuery(
    'SELECT * FROM favorite_artists ORDER BY added_at DESC,rowid DESC',
  ),
  playlistRows: await db.rawQuery(
    """SELECT p.*,CASE WHEN p.cover_image_path IS NULL OR p.cover_image_path='' THEN
    (SELECT pt.track_json FROM playlist_tracks pt WHERE pt.playlist_id=p.id ORDER BY pt.added_at ASC,pt.rowid ASC LIMIT 1)
    END AS preview_track_json FROM playlists p ORDER BY p.created_at DESC,p.rowid DESC""",
  ),
  playlistTrackRows: await db.rawQuery(
    'SELECT playlist_id,track_key FROM playlist_tracks ORDER BY playlist_id ASC,rowid ASC',
  ),
);

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('collection-db-read-test-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'keyset pages preserve all original query rows and tied-date ordering',
    () async {
      final db = await _fixture('${root.path}/library_collections.db', 1200);
      final actual = await LibraryCollectionsDatabase.readDatabaseSnapshot(
        db,
        forceLegacy: true,
      );
      expect(db.pageSizes.every((size) => size <= 256), isTrue);
      final expected = await _legacy(db);
      expect(actual.wishlistRows, expected.wishlistRows);
      expect(actual.lovedRows, expected.lovedRows);
      expect(actual.favoriteArtistRows, expected.favoriteArtistRows);
      expect(actual.playlistRows, expected.playlistRows);
      expect(actual.playlistTrackRows, expected.playlistTrackRows);
      db.pageSizes.clear();
      final tracks =
          await LibraryCollectionsDatabase.readDatabasePlaylistTracks(
            db,
            '1',
            forceLegacy: true,
          );
      expect(db.pageSizes.every((size) => size <= 256), isTrue);
      expect(
        tracks.rows,
        await db.rawQuery(
          'SELECT * FROM playlist_tracks WHERE playlist_id=? ORDER BY added_at ASC,rowid ASC',
          ['1'],
        ),
      );
    },
  );

  test(
    'small collection stays on bounded SQLite reads without native job',
    () async {
      final db = await _fixture('${root.path}/library_collections.db', 3);
      final snapshot = await LibraryCollectionsDatabase.readDatabaseSnapshot(
        db,
        temporaryDirectory: root,
        nativeJobRunner: (_) async => throw StateError('must not run'),
      );
      expect(snapshot.nativeRowsPath, isNull);
      expect(snapshot.wishlistRows.length, 3);
      expect(db.pageSizes.every((size) => size <= 64), isTrue);
    },
  );

  test(
    'large read routes only probe and staged path, hydrates and cleans',
    () async {
      final db = await _fixture('${root.path}/library_collections.db', 600);
      final expected = await _legacy(db);
      db.pageSizes.clear();
      var calls = 0;
      final snapshot = await LibraryCollectionsDatabase.readDatabaseSnapshot(
        db,
        temporaryDirectory: root,
        nativeJobRunner: (request) async {
          calls++;
          expect(request['operation'], 'collections_snapshot');
          final projectedPath = request['collections_path'] as String;
          expect(projectedPath, isNot(db.path));
          expect(
            File(projectedPath).parent.path,
            File(request['output_path'] as String).parent.path,
          );
          final attached = await db.database.rawQuery('PRAGMA database_list');
          expect(attached.map((row) => row['name']), ['main']);
          final projectedDb = _ReadDatabase(
            await SqliteProcessDatabase.open(path: projectedPath),
          );
          late LibraryCollectionsSnapshot projected;
          try {
            projected = await _legacy(projectedDb);
            expect(projected.wishlistRows, expected.wishlistRows);
            expect(projected.lovedRows, expected.lovedRows);
            expect(projected.playlistRows, expected.playlistRows);
            expect(projected.playlistTrackRows, expected.playlistTrackRows);
            expect(projected.favoriteArtistRows, expected.favoriteArtistRows);
          } finally {
            await projectedDb.close();
          }
          // Changing the live rows after DETACH cannot change this read's
          // already captured projection or its hydrated membership snapshot.
          await db.execute("DELETE FROM playlist_tracks WHERE playlist_id='0'");
          final rows = [
            for (final row in projected.wishlistRows)
              {'kind': 'wishlist', 'row': row},
            for (final row in projected.lovedRows)
              {'kind': 'loved', 'row': row},
            for (final row in projected.playlistRows)
              {'kind': 'playlist', 'row': row},
            for (final row in projected.playlistTrackRows)
              {'kind': 'membership', 'row': row},
            for (final row in projected.favoriteArtistRows)
              {'kind': 'artist', 'row': row},
          ];
          await File(
            request['output_path'] as String,
          ).writeAsString(rows.map(jsonEncode).join('\n'));
          return {
            'published': true,
            'rows_path': request['output_path'],
            'counts': {'rows': rows.length},
          };
        },
      );
      expect(calls, 1);
      expect(db.pageSizes, [64]);
      expect(snapshot.wishlistRows, isEmpty);
      final stagedDirectory = snapshot.nativeRowsDirectory!;
      final actual = await hydrateLibraryCollectionsSnapshot(snapshot);
      expect(
        jsonEncode(actual.toJson()),
        jsonEncode(decodeLibraryCollectionsSnapshot(expected).toJson()),
      );
      for (final playlist in actual.playlists) {
        expect(playlist.trackCount, 150);
      }
      expect(await Directory(stagedDirectory).exists(), isFalse);
    },
  );

  test(
    'lazy read projects only the selected playlist and preserves ties',
    () async {
      final db = await _fixture('${root.path}/library_collections.db', 800);
      final expected = await db.rawQuery(
        'SELECT * FROM playlist_tracks WHERE playlist_id=? ORDER BY added_at ASC,rowid ASC',
        ['1'],
      );
      final snapshot =
          await LibraryCollectionsDatabase.readDatabasePlaylistTracks(
            db,
            '1',
            temporaryDirectory: root,
            nativeJobRunner: (request) async {
              expect(request['playlist_id'], '1');
              final projectedPath = request['collections_path'] as String;
              expect(projectedPath, isNot(db.path));
              final projected = await SqliteProcessDatabase.open(
                path: projectedPath,
              );
              try {
                for (final table in [
                  'wishlist_tracks',
                  'loved_tracks',
                  'favorite_artists',
                ]) {
                  expect(
                    await projected.rawQuery('SELECT * FROM $table'),
                    isEmpty,
                  );
                }
                expect(await projected.rawQuery('SELECT id FROM playlists'), [
                  {'id': '1'},
                ]);
                expect(await projected.rawQuery('PRAGMA user_version'), [
                  {'user_version': 2},
                ]);
                final rows = await projected.rawQuery(
                  'SELECT * FROM playlist_tracks ORDER BY added_at ASC,rowid ASC',
                );
                expect(rows, expected);
                await File(request['output_path'] as String).writeAsString(
                  rows
                      .map(
                        (row) =>
                            jsonEncode({'kind': 'playlist_track', 'row': row}),
                      )
                      .join('\n'),
                );
                return {
                  'published': true,
                  'rows_path': request['output_path'],
                  'counts': {'playlist_track': rows.length},
                };
              } finally {
                await projected.close();
              }
            },
          );
      final staged = snapshot.nativeRowsDirectory!;
      final tracks = await hydratePlaylistTracksSnapshot(
        snapshot,
        knownKeys: expected.map((row) => row['track_key'] as String).toSet(),
      );
      expect(tracks.membershipUnchanged, true);
      expect(tracks.tracks, hasLength(200));
      expect(await Directory(staged).exists(), false);
    },
  );

  test(
    'failed projection detaches private database and removes staging',
    () async {
      final db = await _fixture('${root.path}/library_collections.db', 80);
      db.failProjection = true;
      await expectLater(
        LibraryCollectionsDatabase.readDatabaseSnapshot(
          db,
          temporaryDirectory: root,
          nativeJobRunner: (_) async => throw StateError('must not run'),
        ),
        throwsStateError,
      );
      final databases = await db.database.rawQuery('PRAGMA database_list');
      expect(databases.map((row) => row['name']), ['main']);
      expect(
        await File(databases.single['file'] as String).resolveSymbolicLinks(),
        await File(db.path).resolveSymbolicLinks(),
      );
      expect(root.listSync().whereType<Directory>(), isEmpty);
      expect(await db.database.rawQuery('PRAGMA integrity_check'), [
        {'integrity_check': 'ok'},
      ]);
      db.failProjection = false;
      final rows = await LibraryCollectionsDatabase.readDatabaseSnapshot(
        db,
        forceLegacy: true,
      );
      expect(rows.wishlistRows, hasLength(80));
    },
  );

  test(
    'bad native result and native failure remove their staged directories',
    () async {
      final db = await _fixture('${root.path}/library_collections.db', 80);
      for (final fail in [true, false]) {
        await expectLater(
          LibraryCollectionsDatabase.readDatabaseSnapshot(
            db,
            temporaryDirectory: root,
            nativeJobRunner: (request) async {
              await File(
                request['output_path'] as String,
              ).writeAsString('partial');
              if (fail) throw StateError('cancelled');
              return {
                'published': true,
                'rows_path': request['output_path'],
                'counts': {'rows': -1},
              };
            },
          ),
          throwsA(anything),
        );
        expect(root.listSync().whereType<Directory>(), isEmpty);
      }
    },
  );
}
