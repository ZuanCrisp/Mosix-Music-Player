import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_collections_database.dart';

import 'support/playlist_deletion_fixture.dart';
import 'support/sqlite_process_database.dart';

void main() {
  for (final failure in ['none', 'parent', 'cascade']) {
    test('playlist deletion cascades atomically (failure: $failure)', () async {
      final db = await SqliteProcessDatabase.open();
      addTearDown(db.close);
      await createPlaylistDeletionSchema(db);
      await seedPlaylistDeletion(db, 300, tracksPerPlaylist: 2);
      final before = await playlistDeletionSnapshot(db);
      final keys = [
        for (var i = 0; i < 300; i++) 'playlist-$i',
        'missing',
        'playlist-0',
      ];
      if (failure != 'none') {
        final table = failure == 'parent' ? 'playlists' : 'playlist_tracks';
        final column = failure == 'parent' ? 'id' : 'playlist_id';
        await db.execute(
          "CREATE TRIGGER reject_delete BEFORE DELETE ON $table WHEN old.$column='playlist-150' BEGIN SELECT RAISE(ABORT,'denied'); END",
        );
        await expectLater(
          LibraryCollectionsDatabase.deleteDatabasePlaylists(db, keys),
          throwsStateError,
        );
        expect(await playlistDeletionSnapshot(db), before);
        await db.execute('DROP TRIGGER reject_delete');
      }
      await LibraryCollectionsDatabase.deleteDatabasePlaylists(db, keys);
      final after = await playlistDeletionSnapshot(db);
      expect(
        after['playlists'],
        before['playlists']!.where((p) => p['id'] == "keep'quoted"),
      );
      expect(
        after['playlist_tracks'],
        before['playlist_tracks']!.where(
          (p) => p['playlist_id'] == "keep'quoted",
        ),
      );
      for (final table in ['wishlist_tracks', 'loved_tracks']) {
        expect(after[table], before[table]);
      }
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      await LibraryCollectionsDatabase.deleteDatabasePlaylists(db, keys);
      await LibraryCollectionsDatabase.deleteDatabasePlaylists(db, []);
      expect(await playlistDeletionSnapshot(db), after);
      await LibraryCollectionsDatabase.deleteDatabasePlaylists(db, [
        "keep'quoted",
      ]);
      expect(await db.query('playlists'), isEmpty);
      expect(await db.query('playlist_tracks'), isEmpty);
      expect(await db.query('loved_tracks'), hasLength(2));
    });
  }
}
