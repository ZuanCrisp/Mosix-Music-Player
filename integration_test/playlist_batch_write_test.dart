import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/collection_track_batch.dart';

import '../test/support/library_collections_benchmark.dart';
import '../test/support/playlist_batch_benchmark.dart';

Future<String> _digest(Object value) => Isolate.run(
  () => sha256.convert(utf8.encode(jsonEncode(value))).toString(),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note': 'Five alternating paired samples. Heartbeat gaps are not FPS.',
  };
  late Directory root;
  late Database db;
  final now = DateTime.utc(2026, 10, 8);
  final stamp = now.toIso8601String();
  var completed = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('playlist-device-');
    final extensions = await Directory('${root.path}/extensions').create();
    final data = await Directory('${root.path}/data').create();
    final output = await Directory('${root.path}/output').create();
    await PlatformBridge.initExtensionSystem(
      extensions.path,
      data.path,
      masterKey: base64Encode(List<int>.filled(32, 1)),
      lyricsProviders: const [],
      lyricsFetchOptions: const {},
      allowedDirectories: [output.path],
    );
    final implementations = await PlatformBridge.getBackendImplementations();
    expect(implementations['extensions'], 'rust');
    db = await openDatabase(
      '${root.path}/library_collections.db',
      version: 2,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys=ON');
        await db.execute('PRAGMA recursive_triggers=ON');
        await db.execute('PRAGMA auto_vacuum=INCREMENTAL');
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=NORMAL');
        await db.rawQuery('PRAGMA busy_timeout=5000');
      },
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE playlists(id TEXT PRIMARY KEY,name TEXT NOT NULL,cover_image_path TEXT,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL,track_key TEXT NOT NULL,track_json TEXT NOT NULL,added_at TEXT NOT NULL,PRIMARY KEY(playlist_id,track_key),FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE)',
        );
        await db.execute(
          'CREATE INDEX idx_playlist_tracks_playlist_id ON playlist_tracks(playlist_id)',
        );
        for (final id in ['p', 'other']) {
          await db.insert('playlists', {
            'id': id,
            'name': id,
            'created_at': 'old',
            'updated_at': 'old',
          });
        }
      },
    );
  });

  tearDown(() async {
    await db.close();
    await PlatformBridge.cleanupExtensions();
    await root.delete(recursive: true);
  });

  tearDownAll(() {
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['playlist_batch_write'] = report;
  });

  Future<void> publish(
    PreparedCollectionTrackBatch batch, {
    String id = 'p',
  }) async {
    if (batch.rowsPath == null) {
      await LibraryCollectionsDatabase.writeDatabasePlaylistTracks(
        db,
        playlistId: id,
        playlistUpdatedAt: stamp,
        tracks: batch.rows,
      );
    } else {
      await publishPlaylistBatch(
        database: db,
        playlistId: id,
        updatedAt: stamp,
        rowsPath: batch.rowsPath!,
        expectedCount: batch.entries.length,
        temporaryDirectory: root,
      );
    }
  }

  // Preserve the pre-optimization single large sqflite batch as the baseline.
  Future<void> originalWrite(List<Map<String, String>> rows) =>
      db.transaction((txn) async {
        final batch = txn.batch();
        for (final row in rows) {
          batch.insert('playlist_tracks', {
            'playlist_id': 'p',
            ...row,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        batch.update(
          'playlists',
          {'updated_at': stamp},
          where: 'id=?',
          whereArgs: ['p'],
        );
        await batch.commit(noResult: true);
      });

  for (final count in [20, 256, 1024, 2048, 12000]) {
    testWidgets('playlist publication parity and paired timing ($count)', (
      tester,
    ) async {
      final unique = await playlistBatchFixture(count);
      final input = [...unique, unique.first, unique.last];
      final expected = inlinePlaylistBatch(input, const {}, now);
      final expectedDigest = await _digest(expected.rows);
      final baseline = <Map<String, int>>[];
      final optimized = <Map<String, int>>[];
      final playlist = UserPlaylistCollection(
        id: 'p',
        name: 'p',
        createdAt: now,
        updatedAt: now,
        tracks: const [],
      );
      for (var sample = 0; sample < 5; sample++) {
        for (final candidate in sample.isEven ? [false, true] : [true, false]) {
          await db.delete('playlist_tracks');
          await db.update('playlists', {'updated_at': 'old'});
          final result = await measureCollectionOperation(() async {
            late List<CollectionTrackEntry> additions;
            if (candidate) {
              final batch = await prepareCollectionTrackBatch(
                tracks: input,
                existingKeys: playlist.trackKeys,
                addedAt: now,
                temporaryDirectory: root,
              );
              try {
                expect(batch.duplicates, 2);
                expect(batch.rowsPath != null, count >= 2048);
                await publish(batch);
                additions = batch.entries;
              } finally {
                await batch.dispose();
              }
            } else {
              final batch = inlinePlaylistBatch(input, playlist.trackKeys, now);
              await originalWrite(batch.rows);
              additions = batch.entries;
            }
            // Include the same model publication in both timing paths.
            return playlist.copyWith(
              tracks: [...playlist.tracks, ...additions],
              updatedAt: now,
            );
          });
          expect(result.value.trackKeys.length, count);
          expect(
            result.value.tracks.map((entry) => entry.key),
            expected.entries.map((entry) => entry.key),
          );
          final persisted = await db.rawQuery(
            'SELECT track_key,track_json,added_at FROM playlist_tracks ORDER BY added_at ASC,rowid ASC',
          );
          expect(await _digest(persisted), expectedDigest);
          expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
          expect((await db.rawQuery('PRAGMA database_list')).length, 1);
          expect(
            await db.rawQuery(
              'SELECT id,updated_at FROM playlists ORDER BY id',
            ),
            [
              {'id': 'other', 'updated_at': 'old'},
              {'id': 'p', 'updated_at': stamp},
            ],
          );
          expect(
            await root
                .list()
                .where(
                  (entry) =>
                      entry.path.contains('playlist-input-') ||
                      entry.path.contains('playlist-stage-'),
                )
                .isEmpty,
            isTrue,
          );
          (candidate ? optimized : baseline).add(result.timing);
        }
      }
      report['$count'] = {'baseline': baseline, 'optimized': optimized};
      completed++;
      binding.reportData ??= {};
      binding.reportData!['playlist_batch_write'] = report;
    });
  }

  for (final count in [300, 2100]) {
    testWidgets('rollback and recovery through actual SQLite ($count)', (
      tester,
    ) async {
      final batch = await prepareCollectionTrackBatch(
        tracks: await playlistBatchFixture(count),
        existingKeys: const {},
        addedAt: now,
        temporaryDirectory: root,
      );
      try {
        await db.execute(
          "CREATE TRIGGER reject_update BEFORE UPDATE ON playlists BEGIN SELECT RAISE(ABORT,'fixture rollback'); END",
        );
        await expectLater(publish(batch), throwsA(isA<DatabaseException>()));
        expect(await db.rawQuery('SELECT * FROM playlist_tracks'), isEmpty);
        expect((await db.rawQuery('PRAGMA database_list')).length, 1);
        await db.execute('DROP TRIGGER reject_update');
        await expectLater(
          publish(batch, id: 'missing'),
          throwsA(isA<DatabaseException>()),
        );
        expect(await db.rawQuery('SELECT * FROM playlist_tracks'), isEmpty);
        await publish(batch);
        expect(
          Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM playlist_tracks'),
          ),
          count,
        );
        expect(await db.rawQuery('PRAGMA integrity_check'), [
          {'integrity_check': 'ok'},
        ]);
        completed++;
      } finally {
        await batch.dispose();
      }
    });
  }
}
