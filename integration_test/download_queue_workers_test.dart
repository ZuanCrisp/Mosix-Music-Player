import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/download_queue_codec.dart';
import 'package:mornye/services/download_queue_persistence.dart';

// Baseline is the synchronous restore loop before the worker change. Keep its
// parsing, canonical-payload comparison, and corrupt-row behavior comparable.
Future<RestoredDownloadQueue> _inlineRestore(
  List<Map<String, dynamic>> rows,
) async {
  final saved = <String, DownloadQueueSavedItem>{};
  final pending = <DownloadItem>[];
  for (final row in rows) {
    final id = row['id']?.toString() ?? '';
    saved[id] = (item: null, payload: null);
    final payload = row['item_json'];
    if (id.isEmpty || payload is! String || payload.isEmpty) continue;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) continue;
      var item = DownloadItem.fromJson(Map<String, dynamic>.from(decoded));
      final status = downloadQueuePersistenceStatus(item.status);
      saved[id] = (
        item: item,
        payload:
            row['status']?.toString() == status.name &&
                payload == encodeDownloadQueueItemForPersistence(item)
            ? payload
            : null,
      );
      if (item.status != status) {
        item = item.copyWith(status: status, progress: 0);
      }
      if (status == DownloadStatus.queued || status == DownloadStatus.skipped) {
        pending.add(item);
      }
    } catch (_) {
      continue;
    }
  }
  return RestoredDownloadQueue(items: pending, saved: saved);
}

Future<List<String>> _inlineEncode(List<DownloadItem> items) async => [
  for (final item in items) encodeDownloadQueueItemForPersistence(item),
];

Future<void> _inlineWrite(
  Database database,
  List<Map<String, dynamic>> upserts,
) => database.transaction((txn) async {
  final batch = txn.batch();
  for (final row in upserts) {
    batch.insert(
      'download_queue_items',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  await batch.commit(noResult: true);
});

List<DownloadItem> _fixtureItems(int count) => List.generate(count, (index) {
  final status = index % 7 == 0
      ? DownloadStatus.skipped
      : index % 3 == 0
      ? DownloadStatus.downloading
      : DownloadStatus.queued;
  return DownloadItem(
    id: 'queue:$index',
    track: Track(
      id: 'example:$index',
      name: 'Song $index — 日本語',
      artistName: 'Artist ${index % 99}',
      albumName: 'Album ${index ~/ 12}',
      albumArtist: 'Album artist ${index % 99}',
      duration: 180,
      trackNumber: index % 12 + 1,
      discNumber: 1,
      totalDiscs: 1,
      releaseDate: '2026-10-07',
      genre: 'Rock',
      label: 'Example label',
      copyright: '© Example',
      composer: 'Composer $index',
      comment: List.filled(24, 'Metadata $index — 日本語').join(' '),
      coverUrl: 'https://example.test/art/${index ~/ 12}.jpg',
      availability: const ServiceAvailability(deezer: true),
    ),
    service: 'extension.example',
    status: status,
    progress: .7,
    speedMBps: 5,
    bytesReceived: 70,
    bytesTotal: 100,
    preparationStage: 'decrypt',
    createdAt: DateTime.utc(2026).add(Duration(seconds: index)),
    qualityOverride: 'HI_RES',
    playlistName: 'Large playlist',
    playlistPosition: index + 1,
    fromBatch: true,
    preserveQualityVariant: true,
    networkDownloadFolder: 'Music/Albums',
  );
});

class _InlineProbeTrack extends Track {
  _InlineProbeTrack(this.original, this.expectedIsolate)
    : super(
        id: original.id,
        name: original.name,
        artistName: original.artistName,
        albumName: original.albumName,
        duration: original.duration,
        albumArtist: original.albumArtist,
        comment: original.comment,
        coverUrl: original.coverUrl,
        genre: original.genre,
        label: original.label,
        copyright: original.copyright,
        composer: original.composer,
        releaseDate: original.releaseDate,
        availability: original.availability,
      );
  final Track original;
  final String? expectedIsolate;

  @override
  Map<String, dynamic> toJson() {
    if (Isolate.current.debugName != expectedIsolate) {
      throw StateError('Small queue serialization left its owning isolate');
    }
    return original.toJson();
  }
}

class _Measurement<T> {
  _Measurement(this.value, this.elapsedMs, this.maxGapMs, this.ticks);
  final T value;
  final double elapsedMs;
  final double maxGapMs;
  final int ticks;

  Map<String, Object> toJson() => {
    'elapsed_ms': elapsedMs,
    'max_ui_gap_ms': maxGapMs,
    'ui_ticks': ticks,
  };
}

Future<_Measurement<T>> _measure<T>(Future<T> Function() operation) async {
  final heartbeat = Stopwatch()..start();
  var previous = 0;
  var maximum = 0;
  var ticks = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
    final current = heartbeat.elapsedMicroseconds;
    final gap = current - previous;
    if (gap > maximum) maximum = gap;
    previous = current;
    ticks++;
  });
  await Future<void>.delayed(const Duration(milliseconds: 8));
  previous = heartbeat.elapsedMicroseconds;
  maximum = 0;
  ticks = 0;
  final stopwatch = Stopwatch()..start();
  try {
    final value = await operation();
    stopwatch.stop();
    final operationTicks = ticks;
    final trailingGap = heartbeat.elapsedMicroseconds - previous;
    if (trailingGap > maximum) maximum = trailingGap;
    return _Measurement(
      value,
      stopwatch.elapsedMicroseconds / 1000,
      maximum / 1000,
      operationTicks,
    );
  } finally {
    timer.cancel();
  }
}

