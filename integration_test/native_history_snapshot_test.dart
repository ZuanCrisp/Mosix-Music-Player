import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/backup_service.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/sqlite_native_snapshot.dart';

Map<String, dynamic> _track(int id) => DownloadHistoryItem(
  id: 'track-$id',
  trackName: ' CAFÉ İ 音楽 $id ',
  artistName: ' Artist ',
  albumName: ' Album ',
  albumArtist: ' Album Artist ',
  coverUrl: 'https://example.test/art/$id.jpg',
  filePath: '/music/$id.flac',
  service: 'example',
  downloadedAt: DateTime.utc(2026, 10, 7, 5, 0, id, 123, 456),
  isrc: ' us-aa-a26 00001 ',
  spotifyId: ' Example:Track:$id ',
  trackNumber: id + 1,
  totalTracks: 10,
  discNumber: 1,
  totalDiscs: 2,
  duration: 240,
  quality: 'lossless',
  bitDepth: 24,
  sampleRate: 96000,
  format: 'flac',
  explicit: true,
  hasLyrics: true,
  lyricsMetadataScanVersion: 3,
  hasReplayGain: true,
  replayGainMetadataScanVersion: 1,
).toJson();

BackupBundle _bundle(String path, int count) => BackupBundle(
  formatVersion: 3,
  appVersion: 'test',
  createdAt: null,
  settings: null,
  history: const [],
  collections: const {},
  playlistCovers: const {},
  extensions: const {},
  historyNdjsonPath: path,
  historyCount: count,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Database database;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-history-private-');
    // Read only the initialized app's schema; its history is never replaced.
    await createNativeSqliteSnapshot(
      await HistoryDatabase.instance.database,
      '${root.path}/history.db',
      tables: const ['history', 'history_path_keys'],
      version: HistoryDatabase.schemaVersion,
      copyRows: false,
    );
    database = await openDatabase(
      '${root.path}/history.db',
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA recursive_triggers=ON');
      },
    );
    await database.execute('CREATE TABLE derived(id TEXT PRIMARY KEY)');
    await database.execute(
      'CREATE TRIGGER derived_insert AFTER INSERT ON history BEGIN '
      'INSERT INTO derived VALUES(new.id); END',
    );
    await database.execute(
      'CREATE TRIGGER derived_delete AFTER DELETE ON history BEGIN '
      'DELETE FROM derived WHERE id = old.id; END',
    );
  });
  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  testWidgets(
    'production history stages privately and publishes exact rows through its owner',
    (tester) async {
      final input = File('${root.path}/input.ndjson');
      for (final count in [1, 2, 0, 3]) {
        final tracks = [for (var i = 0; i < count; i++) _track(i)];
        await input.writeAsString(tracks.map(jsonEncode).join('\n'));
        await BackupService.restoreNativeHistory(
          database,
          _bundle(input.path, count),
        );
        expect(await database.query('history'), hasLength(count));
        expect(await database.query('derived'), hasLength(count));
        final output = '${root.path}/export-$count.ndjson';
        expect(
          await BackupService.exportNativeHistory(database, output),
          count,
        );
        final exported = (await File(
          output,
        ).readAsLines()).map(jsonDecode).toList();
        // History export retains the established newest-first ordering.
        expect(exported, tracks.reversed.toList());
        expect(await database.rawQuery('PRAGMA quick_check'), [
          {'quick_check': 'ok'},
        ]);
        expect(
          (await database.rawQuery('PRAGMA database_list'))
              .map((row) => row['name'])
              .where((name) => name != 'main' && name != 'temp'),
          isEmpty,
        );
        if (count > 0) {
          expect((await database.query('history')).first.keys, hasLength(48));
          expect(await database.query('history_path_keys'), isNotEmpty);
          // Exercise the owner's cache and WAL after a native read closes.
          await database.execute(
            "UPDATE history SET genre = 'Changed' WHERE id = 'track-0'",
          );
          expect(
            (await database.query(
              'history',
              where: 'id = ?',
              whereArgs: ['track-0'],
            )).single['genre'],
            'Changed',
          );
        }
      }
      final oldRows = await database.query('history', orderBy: 'id');
      final oldKeys = await database.query(
        'history_path_keys',
        orderBy: 'item_id,path_key',
      );
      await expectLater(
        BackupService.restoreNativeHistory(database, _bundle(input.path, 4)),
        throwsA(isA<Exception>()),
      );
      expect(await database.query('history', orderBy: 'id'), oldRows);
      expect(
        await database.query('history_path_keys', orderBy: 'item_id,path_key'),
        oldKeys,
      );
      expect(await database.rawQuery('PRAGMA quick_check'), [
        {'quick_check': 'ok'},
      ]);
      expect(
        (await database.rawQuery('PRAGMA database_list'))
            .map((row) => row['name'])
            .where((name) => name != 'main' && name != 'temp'),
        isEmpty,
      );
    },
  );
}
