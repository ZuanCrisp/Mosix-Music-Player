import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/download_queue_codec.dart';

import 'support/sqlite_process_database.dart';

const _marker = 'app_state_migrated_queue_to_sqlite_v1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SqliteProcessDatabase> fixture() async {
    final database = await SqliteProcessDatabase.open();
    addTearDown(database.close);
    await database.execute('''
      CREATE TABLE download_queue_items (
        id TEXT PRIMARY KEY,
        item_json TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    return database;
  }

  Future<SharedPreferences> preferences(String raw) {
    SharedPreferences.setMockInitialValues({'download_queue': raw});
    return SharedPreferences.getInstance();
  }

  test(
    'legacy migration preserves unknown fields and original normalization',
    () async {
      final database = await fixture();
      final queued = {
        'id': 'queued',
        'createdAt': '2026-01-01',
        'future_field': {'unknown': 'preserved'},
      };
      final downloading = {
        'id': 'active',
        'status': 'downloading',
        'progress': .8,
        'speedMBps': 3,
        'bytesReceived': 80,
        'bytesTotal': 100,
        'preparationStage': 'legacy-stage',
      };
      final raw = jsonEncode([
        queued,
        downloading,
        {'id': 'terminal', 'status': 'completed'},
        {'id': 'skipped', 'status': 'skipped'},
        {'id': '', 'status': 'queued'},
        null,
        1,
        'ignored',
      ]);
      final prefs = await preferences(raw);
      expect(
        await AppStateDatabase.instance.migrateQueueFromSharedPreferences(
          preferencesOverride: prefs,
          databaseOverride: database,
        ),
        isTrue,
      );
      final rows = await database.query('download_queue_items');
      expect(rows.map((row) => row['id']), ['queued', 'active']);
      expect(rows.first['item_json'], jsonEncode(queued));
      expect(rows.first['created_at'], '2026-01-01');
      expect(
        rows.last['item_json'],
        jsonEncode({
          ...downloading,
          'status': 'queued',
          'progress': 0.0,
          'speedMBps': 0.0,
          'bytesReceived': 0,
        }),
      );
      expect(rows.last['created_at'], rows.last['updated_at']);
      expect(rows.every((row) => row['status'] == 'queued'), isTrue);
      expect(prefs.getBool(_marker), isTrue);
      expect(prefs.getString('download_queue'), raw);
      expect(
        await AppStateDatabase.instance.migrateQueueFromSharedPreferences(
          preferencesOverride: prefs,
          databaseOverride: database,
        ),
        isFalse,
      );
    },
  );

  test(
    'malformed legacy data keeps its retry marker while non-list data finishes',
    () async {
      final database = await fixture();
      for (final raw in ['{broken', '[{"id":"valid"},{"id":5}]']) {
        final prefs = await preferences(raw);
        expect(
          await AppStateDatabase.instance.migrateQueueFromSharedPreferences(
            preferencesOverride: prefs,
            databaseOverride: database,
          ),
          isFalse,
        );
        expect(prefs.getBool(_marker), isNull);
        expect(prefs.getString('download_queue'), raw);
        expect(await database.query('download_queue_items'), isEmpty);
      }
      for (final raw in ['', '{}']) {
        final prefs = await preferences(raw);
        expect(
          await AppStateDatabase.instance.migrateQueueFromSharedPreferences(
            preferencesOverride: prefs,
            databaseOverride: database,
          ),
          isFalse,
        );
        expect(prefs.getBool(_marker), isTrue);
      }
    },
  );

  test(
    'large legacy preparation yields to a worker and preserves exact maps',
    () async {
      final comment = List.filled(5000, 'x').join();
      final entries = [
        for (var index = 0; index < 30; index++)
          {'id': '$index', 'status': 'queued', 'comment': comment},
      ];
      var eventLoopResumed = false;
      Timer.run(() => eventLoopResumed = true);
      final rows = await prepareLegacyDownloadQueueRows(
        jsonEncode(entries),
        'now',
      );
      expect(eventLoopResumed, isTrue);
      expect(rows!.map((row) => row['item_json']), entries.map(jsonEncode));
      expect(rows.every((row) => row['created_at'] == 'now'), isTrue);
    },
  );

  test(
    'a failed large legacy import rolls back rows and leaves preferences retryable',
    () async {
      final database = await fixture();
      await database.insert('download_queue_items', {
        'id': 'existing',
        'item_json': '{}',
        'status': 'queued',
        'created_at': 'before',
        'updated_at': 'before',
      });
      await database.execute('''
      CREATE TRIGGER reject_queue BEFORE INSERT ON download_queue_items
      WHEN NEW.id = 'reject' BEGIN SELECT RAISE(ABORT, 'fixture rejection'); END
    ''');
      final comment = List.filled(70000, 'x').join();
      final raw = jsonEncode([
        {'id': 'first', 'status': 'queued', 'comment': comment},
        {'id': 'reject', 'status': 'queued'},
      ]);
      final prefs = await preferences(raw);
      expect(
        await AppStateDatabase.instance.migrateQueueFromSharedPreferences(
          preferencesOverride: prefs,
          databaseOverride: database,
        ),
        isFalse,
      );
      expect(
        (await database.query('download_queue_items')).map((row) => row['id']),
        ['existing'],
      );
      expect(prefs.getBool(_marker), isNull);
      expect(prefs.getString('download_queue'), raw);
      await database.execute('DROP TRIGGER reject_queue');
      expect(
        await AppStateDatabase.instance.migrateQueueFromSharedPreferences(
          preferencesOverride: prefs,
          databaseOverride: database,
        ),
        isTrue,
      );
      expect(
        (await database.query('download_queue_items')).map((row) => row['id']),
        ['existing', 'first', 'reject'],
      );
      expect(prefs.getBool(_marker), isTrue);
    },
  );
}
