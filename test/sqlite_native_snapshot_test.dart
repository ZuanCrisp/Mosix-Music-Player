import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/sqlite_native_snapshot.dart';

import 'support/sqlite_process_database.dart';

class _DetachFailureDatabase implements Database {
  _DetachFailureDatabase(this.database);
  @override
  final SqliteProcessDatabase database;

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (sql.startsWith('DETACH DATABASE')) throw StateError('detach failed');
    await database.execute(sql, arguments);
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) => database.transaction(action, exclusive: exclusive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late SqliteProcessDatabase database;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sqlite-native-snapshot-');
    database = await SqliteProcessDatabase.open(path: '${root.path}/live.db');
    await database.execute('PRAGMA foreign_keys = ON');
    await database.execute(
      'CREATE TABLE parents(id TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await database.execute(
      'CREATE TABLE children(parent_id TEXT NOT NULL, path TEXT NOT NULL, '
      'PRIMARY KEY(parent_id, path), '
      'FOREIGN KEY(parent_id) REFERENCES parents(id))',
    );
    await database.execute('CREATE TABLE derived(id TEXT PRIMARY KEY)');
    await database.execute(
      'CREATE TRIGGER derived_insert AFTER INSERT ON parents BEGIN '
      'INSERT INTO derived VALUES (new.id); END',
    );
    await database.execute(
      'CREATE TRIGGER derived_delete AFTER DELETE ON parents BEGIN '
      'DELETE FROM derived WHERE id = old.id; END',
    );
    await database.execute(
      "INSERT INTO parents(rowid, id, value) VALUES(7, 'old', '音楽')",
    );
    await database.execute("INSERT INTO children VALUES('old', '/old.flac')");
  });
  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  test(
    'private snapshot preserves rows/schema and is detached before native work',
    () async {
      final path = '${root.path}/snapshot.db';
      await createNativeSqliteSnapshot(
        database,
        path,
        tables: ['parents', 'children'],
        version: 15,
      );
      expect((await database.rawQuery('PRAGMA database_list')).length, 1);
      final snapshot = await SqliteProcessDatabase.open(path: path);
      try {
        expect(await snapshot.rawQuery('PRAGMA user_version'), [
          {'user_version': 15},
        ]);
        expect(await snapshot.rawQuery('SELECT rowid, * FROM parents'), [
          {'rowid': 7, 'id': 'old', 'value': '音楽'},
        ]);
        await expectLater(
          snapshot.execute("INSERT INTO parents VALUES('old', 'duplicate')"),
          throwsA(isA<StateError>()),
        );
        await database.execute("UPDATE parents SET value = 'changed'");
        expect(
          (await snapshot.rawQuery(
            'SELECT value FROM parents',
          )).single['value'],
          '音楽',
        );
        expect(
          await snapshot.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'trigger'",
          ),
          isEmpty,
        );
      } finally {
        await snapshot.close();
      }
    },
  );

  test(
    'closed staging publishes atomically through live triggers and foreign keys',
    () async {
      final path = '${root.path}/staging.db';
      await createNativeSqliteSnapshot(
        database,
        path,
        tables: ['parents', 'children'],
        version: 15,
        copyRows: false,
      );
      final staging = await SqliteProcessDatabase.open(path: path);
      await staging.execute("INSERT INTO parents VALUES('new', 'new value')");
      await staging.execute("INSERT INTO children VALUES('new', '/new.flac')");
      await staging.close();
      await replaceTablesFromNativeSnapshot(
        database,
        path,
        tables: ['parents', 'children'],
        deleteOrder: ['children', 'parents'],
      );
      expect(await database.query('parents'), [
        {'id': 'new', 'value': 'new value'},
      ]);
      expect(await database.query('derived'), [
        {'id': 'new'},
      ]);
      expect(await database.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect((await database.rawQuery('PRAGMA database_list')).length, 1);
    },
  );

  test(
    'late publication failure rolls back original rows and derived index',
    () async {
      final path = '${root.path}/invalid.db';
      await createNativeSqliteSnapshot(
        database,
        path,
        tables: ['parents', 'children'],
        version: 15,
        copyRows: false,
      );
      final staging = await SqliteProcessDatabase.open(path: path);
      await staging.execute("INSERT INTO parents VALUES('new', 'new value')");
      await staging.execute(
        "INSERT INTO children VALUES('missing', '/bad.flac')",
      );
      await staging.close();
      await expectLater(
        replaceTablesFromNativeSnapshot(
          database,
          path,
          tables: ['parents', 'children'],
          deleteOrder: ['children', 'parents'],
        ),
        throwsA(isA<StateError>()),
      );
      expect(await database.query('parents'), [
        {'id': 'old', 'value': '音楽'},
      ]);
      expect(await database.query('derived'), [
        {'id': 'old'},
      ]);
      expect(await database.query('children'), [
        {'parent_id': 'old', 'path': '/old.flac'},
      ]);
      expect((await database.rawQuery('PRAGMA database_list')).length, 1);
    },
  );

  test(
    'failed private schema copy detaches and leaves live tables intact',
    () async {
      await expectLater(
        createNativeSqliteSnapshot(
          database,
          '${root.path}/missing.db',
          tables: ['parents', 'missing'],
          version: 15,
        ),
        throwsA(isA<StateError>()),
      );
      expect((await database.rawQuery('PRAGMA database_list')).length, 1);
      expect(await database.query('parents'), [
        {'id': 'old', 'value': '音楽'},
      ]);
    },
  );

  test(
    'failed detach identifies the private file that must be retained',
    () async {
      final path = '${root.path}/retained.db';
      await expectLater(
        createNativeSqliteSnapshot(
          _DetachFailureDatabase(database),
          path,
          tables: ['parents', 'children'],
          version: 15,
        ),
        throwsA(
          isA<NativeSqliteSnapshotDetachException>().having(
            (error) => error.path,
            'attached private path',
            path,
          ),
        ),
      );
      final attached = (await database.rawQuery('PRAGMA database_list'))
          .singleWhere(
            (row) => (row['name'] as String).startsWith('native_snapshot_'),
          );
      expect(await File(path).exists(), true);
      await database.execute('DETACH DATABASE "${attached['name']}"');
    },
  );

  test(
    'post-commit detach failure retains staging without rejecting publication',
    () async {
      final path = '${root.path}/published.db';
      await createNativeSqliteSnapshot(
        database,
        path,
        tables: ['parents', 'children'],
        version: 15,
        copyRows: false,
      );
      final staging = await SqliteProcessDatabase.open(path: path);
      await staging.execute("INSERT INTO parents VALUES('new', 'published')");
      await staging.close();
      expect(
        await replaceTablesFromNativeSnapshot(
          _DetachFailureDatabase(database),
          path,
          tables: ['parents', 'children'],
          deleteOrder: ['children', 'parents'],
        ),
        false,
      );
      expect(await database.query('parents'), [
        {'id': 'new', 'value': 'published'},
      ]);
      expect(await database.query('derived'), [
        {'id': 'new'},
      ]);
      final attached = (await database.rawQuery('PRAGMA database_list'))
          .singleWhere(
            (row) => (row['name'] as String).startsWith('native_publish_'),
          );
      expect(await File(path).exists(), true);
      await database.execute('DETACH DATABASE "${attached['name']}"');
    },
  );
}
