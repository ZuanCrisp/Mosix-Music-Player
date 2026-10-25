import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/services/sqlite_native_snapshot.dart';
import 'package:mornye/utils/logger.dart';

// Small selections cost less inline; reserve worker setup for larger lists.
const _workerThreshold = 1024;
const _nativeThreshold = 2048;
var _attachmentSequence = 0;
final _log = AppLogger('CollectionTrackBatch');

class PreparedCollectionTrackBatch {
  const PreparedCollectionTrackBatch({
    required this.entries,
    required this.duplicates,
    required this.rows,
    this.rowsPath,
    this.inputDirectory,
  });

  final List<CollectionTrackEntry> entries;
  final int duplicates;
  final List<Map<String, String>> rows;
  final String? rowsPath;
  final String? inputDirectory;

  Future<void> dispose() async {
    final directory = inputDirectory;
    if (directory != null) await _removeDirectory(directory);
  }
}

/// Deduplication and encoding share one worker. Large native batches return a
/// file path instead of transferring thousands of JSON maps back through UI.
Future<PreparedCollectionTrackBatch> prepareCollectionTrackBatch({
  required Iterable<Track> tracks,
  required Set<String> existingKeys,
  required DateTime addedAt,
  bool preserveOccurrences = false,
  bool? useNative,
  Directory? temporaryDirectory,
}) async {
  final snapshot = tracks.toList(growable: false);
  String? inputDirectory;
  if (snapshot.length >= _nativeThreshold &&
      (useNative ?? PlatformBridge.supportsCoreBackend)) {
    inputDirectory =
        (await (temporaryDirectory ?? await getTemporaryDirectory()).createTemp(
          'playlist-input-',
        )).path;
  }
  try {
    if (snapshot.length < _workerThreshold) {
      return _prepare(
        snapshot,
        existingKeys,
        addedAt,
        inputDirectory,
        preserveOccurrences,
      );
    }
    return await Isolate.run(
      () => _prepare(
        snapshot,
        existingKeys,
        addedAt,
        inputDirectory,
        preserveOccurrences,
      ),
    );
  } catch (_) {
    if (inputDirectory != null) await _removeDirectory(inputDirectory);
    rethrow;
  }
}

PreparedCollectionTrackBatch _prepare(
  List<Track> tracks,
  Set<String> existingKeys,
  DateTime addedAt,
  String? inputDirectory,
  bool preserveOccurrences,
) {
  final keys = <String>{};
  final entries = <CollectionTrackEntry>[];
  var duplicates = 0;
  final importKeys = preserveOccurrences
      ? playlistImportKeys(tracks).iterator
      : null;
  for (final track in tracks) {
    importKeys?.moveNext();
    final key = importKeys?.current ?? trackCollectionKey(track);
    if (existingKeys.contains(key) || !keys.add(key)) {
      duplicates++;
    } else {
      entries.add(
        CollectionTrackEntry(key: key, track: track, addedAt: addedAt),
      );
    }
  }
  final rows = <Map<String, String>>[];
  String? rowsPath;
  if (inputDirectory != null && entries.length >= _nativeThreshold) {
    rowsPath = '$inputDirectory/rows.ndjson';
    final file = File(rowsPath).openSync(mode: FileMode.write);
    try {
      var buffer = StringBuffer();
      for (final entry in entries) {
        buffer.writeln(
          jsonEncode({'key': entry.key, 'track': entry.track.toJson()}),
        );
        if (buffer.length >= 64 * 1024) {
          file.writeStringSync(buffer.toString());
          buffer = StringBuffer();
        }
      }
      if (buffer.isNotEmpty) file.writeStringSync(buffer.toString());
    } finally {
      file.closeSync();
    }
  } else {
    final timestamp = addedAt.toIso8601String();
    for (final entry in entries) {
      rows.add({
        'track_key': entry.key,
        'track_json': jsonEncode(entry.track.toJson()),
        'added_at': timestamp,
      });
    }
  }
  return PreparedCollectionTrackBatch(
    entries: entries,
    duplicates: duplicates,
    rows: rows,
    rowsPath: rowsPath,
    inputDirectory: inputDirectory,
  );
}

