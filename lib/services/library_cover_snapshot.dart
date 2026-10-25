import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:mornye/utils/logger.dart';

var _snapshotSequence = 0;
const _coverReferences =
    "SELECT DISTINCT cover_path FROM library WHERE cover_path IS NOT NULL AND cover_path != ''";

/// Copies only the cover-reference projection using the live connection's
/// SQLite engine. Rust receives a private, detached file, never the live DB.
/// The source writer barrier remains held throughout destructive maintenance.
Future<int> withLibraryCoverSnapshot(
  Database db,
  Future<int> Function(String privatePath) prune, {
  bool Function()? canPrune,
  Directory? temporaryDirectory,
}) async {
  if (canPrune != null && !canPrune()) return 0;
  final directory = await (temporaryDirectory ?? Directory.systemTemp)
      .createTemp('library-cover-snapshot-');
  final path = '${directory.path}/local_library.db';
  final suffix = ++_snapshotSequence;
  final alias = 'cover_snapshot_$suffix';
  final references = 'cover_snapshot_refs_$suffix';
  var attached = false;
  var temporaryTable = false;
  try {
    await db.execute(
      'CREATE TEMP TABLE $references (cover_path TEXT PRIMARY KEY)',
    );
    temporaryTable = true;
    await db.execute('ATTACH DATABASE ? AS $alias', [path]);
    attached = true;
    await db.transaction((txn) async {
      await txn.execute('INSERT INTO temp.$references $_coverReferences');
      // This schema17 projection is exclusively for cache_prune_library;
      // native maintenance reads only library.cover_path and user_version.
      await txn.execute(
        'CREATE TABLE $alias.library (cover_path TEXT NOT NULL)',
      );
      await txn.execute(
        'INSERT INTO $alias.library SELECT cover_path FROM temp.$references',
      );
      await txn.execute('PRAGMA $alias.user_version = 17');
    }, exclusive: true);
    await db.execute('DETACH DATABASE $alias');
    attached = false;

    // DETACH must precede any Rust access. Reacquire the source writer barrier
    // and check the exact reference set, including disabled/offline sources.
    // A change in the brief handoff gap safely postpones this optional sweep.
    return await db.transaction((txn) async {
      if (canPrune != null && !canPrune()) return 0;
      final changed = Sqflite.firstIntValue(
        await txn.rawQuery('''
          SELECT EXISTS (
            $_coverReferences EXCEPT SELECT cover_path FROM temp.$references
          ) OR EXISTS (
            SELECT cover_path FROM temp.$references EXCEPT $_coverReferences
          ) AS changed
        '''),
      );
      if (changed != 0) {
        AppLogger('LocalLibrary').w(
          'Cover references changed during snapshot handoff; postponing cache pruning',
        );
        return 0;
      }
      if (canPrune != null && !canPrune()) return 0;
      return prune(path);
    }, exclusive: true);
  } finally {
    if (attached) {
      try {
        await db.execute('DETACH DATABASE $alias');
        attached = false;
      } catch (error) {
        AppLogger('LocalLibrary').w('Failed detaching cover snapshot: $error');
      }
    }
    if (temporaryTable) {
      try {
        await db.execute('DROP TABLE temp.$references');
      } catch (error) {
        AppLogger(
          'LocalLibrary',
        ).w('Failed clearing cover reference set: $error');
      }
    }
    // Do not unlink a DB whose system SQLite handle could still be attached.
    if (!attached) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException catch (error) {
        AppLogger(
          'LocalLibrary',
        ).w('Failed clearing private cover snapshot: $error');
      }
    }
  }
}

/// Desktop fallback: bounded channel replies while the caller holds its
/// source transaction. Native projection reads transfer no paths through Dart.
Future<Set<String>> readLibraryCoverReferences(DatabaseExecutor db) async {
  final paths = <String>{};
  String? after;
  while (true) {
    final page = await db.rawQuery(
      '''
      SELECT DISTINCT cover_path FROM library
      WHERE cover_path IS NOT NULL AND cover_path != ''
        ${after == null ? '' : 'AND cover_path > ?'}
      ORDER BY cover_path LIMIT 256
    ''',
      [?after],
    );
    if (page.isEmpty) break;
    paths.addAll(page.map((row) => row['cover_path'] as String));
    after = page.last['cover_path'] as String;
    if (page.length < 256) break;
  }
  return paths;
}
