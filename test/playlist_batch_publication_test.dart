import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/collection_track_batch.dart';
import 'package:mornye/services/library_collections_database.dart';

import 'support/sqlite_process_database.dart';

class _DetachFailure implements Database {
  _DetachFailure(this.database);
  @override
  final SqliteProcessDatabase database;

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    if (sql.startsWith('DETACH DATABASE')) throw StateError('detach failed');
    await database.execute(sql, args);
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) => database.transaction(action, exclusive: exclusive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late SqliteProcessDatabase live;
  late String input;
  String? retainedStage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('playlist-publication-');
    live = await SqliteProcessDatabase.open(path: '${root.path}/live.db');
    await live.execute('PRAGMA foreign_keys=ON');
    await live.execute(
      'CREATE TABLE playlists(id TEXT PRIMARY KEY, name TEXT, updated_at TEXT)',
    );
    await live.execute(
      'CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL, track_key TEXT NOT NULL, track_json TEXT NOT NULL, added_at TEXT NOT NULL, PRIMARY KEY(playlist_id,track_key), FOREIGN KEY(playlist_id) REFERENCES playlists(id))',
    );
    await live.execute('CREATE TABLE published(track_key TEXT)');
    await live.execute(
      'CREATE TABLE loved_tracks(track_key TEXT PRIMARY KEY,track_json TEXT NOT NULL,added_at TEXT NOT NULL)',
    );
    await live.execute(
      'CREATE TRIGGER audit AFTER INSERT ON playlist_tracks BEGIN INSERT INTO published VALUES(new.track_key); END',
    );
    await live.execute("INSERT INTO playlists VALUES('p','Original','old')");
    await live.execute("INSERT INTO playlists VALUES('other','Other','old')");
    await live.execute(
      "INSERT INTO playlist_tracks VALUES('p','existing','{}','old')",
    );
    await live.execute('DELETE FROM published');
    input = '${root.path}/rows.ndjson';
    await File(input).writeAsString('');
    retainedStage = null;
  });
  tearDown(() async {
    await live.close();
    await root.delete(recursive: true);
  });

  // This fixture implements only the native boundary. SQL publication below
  // runs on real SQLite; the native parser itself has Rust and device tests.
  Future<Map<String, dynamic>> stage(Map<String, dynamic> request) async {
    expect(request['operation'], 'collections_stage_playlist_additions');
    expect(request.values, isNot(contains(live.path)));
    expect((await live.rawQuery('PRAGMA database_list')).length, 1);
    final path = request['output_path'] as String;
    retainedStage = path;
    final private = await SqliteProcessDatabase.open(path: path);
    try {
      await private.execute(
        'CREATE TABLE playlist_additions(position INTEGER PRIMARY KEY,track_key TEXT UNIQUE,track_json TEXT)',
      );
      for (final key in ['new-a', 'new-b']) {
        await private.execute(
          'INSERT INTO playlist_additions(track_key,track_json) VALUES(?,?)',
          [
            key,
            jsonEncode({'id': key, 'name': '音楽 🎵'}),
          ],
        );
      }
    } finally {
      await private.close();
    }
    return {'committed': true, 'published': true, 'path': path, 'count': 2};
  }

  Future<void> publish({
    Database? database,
    String playlist = 'p',
    Future<Map<String, dynamic>> Function(Map<String, dynamic>)? runner,
  }) => publishPlaylistBatch(
    database: database ?? live,
    playlistId: playlist,
    updatedAt: 'new',
    rowsPath: input,
    expectedCount: 2,
    temporaryDirectory: root,
    nativeJobRunner: runner ?? stage,
  );

  test(
    'publishes in order through live triggers and changes only target timestamp',
    () async {
      await publish();
      expect(
        (await live.rawQuery(
          'SELECT track_key FROM playlist_tracks ORDER BY rowid',
        )).map((row) => row['track_key']),
        ['existing', 'new-a', 'new-b'],
      );
      expect(await live.rawQuery('SELECT * FROM published'), [
        {'track_key': 'new-a'},
        {'track_key': 'new-b'},
      ]);
      expect(
        await live.rawQuery(
          'SELECT id,name,updated_at FROM playlists ORDER BY rowid',
        ),
        [
          {'id': 'p', 'name': 'Original', 'updated_at': 'new'},
          {'id': 'other', 'name': 'Other', 'updated_at': 'old'},
        ],
      );
      expect(await live.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect((await live.rawQuery('PRAGMA database_list')).length, 1);
      expect(await File(retainedStage!).exists(), false);
    },
  );

  for (final fail in [false, true]) {
    test('shared staging publishes Loved atomically (failure: $fail)', () async {
      if (fail) {
        await live.execute(
          "CREATE TRIGGER fail_loved BEFORE INSERT ON loved_tracks WHEN new.track_key='new-b' BEGIN SELECT RAISE(ABORT,'denied'); END",
        );
      }
      final operation = publishLovedBatch(
        database: live,
        addedAt: 'new',
        rowsPath: input,
        expectedCount: 2,
        nativeJobRunner: stage,
        temporaryDirectory: root,
      );
      if (fail) {
        await expectLater(operation, throwsA(isA<StateError>()));
        expect(await live.rawQuery('SELECT * FROM loved_tracks'), isEmpty);
      } else {
        await operation;
        expect(
          (await live.rawQuery(
            'SELECT track_key FROM loved_tracks ORDER BY added_at DESC,rowid DESC',
          )).map((row) => row['track_key']),
          ['new-b', 'new-a'],
        );
      }
      expect(await File(retainedStage!).exists(), isFalse);
      expect((await live.rawQuery('PRAGMA database_list')).length, 1);
      expect(
        (await live.rawQuery(
          'SELECT track_key FROM playlist_tracks',
        )).single['track_key'],
        'existing',
      );
      expect(
        (await live.rawQuery(
          "SELECT updated_at FROM playlists WHERE id='p'",
        )).single['updated_at'],
        'old',
      );
    });
  }

  test('bounded Loved inserts and deletes roll back earlier chunks', () async {
    final rows = List.generate(
      400,
      (index) => <String, String>{
        'track_key': 'key-$index',
        'track_json': '{}',
        'added_at': 'new',
      },
    );
    await live.execute(
      "CREATE TRIGGER fail_loved BEFORE INSERT ON loved_tracks WHEN new.track_key='key-300' BEGIN SELECT RAISE(ABORT,'denied'); END",
    );
    await expectLater(
      LibraryCollectionsDatabase.writeDatabaseLovedTracks(live, rows),
      throwsA(isA<StateError>()),
    );
    expect(await live.rawQuery('SELECT * FROM loved_tracks'), isEmpty);
    await live.execute('DROP TRIGGER fail_loved');
    await LibraryCollectionsDatabase.writeDatabaseLovedTracks(live, rows);
    await live.execute(
      "CREATE TRIGGER fail_delete BEFORE DELETE ON loved_tracks WHEN old.track_key='key-300' BEGIN SELECT RAISE(ABORT,'denied'); END",
    );
    final keys = rows.map((row) => row['track_key']!).toList();
    await expectLater(
      LibraryCollectionsDatabase.deleteDatabaseLovedTracks(live, keys),
      throwsA(isA<StateError>()),
    );
    expect((await live.rawQuery('SELECT * FROM loved_tracks')).length, 400);
    await live.execute('DROP TRIGGER fail_delete');
    await LibraryCollectionsDatabase.deleteDatabaseLovedTracks(live, keys);
    expect(await live.rawQuery('SELECT * FROM loved_tracks'), isEmpty);
  });

  test(
    'timestamp failure rolls back all inserted tracks and trigger effects',
    () async {
      await live.execute(
        "CREATE TRIGGER fail_update BEFORE UPDATE ON playlists BEGIN SELECT RAISE(ABORT,'denied'); END",
      );
      await expectLater(publish(), throwsA(isA<StateError>()));
      expect(
        (await live.rawQuery(
          'SELECT track_key FROM playlist_tracks',
        )).single['track_key'],
        'existing',
      );
      expect(await live.rawQuery('SELECT * FROM published'), isEmpty);
      expect(
        (await live.rawQuery(
          "SELECT updated_at FROM playlists WHERE id='p'",
        )).single['updated_at'],
        'old',
      );
      expect((await live.rawQuery('PRAGMA database_list')).length, 1);
      expect(await File(retainedStage!).exists(), false);
    },
  );

  test(
    'missing playlist preserves foreign-key enforcement and existing data',
    () async {
      await expectLater(
        publish(playlist: 'missing'),
        throwsA(isA<StateError>()),
      );
      expect(
        (await live.rawQuery('SELECT track_key FROM playlist_tracks')).length,
        1,
      );
      expect((await live.rawQuery('PRAGMA database_list')).length, 1);
    },
  );

  test('incomplete native result cannot enter the live transaction', () async {
    await expectLater(
      publish(
        runner: (request) async {
          final result = await stage(request);
          result['count'] = 1;
          return result;
        },
      ),
      throwsFormatException,
    );
    expect(
      (await live.rawQuery('SELECT track_key FROM playlist_tracks')).length,
      1,
    );
    expect(await File(retainedStage!).exists(), false);
    expect((await live.rawQuery('PRAGMA database_list')).length, 1);
  });

  test(
    'failed detach retains its file without reporting a durable commit as failure',
    () async {
      await publish(database: _DetachFailure(live));
      expect(
        (await live.rawQuery('SELECT track_key FROM playlist_tracks')).length,
        3,
      );
      expect(await File(retainedStage!).exists(), true);
      expect((await live.rawQuery('PRAGMA database_list')).length, 2);
      await File(input).delete();
      expect(await File(retainedStage!).exists(), true);
    },
  );
}
