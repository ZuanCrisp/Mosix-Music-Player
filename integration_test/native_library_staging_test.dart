import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_native_adapter.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/platform_bridge.dart';

import '../test/support/library_native_fixture.dart';

Future<File> _wav(String path) async {
  final bytes = Uint8List(44 + 320);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  return File(path).writeAsBytes(bytes, flush: true);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Database database;
  late LibraryNativeAdapter adapter;
  var initialized = false;
  final privatePaths = <String>[];
  Future<void> Function(Map<String, dynamic>, Map<String, dynamic>)? afterStage;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-library-private-');
    database = await openDatabase(
      '${root.path}/live.db',
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA recursive_triggers=ON');
      },
    );
    await createNativeLibraryFixture(
      database,
      historyPath: '${root.path}/history.db',
    );
    privatePaths.clear();
    afterStage = null;
    adapter = LibraryNativeAdapter(
      database,
      temporaryDirectory: root,
      nativeJobRunner: (request, {requestId}) async {
        final private = request['library_path'] as String;
        expect(private, isNot(database.path));
        final attachments = await database.rawQuery('PRAGMA database_list');
        expect(
          attachments.where(
            (row) =>
                (row['name'] as String).startsWith('library_private_') ||
                (row['name'] as String).startsWith('native_snapshot_'),
          ),
          isEmpty,
        );
        expect(request['history_path'], isNot('${root.path}/history.db'));
        privatePaths.add(private);
        final result = await PlatformBridge.runNativeDataJob(
          request,
          requestId: requestId,
        );
        await afterStage?.call(request, result);
        return result;
      },
    );
    await addNativeLibraryTrack(database, nativeLibraryTrack('old'));
    await addNativeLibraryTrack(
      database,
      nativeLibraryTrack('other', path: '/other/other.flac'),
      source: 'other',
    );
  });
  tearDown(() async {
    if (initialized) {
      await PlatformBridge.cleanupExtensions();
      initialized = false;
    }
    await database.close();
    await root.delete(recursive: true);
  });
  Future<LibraryScanNDJSONFile> scan(
    List<Map<String, dynamic>> rows, {
    int errors = 0,
  }) async {
    final file = File('${root.path}/scan.ndjson');
    await file.writeAsString(rows.map(jsonEncode).join('\n'));
    return LibraryScanNDJSONFile(
      file: file,
      expectedCount: rows.length,
      errorCount: errors,
    );
  }

  Future<void> cleanAndHealthy() async {
    for (final path in privatePaths) {
      expect(await File(path).parent.exists(), isFalse);
    }
    expect(await database.rawQuery('PRAGMA integrity_check'), [
      {'integrity_check': 'ok'},
    ]);
    expect(
      await database.rawQuery(
        'SELECT item_id FROM library_path_keys WHERE item_id NOT IN(SELECT id FROM library)',
      ),
      isEmpty,
    );
    final lookups = await database.rawQuery(
      'SELECT source_id, kind, value, ref_count FROM library_lookup_summary ORDER BY source_id,kind,value',
    );
    final expected = await database.rawQuery(
      "SELECT source_id, 'match' AS kind, match_key AS value, COUNT(*) AS ref_count FROM library WHERE match_key IS NOT NULL AND match_key != '' GROUP BY source_id, match_key ORDER BY source_id,kind,value",
    );
    expect(lookups, expected);
    if ((await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE name='library_search_fts'",
    )).isNotEmpty) {
      expect(
        await database.rawQuery(
          "SELECT rowid FROM library_search_fts WHERE library_search_fts MATCH 'track' ORDER BY rowid",
        ),
        await database.rawQuery(
          "SELECT rowid FROM library WHERE search_text LIKE '%track%' ORDER BY rowid",
        ),
      );
    }
  }

  testWidgets(
    'scan preparation and publication retry transient download History locks',
    (tester) async {
      final historyPath = '${root.path}/history.db';
      await database.rawQuery('PRAGMA busy_timeout=0');
      await database.rawQuery('PRAGMA history_db.journal_mode=WAL');
      final writer = await openDatabase(historyPath, singleInstance: false);
      final releases = <Completer<void>>[];
      final writes = <Future<void>>[];
      Future<void> blockHistoryWriter({bool reproduce = false}) async {
        final locked = Completer<void>();
        final release = Completer<void>();
        final index = writes.length;
        releases.add(release);
        final writing = writer.transaction((txn) async {
          await txn.execute('INSERT INTO history_path_keys VALUES (?, ?)', [
            'history-$index',
            '/music/pending-$index.flac',
          ]);
          locked.complete();
          await release.future;
        });
        writes.add(writing);
        unawaited(
          writing.catchError((Object error, StackTrace stack) {
            if (!locked.isCompleted) locked.completeError(error, stack);
          }),
        );
        await locked.future;
        if (reproduce) {
          // The previous plain BEGIN fails against the same attachment and
          // writer. Only transaction admission is retried by the new helper.
          await expectLater(
            database.transaction((txn) async {}),
            throwsA(
              isA<DatabaseException>().having(
                (error) => error.toString(),
                'message',
                contains('database is locked'),
              ),
            ),
          );
        }
        Timer(const Duration(milliseconds: 150), () {
          if (!release.isCompleted) release.complete();
        });
      }

      try {
        await blockHistoryWriter(reproduce: true);
        afterStage = (_, _) => blockHistoryWriter();
        final full = await adapter.importScanFile(
          'source',
          await scan([nativeLibraryTrack('full')]),
          requestId: 'history-writer-full',
          isCancelled: () => false,
        );
        expect(full['durable'], isTrue);
        expect(full['inserted'], 1);

        final music = await Directory('${root.path}/music').create();
        if (!initialized) {
          final extensions = await Directory(
            '${root.path}/extensions',
          ).create();
          final data = await Directory('${root.path}/extension-data').create();
          await PlatformBridge.initExtensionSystem(
            extensions.path,
            data.path,
            masterKey: base64Encode(List.filled(32, 1)),
            lyricsProviders: const [],
            lyricsFetchOptions: const {},
            allowedDirectories: [music.path],
          );
          initialized = true;
        }
        await database.update(
          'library_sources',
          {'path': music.path},
          where: 'id = ?',
          whereArgs: ['source'],
        );
        final track = await _wav('${music.path}/new.wav');
        final snapshot = await adapter.writeFileModTimesSnapshot(
          'source',
          requestId: 'history-writer-snapshot',
          isCancelled: () => false,
        );
        try {
          final delta = await adapter.scanIncremental(
            'source',
            music.path,
            snapshot,
            isSaf: false,
            requestId: 'history-writer-incremental',
            isCancelled: () => false,
          );
          expect(delta['durable'], isTrue);
          expect(
            await database.query(
              'library',
              columns: ['file_path'],
              where: 'source_id = ? AND file_path = ?',
              whereArgs: ['source', track.path],
            ),
            [
              {'file_path': track.path},
            ],
          );
        } finally {
          await File(snapshot).delete();
        }
      } finally {
        for (final release in releases) {
          if (!release.isCompleted) release.complete();
        }
        try {
          await Future.wait(writes);
        } finally {
          await writer.close();
        }
      }
      expect(
        await database.rawQuery(
          'SELECT item_id FROM history_db.history_path_keys ORDER BY item_id',
        ),
        [
          for (var i = 0; i < writes.length; i++) {'item_id': 'history-$i'},
        ],
        reason: 'committed downloads remain visible after scan retries',
      );
      await cleanAndHealthy();
    },
  );

  testWidgets(
    'production full scan repeatedly publishes exact rows, empty and partial states through owner SQLite',
    (tester) async {
      final timings = <int>[];
      for (final count in [2, 0, 3, 0]) {
        final rows = [
          for (var i = 0; i < count; i++) nativeLibraryTrack('scan-$i'),
        ];
        afterStage = count == 3
            ? (_, _) => addNativeLibraryDownload(database, '/music/scan-2.flac')
            : null;
        final input = await scan(rows);
        final stopwatch = Stopwatch()..start();
        final result = await adapter.importScanFile(
          'source',
          input,
          requestId: 'full-$count-${timings.length}',
          isCancelled: () => false,
        );
        timings.add(stopwatch.elapsedMicroseconds);
        final accepted = count == 3 ? rows.take(2).toList() : rows;
        expect(result['committed'], isTrue);
        expect(result['durable'], isTrue);
        expect(result['inserted'], accepted.length);
        expect(result['skipped'], count - accepted.length);
        expect(
          await database.query(
            'library',
            where: 'source_id=?',
            whereArgs: ['source'],
            orderBy: 'id',
          ),
          accepted
              .map((row) => LibraryRowMapper.encode(row, sourceId: 'source'))
              .toList(),
        );
        await cleanAndHealthy();
      }
      await addNativeLibraryTrack(database, nativeLibraryTrack('unreadable'));
      await adapter.importScanFile(
        'source',
        await scan([nativeLibraryTrack('new')], errors: 1),
        requestId: 'partial',
        isCancelled: () => false,
      );
      expect(
        (await database.query(
          'library',
          orderBy: 'id',
        )).map((row) => row['id']),
        ['new', 'other', 'unreadable'],
      );
      await cleanAndHealthy();
      binding.reportData ??= {};
      binding.reportData!['library_private_full'] = {
        'samples_us': timings,
        'parity': true,
      };
    },
  );

  testWidgets(
    'source edit, late SQL failure and cancellation after native staging leave live rows unchanged',
    (tester) async {
      final before = await nativeLibraryDigest(database);
      var cancelled = false;
      afterStage = (_, _) async {
        cancelled = true;
      };
      await expectLater(
        adapter.importScanFile(
          'source',
          await scan([nativeLibraryTrack('new')]),
          requestId: 'cancel-staged',
          isCancelled: () => cancelled,
        ),
        throwsStateError,
      );
      expect(await nativeLibraryDigest(database), before);
      afterStage = (_, _) => database
          .update(
            'library_sources',
            {'enabled': 0},
            where: 'id=?',
            whereArgs: ['source'],
          )
          .then((_) {});
      await expectLater(
        adapter.importScanFile(
          'source',
          await scan([nativeLibraryTrack('new')]),
          requestId: 'source-changed',
          isCancelled: () => false,
        ),
        throwsStateError,
      );
      expect(await nativeLibraryDigest(database), before);
      await database.update(
        'library_sources',
        {'enabled': 1},
        where: 'id=?',
        whereArgs: ['source'],
      );
      afterStage = null;
      await database.execute(
        "CREATE TRIGGER reject_new BEFORE INSERT ON library WHEN new.id='new' BEGIN SELECT RAISE(ABORT,'fixture late failure'); END",
      );
      await expectLater(
        adapter.importScanFile(
          'source',
          await scan([nativeLibraryTrack('new')]),
          requestId: 'owner-rollback',
          isCancelled: () => false,
        ),
        throwsA(anything),
      );
      expect(await nativeLibraryDigest(database), before);
      await cleanAndHealthy();
    },
  );

  testWidgets(
    'production timestamp export uses detached projection and conditionally backfills current owner rows',
    (tester) async {
      final zero = await _wav('${root.path}/zero.wav');
      final changed = await _wav('${root.path}/changed.wav');
      final legacy = await _wav('${root.path}/legacy.wav');
      for (final file in [zero, changed, legacy]) {
        await addNativeLibraryTrack(
          database,
          nativeLibraryTrack(
            file.uri.pathSegments.last,
            path: file.path,
            timestamp: 0,
            version: file == legacy ? 3 : 4,
          ),
        );
      }
      afterStage = (_, _) async {
        await database.update(
          'library',
          {'file_mod_time': 777, 'sort_added': 777},
          where: 'file_path=?',
          whereArgs: [changed.path],
        );
        await database.update(
          'library',
          {'file_mod_time': 0},
          where: 'id=?',
          whereArgs: ['old'],
        );
      };
      final path = await adapter.writeFileModTimesSnapshot(
        'source',
        requestId: 'snapshot',
        isCancelled: () => false,
      );
      final lines = await File(path).readAsLines();
      expect(lines, contains('-1\t${legacy.path}'));
      expect(lines, contains('1770000000000\t/music/old.flac'));
      final zeroTime = int.parse(
        lines
            .singleWhere((line) => line.endsWith('\t${zero.path}'))
            .split('\t')
            .first,
      );
      expect(zeroTime, greaterThan(0));
      final liveRows = await database.query(
        'library',
        columns: ['file_path', 'file_mod_time'],
      );
      expect(
        liveRows.singleWhere(
          (row) => row['file_path'] == zero.path,
        )['file_mod_time'],
        zeroTime,
      );
      expect(
        liveRows.singleWhere(
          (row) => row['file_path'] == changed.path,
        )['file_mod_time'],
        777,
      );
      expect(
        liveRows.singleWhere(
          (row) => row['file_path'] == legacy.path,
        )['file_mod_time'],
        0,
      );
      expect(
        liveRows.singleWhere(
          (row) => row['file_path'] == '/music/old.flac',
        )['file_mod_time'],
        0,
      );
      await cleanAndHealthy();
      await File(path).delete();
    },
  );

  testWidgets(
    'production folder incremental scan retains removals and publishes current History filtering',
    (tester) async {
      final folder = await Directory('${root.path}/audio').create();
      final extensions = await Directory('${root.path}/extensions').create();
      final data = await Directory('${root.path}/extension-data').create();
      await PlatformBridge.initExtensionSystem(
        extensions.path,
        data.path,
        masterKey: base64Encode(List.filled(32, 1)),
        lyricsProviders: const [],
        lyricsFetchOptions: const {},
        allowedDirectories: [folder.path],
      );
      initialized = true;
      final unchanged = await _wav('${folder.path}/unchanged.wav');
      final added = await _wav('${folder.path}/added.wav');
      final missing = '${folder.path}/missing.wav';
      await database.update(
        'library_sources',
        {'path': folder.path},
        where: 'id=?',
        whereArgs: ['source'],
      );
      await database.delete(
        'library_path_keys',
        where: 'item_id=?',
        whereArgs: ['old'],
      );
      await database.delete('library', where: 'id=?', whereArgs: ['old']);
      await addNativeLibraryTrack(
        database,
        nativeLibraryTrack(
          'unchanged',
          path: unchanged.path,
          timestamp: (await unchanged.stat()).modified.millisecondsSinceEpoch,
        ),
      );
      await addNativeLibraryTrack(
        database,
        nativeLibraryTrack('missing', path: missing),
      );
      final snapshot = await adapter.writeFileModTimesSnapshot(
        'source',
        requestId: 'incremental-snapshot',
        isCancelled: () => false,
      );
      List<Map<String, Object?>>? staged;
      afterStage = (request, _) async {
        final private = await openDatabase(
          request['library_path'] as String,
          singleInstance: false,
        );
        try {
          staged = await private.query('library', orderBy: 'id');
          expect(
            await private.query(
              'native_library_removed_paths',
              columns: ['path'],
              orderBy: 'ordinal',
            ),
            [
              {'path': missing},
            ],
          );
        } finally {
          await private.close();
        }
        await addNativeLibraryDownload(database, unchanged.path);
      };
      final watch = Stopwatch()..start();
      final result = await adapter.scanIncremental(
        'source',
        folder.path,
        snapshot,
        isSaf: false,
        requestId: 'incremental',
        isCancelled: () => false,
      );
      expect(result['committed'], isTrue);
      expect(result['durable'], isTrue);
      expect(result['inserted'], 1);
      expect(result['scanned_count'], 1);
      expect(result['skipped'], 1);
      expect(result['deleted_count'], 1);
      expect(result['skippedCount'], 1);
      expect(result['totalFiles'], 2);
      expect(
        await database.query(
          'library',
          where: 'source_id=?',
          whereArgs: ['source'],
          orderBy: 'id',
        ),
        staged,
      );
      expect(staged!.single['file_path'], added.path);
      await cleanAndHealthy();
      await File(snapshot).delete();
      binding.reportData ??= {};
      binding.reportData!['library_private_incremental'] = {
        'total_us': watch.elapsedMicroseconds,
        'parity': true,
      };
    },
  );
}