class _QueueStore {
  final rows = <String, Map<String, dynamic>>{};
  int writes = 0;

  Future<List<Map<String, dynamic>>> load() async => rows.values.toList();

  Future<void> apply({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  }) async {
    writes++;
    for (final id in deletedIds) {
      rows.remove(id);
    }
    for (final row in upserts) {
      rows[row['id'] as String] = row;
    }
  }
}

Map<String, dynamic> _queueReport(
  IntegrationTestWidgetsFlutterBinding binding,
) {
  binding.reportData ??= {};
  return binding.reportData!.putIfAbsent(
        'queue_workers',
        () => <String, dynamic>{},
      )
      as Map<String, dynamic>;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'large queue codecs preserve payloads and release the UI isolate',
    (tester) async {
      final items = _fixtureItems(12000);
      final rows = <Map<String, dynamic>>[
        for (final item in items)
          {
            'id': item.id,
            'status': item.status.name,
            'item_json': jsonEncode(item.toJson()),
          },
        {'id': 'broken', 'status': 'queued', 'item_json': '{broken'},
      ];
      final report = <String, dynamic>{
        'count': items.length,
        'mode': kDebugMode ? 'debug' : 'profile/release',
        'payload_utf16_units': rows.fold<int>(
          0,
          (total, row) => total + (row['item_json'] as String).length,
        ),
        'restore': <Map<String, Object>>[],
        'encode': <Map<String, Object>>[],
        'small': <Map<String, Object>>[],
      };
      // Warm both codecs before alternating the measured order to reduce bias.
      await _inlineRestore(rows.sublist(0, 64));
      await decodeDownloadQueueRows(rows.sublist(0, 64));
      await _inlineEncode(items.sublist(0, 64));
      await encodeDownloadQueueItems(items.sublist(0, 64));
      for (var sample = 0; sample < 5; sample++) {
        late _Measurement<RestoredDownloadQueue> baselineRestore;
        late _Measurement<RestoredDownloadQueue> workerRestore;
        late _Measurement<List<String>> baselineEncode;
        late _Measurement<List<String>> workerEncode;
        if (sample.isEven) {
          baselineRestore = await _measure(() => _inlineRestore(rows));
          workerRestore = await _measure(() => decodeDownloadQueueRows(rows));
          baselineEncode = await _measure(() => _inlineEncode(items));
          workerEncode = await _measure(() => encodeDownloadQueueItems(items));
        } else {
          workerEncode = await _measure(() => encodeDownloadQueueItems(items));
          baselineEncode = await _measure(() => _inlineEncode(items));
          workerRestore = await _measure(() => decodeDownloadQueueRows(rows));
          baselineRestore = await _measure(() => _inlineRestore(rows));
        }
        expect(workerEncode.value, baselineEncode.value);
        expect(workerEncode.ticks, greaterThan(0));
        expect(workerRestore.ticks, greaterThan(0));
        expect(
          workerRestore.value.items.map((item) => item.id),
          baselineRestore.value.items.map((item) => item.id),
        );
        expect(
          workerRestore.value.saved.keys,
          baselineRestore.value.saved.keys,
        );
        for (var index = 0; index < items.length; index++) {
          final workerItem = workerRestore.value.items[index];
          final baselineItem = baselineRestore.value.items[index];
          expect(
            encodeDownloadQueueItemForPersistence(workerItem),
            encodeDownloadQueueItemForPersistence(baselineItem),
          );
          expect(
            workerRestore.value.saved[workerItem.id]!.payload,
            baselineRestore.value.saved[baselineItem.id]!.payload,
          );
          if (workerItem.status == DownloadStatus.queued &&
              items[index].status == DownloadStatus.queued) {
            expect(
              identical(
                workerRestore.value.saved[workerItem.id]!.item,
                workerItem,
              ),
              isTrue,
            );
          }
        }
        expect(workerRestore.value.saved['broken'], (
          item: null,
          payload: null,
        ));
        (report['restore'] as List<Map<String, Object>>).add({
          'sample': sample,
          'baseline': baselineRestore.toJson(),
          'worker': workerRestore.toJson(),
        });
        (report['encode'] as List<Map<String, Object>>).add({
          'sample': sample,
          'baseline': baselineEncode.toJson(),
          'worker': workerEncode.toJson(),
        });
      }
      for (final size in [1, 16, 63]) {
        final small = items.sublist(0, size);
        final guarded = small
            .map(
              (item) => item.copyWith(
                track: _InlineProbeTrack(item.track, Isolate.current.debugName),
              ),
            )
            .toList(growable: false);
        final baseline = await _measure(() => _inlineEncode(small));
        final optimized = await _measure(
          () => encodeDownloadQueueItems(guarded),
        );
        expect(optimized.value, baseline.value);
        (report['small'] as List<Map<String, Object>>).add({
          'count': size,
          'baseline': baseline.toJson(),
          'optimized': optimized.toJson(),
        });
      }
      _queueReport(binding)['codecs'] = report;
      // ignore: avoid_print
      print('QUEUE_WORKER_REPORT ${jsonEncode(report)}');
    },
  );

  testWidgets(
    'large queue persistence keeps sparse progress and write retries',
    (tester) async {
      final original = _fixtureItems(2100);
      var items = original;
      final store = _QueueStore();
      final errors = <Object>[];
      var failFirstWrite = true;
      final persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: errors.add,
        loadRows: store.load,
        applyChanges: ({required upserts, required deletedIds}) async {
          if (failFirstWrite) {
            failFirstWrite = false;
            throw StateError('Temporary storage failure');
          }
          await store.apply(upserts: upserts, deletedIds: deletedIds);
        },
      );
      await persistence.flush();
      expect(store.rows, isEmpty);
      await persistence.flush();
      expect(store.rows.length, original.length);
      expect(errors, hasLength(1));
      final sparse = <Map<String, Object>>[];
      for (var sample = 0; sample < 5; sample++) {
        final index = original.length - 1;
        items = List<DownloadItem>.of(items)
          ..[index] = items[index].copyWith(
            status: DownloadStatus.downloading,
            progress: sample / 5,
            bytesReceived: sample * 100,
            speedMBps: sample + .5,
          );
        final measured = await _measure(persistence.flush);
        sparse.add(measured.toJson());
      }
      expect(store.writes, 1);
      final restored = await persistence.restore();
      expect(restored.length, items.length);
      for (var index = 0; index < original.length; index++) {
        expect(
          encodeDownloadQueueItemForPersistence(restored[index]),
          encodeDownloadQueueItemForPersistence(original[index]),
        );
      }
      items = [];
      await persistence.flush();
      expect(store.rows, isEmpty);
      persistence.dispose();
      _queueReport(binding)['sparse'] = {
        'count': original.length,
        'samples': sparse,
      };
    },
  );

  testWidgets('production queue restore uses bounded real sqflite reads', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('queue-workers-');
    final database = await openDatabase(
      '${directory.path}/queue.db',
      version: 4,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE download_queue_items (
            id TEXT PRIMARY KEY,
            item_json TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_download_queue_items_created ON download_queue_items(created_at ASC)',
        );
        await db.execute(
          'CREATE INDEX idx_download_queue_items_status ON download_queue_items(status)',
        );
      },
    );
    try {
      var items = _fixtureItems(12000);
      await database.transaction((txn) async {
        final batch = txn.batch();
        for (final item in items) {
          batch.insert('download_queue_items', {
            'id': item.id,
            'item_json': encodeDownloadQueueItemForPersistence(item),
            'status': downloadQueuePersistenceStatus(item.status).name,
            'created_at': item.createdAt.toIso8601String(),
            'updated_at': '2026-10-07',
          });
        }
        batch.insert('download_queue_items', {
          'id': 'broken',
          'item_json': '{broken',
          'status': 'queued',
          'created_at': '2027-01-01',
          'updated_at': '2026-10-07',
        });
        await batch.commit(noResult: true);
      });
      final persistence = DownloadQueuePersistence(
        currentItems: () => items,
        onError: (error) => fail('$error'),
        loadRows: () => AppStateDatabase.instance.getPendingDownloadQueueRows(
          databaseOverride: database,
        ),
        applyChanges: ({required upserts, required deletedIds}) =>
            AppStateDatabase.instance.applyPendingDownloadQueueChanges(
              upserts: upserts,
              deletedIds: deletedIds,
              databaseOverride: database,
            ),
      );
      final samples = <Map<String, Object>>[];
      for (var sample = 0; sample < 5; sample++) {
        Future<RestoredDownloadQueue> baseline() async => _inlineRestore(
          await database.query(
            'download_queue_items',
            where: 'status IN (?, ?, ?, ?)',
            whereArgs: ['queued', 'downloading', 'finalizing', 'skipped'],
            orderBy: 'created_at ASC, rowid ASC',
          ),
        );
        late _Measurement<RestoredDownloadQueue> before;
        late _Measurement<List<DownloadItem>> after;
        if (sample.isEven) {
          before = await _measure(baseline);
          after = await _measure(persistence.restore);
        } else {
          after = await _measure(persistence.restore);
          before = await _measure(baseline);
        }
        expect(
          after.value.map((item) => item.id),
          before.value.items.map((item) => item.id),
        );
        expect(after.value.length, items.length);
        expect(after.ticks, greaterThan(0));
        samples.add({
          'sample': sample,
          'baseline': before.toJson(),
          'worker': after.toJson(),
        });
        items = after.value;
      }
      final payloads = await encodeDownloadQueueItems(items);
      final upserts = <Map<String, dynamic>>[
        for (var index = 0; index < items.length; index++)
          {
            'id': items[index].id,
            'item_json': payloads[index],
            'status': downloadQueuePersistenceStatus(items[index].status).name,
            'created_at': items[index].createdAt.toIso8601String(),
            'updated_at': '2026-10-07',
          },
      ];
      final writeSamples = <Map<String, Object>>[];
      for (var sample = 0; sample < 5; sample++) {
        Future<void> optimized() =>
            AppStateDatabase.instance.applyPendingDownloadQueueChanges(
              upserts: upserts,
              deletedIds: const [],
              databaseOverride: database,
            );
        late _Measurement<void> before;
        late _Measurement<void> after;
        if (sample.isEven) {
          before = await _measure(() => _inlineWrite(database, upserts));
          after = await _measure(optimized);
        } else {
          after = await _measure(optimized);
          before = await _measure(() => _inlineWrite(database, upserts));
        }
        writeSamples.add({
          'sample': sample,
          'baseline': before.toJson(),
          'bounded': after.toJson(),
        });
      }
      await persistence.flush();
      expect(
        await database.query(
          'download_queue_items',
          where: 'id = ?',
          whereArgs: ['broken'],
        ),
        isEmpty,
      );
      final persisted = await database.query(
        'download_queue_items',
        orderBy: 'created_at ASC, rowid ASC',
      );
      expect(persisted.length, items.length);
      for (var index = 0; index < items.length; index++) {
        expect(
          persisted[index]['item_json'],
          encodeDownloadQueueItemForPersistence(items[index]),
        );
      }
      await database.execute('''
        CREATE TRIGGER reject_queue BEFORE INSERT ON download_queue_items
        WHEN NEW.id = 'reject' BEGIN SELECT RAISE(ABORT, 'fixture rejection'); END
      ''');
      final failing = <Map<String, dynamic>>[
        for (var index = 0; index < 600; index++)
          {...upserts[index], 'id': index == 599 ? 'reject' : 'new:$index'},
      ];
      await expectLater(
        AppStateDatabase.instance.applyPendingDownloadQueueChanges(
          upserts: failing,
          deletedIds: items.take(600).map((item) => item.id).toList(),
          databaseOverride: database,
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await database.rawQuery(
          'SELECT COUNT(*) AS n FROM download_queue_items',
        )).single['n'],
        items.length,
      );
      expect(
        (await database.rawQuery(
          "SELECT COUNT(*) AS n FROM download_queue_items WHERE id LIKE 'new:%'",
        )).single['n'],
        0,
      );
      await database.execute('DROP TRIGGER reject_queue');
      persistence.dispose();
      final report = _queueReport(binding);
      report['sqflite_restore'] = {'count': items.length, 'samples': samples};
      report['sqflite_write'] = {
        'count': items.length,
        'samples': writeSamples,
      };
      // ignore: avoid_print
      print('QUEUE_SQLITE_REPORT ${jsonEncode(report['sqflite_restore'])}');
      // ignore: avoid_print
      print('QUEUE_SQLITE_WRITE_REPORT ${jsonEncode(report['sqflite_write'])}');
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}
