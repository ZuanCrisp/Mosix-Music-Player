import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/utils/chunked_list.dart';

import '../test/support/queue_persistence_baseline.dart';
import '../test/support/queue_removal_benchmark.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

Future<Map<String, int>> _measure(
  List<DownloadItem> initial,
  String change, {
  required bool legacy,
}) async {
  var items = initial;
  final rows = <String, String>{};
  var writes = 0;
  Future<void> applyChanges({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  }) async {
    writes++;
    for (final id in deletedIds) {
      rows.remove(id);
    }
    for (final row in upserts) {
      rows[row['id'] as String] = row['item_json'] as String;
    }
  }

  final persistence = legacy
      ? null
      : DownloadQueuePersistence(
          currentItems: () => items,
          onError: (error) => fail('$error'),
          loadRows: () async => [],
          applyChanges: applyChanges,
        );
  final flush = legacy
      ? LegacyQueueSnapshot(
          currentItems: () => items,
          applyChanges: applyChanges,
        ).flush
      : persistence!.flush;
  try {
    await flush();
    writes = 0;
    final watch = Stopwatch();
    for (var tick = 0; tick < 20; tick++) {
      if (change != 'unchanged') {
        final index = change == 'completed' ? 100 + tick : 100 + tick % 3;
        final item = items[index];
        items = ChunkedList<DownloadItem>.from(items).updated({
          index: switch (change) {
            'progress' => item.copyWith(
              status: DownloadStatus.downloading,
              progress: (tick + 1) / 100,
              bytesReceived: tick * 100000,
            ),
            'completed' => item.copyWith(status: DownloadStatus.completed),
            _ => item.copyWith(playlistName: 'Playlist $tick'),
          },
        });
      }
      watch.start();
      await flush();
      watch.stop();
    }
    final expected = <String, String>{
      for (final item in items)
        if (item.status != DownloadStatus.completed &&
            item.status != DownloadStatus.failed)
          item.id: encodeDownloadQueueItemForPersistence(item),
    };
    expect(rows, expected);
    expect(writes, change == 'unchanged' || change == 'progress' ? 0 : 20);
    return {
      'microseconds': watch.elapsedMicroseconds,
      'flushes': 20,
      'storage_calls': writes,
      'durable_rows': rows.length,
    };
  } finally {
    persistence?.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final cases = <Map<String, dynamic>>[];
  tearDownAll(() {
    binding.reportData ??= {};
    binding.reportData!['queue_persistence_snapshot'] = {
      'platform': Platform.operatingSystem,
      'completed_cases': cases.length,
      'note':
          '20 flushes from a warm saved cache, five alternating legacy/current pairs after warming both. Original snapshot/diff pipeline and actual current persistence service use the same codec and in-memory applyChanges sink, with canonical durable rows checked. Setup/initial serialization and state mutations excluded; measures snapshot/diff/encoding CPU, not SQLite I/O or rendered frames.',
      'cases': cases,
    };
  });
  for (final count in [1000, 10000]) {
    for (final change in ['unchanged', 'progress', 'completed', 'metadata']) {
      testWidgets('persist $change changes in a $count-item snapshot', (
        tester,
      ) async {
        final initial = await queueRemovalFixture(count);
        await _measure(initial.items, change, legacy: true);
        await _measure(initial.items, change, legacy: false);
        final samples = <String, List<Map<String, int>>>{
          'legacy': [],
          'current': [],
        };
        for (var pair = 0; pair < 5; pair++) {
          for (final legacy in pair.isEven ? [true, false] : [false, true]) {
            samples[legacy ? 'legacy' : 'current']!.add(
              await _measure(initial.items, change, legacy: legacy),
            );
          }
        }
        cases.add({
          'initial_count': count,
          'change': change,
          'samples': samples,
        });
      });
    }
  }

  testWidgets('private SQLite rolls back, retries and reloads saved snapshots', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('queue-snapshot-');
    final originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
    });
    Database? db;
    DownloadQueuePersistence? persistence;
    try {
      final database = AppStateDatabase.instance;
      final connection = await database.database;
      db = connection;
      expect(connection.path, '${root.path}/app_state.db');
      var items = (await queueRemovalFixture(2100)).items;
      final errors = <Object>[];
      var rejectWrite = false;
      var attempts = 0;
      persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: errors.add,
        applyChanges: ({required upserts, required deletedIds}) async {
          attempts++;
          if (rejectWrite) {
            await connection.transaction((txn) async {
              for (final id in deletedIds) {
                await txn.delete(
                  'download_queue_items',
                  where: 'id = ?',
                  whereArgs: [id],
                );
              }
              await txn.insert(
                'download_queue_items',
                upserts.first,
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
              throw StateError('injected transaction failure');
            });
          }
          await database.applyPendingDownloadQueueChanges(
            upserts: upserts,
            deletedIds: deletedIds,
          );
        },
      );
      await persistence.flush();
      final before = await database.getPendingDownloadQueueRows();
      expect(before, hasLength(2000));
      final changed = List<DownloadItem>.of(items);
      changed[100] = changed[100].copyWith(status: DownloadStatus.completed);
      changed[102] = changed[102].copyWith(playlistName: 'Updated');
      changed.add(changed[103].copyWith(id: 'new-item'));
      changed.removeAt(101);
      items = ChunkedList.from(changed);
      rejectWrite = true;
      await persistence.flush();
      expect(errors, hasLength(1));
      expect(await database.getPendingDownloadQueueRows(), before);
      rejectWrite = false;
      await persistence.flush();
      final expected = {
        for (final item in items)
          if (item.status != DownloadStatus.completed)
            item.id: encodeDownloadQueueItemForPersistence(item),
      };
      final after = await database.getPendingDownloadQueueRows();
      expect({for (final row in after) row['id']: row['item_json']}, expected);
      expect(after, hasLength(1999));
      await persistence.flush();
      expect(attempts, 3);

      // A storage reload must invalidate the previously committed list identity.
      await connection.delete(
        'download_queue_items',
        where: 'id = ?',
        whereArgs: ['new-item'],
      );
      expect(await persistence.restore(), hasLength(1998));
      await persistence.flush();
      expect(attempts, 4);
      expect(await database.getPendingDownloadQueueRows(), hasLength(1999));
      final restored = await persistence.restore();
      expect({
        for (final item in restored)
          item.id: encodeDownloadQueueItemForPersistence(item),
      }, expected);
      cases.add({
        'change': 'private_sqlite_rollback_retry_restore',
        'initial_rows': before.length,
        'final_rows': restored.length,
        'write_attempts': attempts,
        'expected_errors': errors.length,
      });
    } finally {
      persistence?.dispose();
      await db?.close();
      PathProviderPlatform.instance = originalPaths;
      await root.delete(recursive: true);
    }
  });
}