/// Rust exclusively builds a new private database. Publication and the
/// playlist timestamp stay in one transaction on the existing sqflite owner.
Future<void> publishPlaylistBatch({
  required Database database,
  required String playlistId,
  required String updatedAt,
  required String rowsPath,
  required int expectedCount,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? nativeJobRunner,
  Directory? temporaryDirectory,
}) => _publishTrackBatch(
  database: database,
  playlistId: playlistId,
  updatedAt: updatedAt,
  rowsPath: rowsPath,
  expectedCount: expectedCount,
  nativeJobRunner: nativeJobRunner,
  temporaryDirectory: temporaryDirectory,
);

Future<void> publishLovedBatch({
  required Database database,
  required String addedAt,
  required String rowsPath,
  required int expectedCount,
  Future<Map<String, dynamic>> Function(Map<String, dynamic>)? nativeJobRunner,
  Directory? temporaryDirectory,
}) => _publishTrackBatch(
  database: database,
  playlistId: null,
  updatedAt: addedAt,
  rowsPath: rowsPath,
  expectedCount: expectedCount,
  nativeJobRunner: nativeJobRunner,
  temporaryDirectory: temporaryDirectory,
);

Future<void> _publishTrackBatch({
  required Database database,
  required String? playlistId,
  required String updatedAt,
  required String rowsPath,
  required int expectedCount,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic>)?
  nativeJobRunner,
  required Directory? temporaryDirectory,
}) async {
  // The native staging format contains only ordered keys and track JSON.
  // Both destinations share it; only this owner chooses the live table.
  final directory = await (temporaryDirectory ?? await getTemporaryDirectory())
      .createTemp('playlist-stage-');
  final stagedPath = '${directory.path}/playlist_additions.db';
  var detached = true;
  try {
    final result = await (nativeJobRunner ?? PlatformBridge.runNativeDataJob)({
      'operation': 'collections_stage_playlist_additions',
      'rows_path': rowsPath,
      'output_path': stagedPath,
      'expected_count': expectedCount,
    });
    if (result['committed'] != true ||
        result['published'] != true ||
        result['count'] != expectedCount ||
        result['path'] != stagedPath) {
      throw const FormatException('Incomplete collection track staging');
    }
    final alias = 'playlist_additions_${_attachmentSequence++}';
    await database.execute('ATTACH DATABASE ? AS $alias', [stagedPath]);
    detached = false;
    var committed = false;
    try {
      await sqlite.transactionWithBusyRetry(database, (txn) async {
        if (playlistId == null) {
          await txn.execute(
            'INSERT OR REPLACE INTO main.loved_tracks '
            '(track_key,track_json,added_at) '
            'SELECT track_key,track_json,? FROM $alias.playlist_additions '
            'ORDER BY position',
            [updatedAt],
          );
          return;
        }
        await txn.execute(
          'INSERT OR REPLACE INTO main.playlist_tracks '
          '(playlist_id,track_key,track_json,added_at) '
          'SELECT ?,track_key,track_json,? FROM $alias.playlist_additions '
          'ORDER BY position',
          [playlistId, updatedAt],
        );
        await txn.update(
          'playlists',
          {'updated_at': updatedAt},
          where: 'id = ?',
          whereArgs: [playlistId],
        );
      });
      committed = true;
    } finally {
      try {
        await detachNativeSqliteSnapshot(database, alias, stagedPath);
        detached = true;
      } on NativeSqliteSnapshotDetachException {
        if (!committed) rethrow;
        _log.w('Collection saved; retaining staging after failed DETACH');
      }
    }
  } finally {
    // This output directory is separate from the input batch so its owner can
    // always remove the input even if a failed DETACH retains the SQLite file.
    if (detached) await _removeDirectory(directory.path);
  }
}

Future<void> _removeDirectory(String path) async {
  try {
    await Directory(path).delete(recursive: true);
  } on FileSystemException catch (error) {
    _log.w('Could not remove playlist staging: $error');
  }
}
