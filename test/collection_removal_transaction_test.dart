import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_collections_database.dart';

import 'support/sqlite_process_database.dart';

void main() {
  for (final kind in ['wishlist', 'loved', 'playlist']) {
    for (final failure in [
      'none',
      'row',
      if (kind == 'playlist') 'timestamp',
    ]) {
      test(
        '$kind removal preserves other rows and rolls back all chunks (failure: $failure)',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'collection-removal-',
          );
          final db = await SqliteProcessDatabase.open(
            path: '${root.path}/collections.db',
          );
          addTearDown(() async {
            await db.close();
            await root.delete(recursive: true);
          });
          final table = '${kind}_tracks';
          await db.execute(
            'CREATE TABLE playlists(id TEXT PRIMARY KEY,updated_at TEXT)',
          );
          await db.execute(
            "INSERT INTO playlists VALUES('p','old'),('other','old')",
          );
          await db.execute(
            kind == 'playlist'
                ? 'CREATE TABLE $table(playlist_id TEXT NOT NULL,track_key TEXT NOT NULL,track_json TEXT NOT NULL,added_at TEXT NOT NULL,PRIMARY KEY(playlist_id,track_key))'
                : 'CREATE TABLE $table(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL)',
          );
          final batch = db.batch();
          for (final playlist in ['p', if (kind == 'playlist') 'other']) {
            for (var index = 0; index < 301; index++) {
              batch.insert(table, {
                if (kind == 'playlist') 'playlist_id': playlist,
                'track_key': '$index',
                'track_json': '{"title":"音楽 $index"}',
                'added_at': 'original-$index',
              });
            }
          }
          await batch.commit(noResult: true);
          final before = await db.rawQuery(
            'SELECT rowid,* FROM $table ORDER BY rowid',
          );
          if (failure == 'row') {
            await db.execute(
              "CREATE TRIGGER reject_delete BEFORE DELETE ON $table WHEN old.track_key='150' BEGIN SELECT RAISE(ABORT,'denied'); END",
            );
          } else if (failure == 'timestamp') {
            await db.execute(
              "CREATE TRIGGER reject_delete BEFORE UPDATE ON playlists BEGIN SELECT RAISE(ABORT,'denied'); END",
            );
          }
          Future<void> remove(List<String> keys) => switch (kind) {
            'wishlist' =>
              LibraryCollectionsDatabase.deleteDatabaseWishlistTracks(db, keys),
            'loved' => LibraryCollectionsDatabase.deleteDatabaseLovedTracks(
              db,
              keys,
            ),
            _ => LibraryCollectionsDatabase.deleteDatabasePlaylistTracks(
              db,
              playlistId: 'p',
              trackKeys: keys,
              playlistUpdatedAt: 'new',
            ),
          };
          final operation = remove([for (var i = 0; i < 300; i++) '$i']);
          if (failure != 'none') {
            await expectLater(operation, throwsStateError);
            expect(
              await db.rawQuery('SELECT rowid,* FROM $table ORDER BY rowid'),
              before,
            );
            expect(
              await db.rawQuery('SELECT updated_at FROM playlists WHERE id=?', [
                'p',
              ]),
              [
                {'updated_at': 'old'},
              ],
            );
            await db.execute('DROP TRIGGER reject_delete');
            await remove([for (var i = 0; i < 300; i++) '$i']);
          } else {
            await operation;
          }
          expect(
            await db.rawQuery('SELECT rowid,* FROM $table ORDER BY rowid'),
            [
              for (final row in before)
                if (row['track_key'] == '300' ||
                    (kind == 'playlist' && row['playlist_id'] == 'other'))
                  row,
            ],
          );
          final playlists = await db.rawQuery(
            'SELECT * FROM playlists ORDER BY rowid',
          );
          expect(playlists, [
            {'id': 'p', 'updated_at': kind == 'playlist' ? 'new' : 'old'},
            {'id': 'other', 'updated_at': 'old'},
          ]);
          await remove(const []);
          expect(
            await db.rawQuery('SELECT * FROM playlists ORDER BY rowid'),
            playlists,
          );
        },
      );
    }
  }
}
