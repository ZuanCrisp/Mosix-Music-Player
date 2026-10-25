import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;

var _attachmentSequence = 0;

/// A failed DETACH can leave a system SQLite handle pointing at the private
/// file. Its caller must retain that file instead of unlinking it in cleanup.
class NativeSqliteSnapshotDetachException implements Exception {
  const NativeSqliteSnapshotDetachException(this.path, this.cause);
  final String path;
  final Object cause;

  @override
  String toString() => 'Could not detach native SQLite staging: $cause';
}

Future<void> detachNativeSqliteSnapshot(
  Database database,
  String alias,
  String path,
) async {
  try {
    await database.execute('DETACH DATABASE ${_identifier(alias)}');
  } catch (error) {
    throw NativeSqliteSnapshotDetachException(path, error);
  }
}

String _identifier(String name) {
  if (!RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(name)) {
    throw ArgumentError.value(name, 'name', 'Invalid SQLite identifier');
  }
  return '"$name"';
}

/// Copies selected application tables through their owning SQLite connection.
/// Native SQLite must only open the resulting file after it is detached: two
/// independent SQLite libraries must never share an application's live file.
/// Derived FTS tables and triggers stay with the live database owner.
Future<void> createNativeSqliteSnapshot(
  Database database,
  String path, {
  required List<String> tables,
  required int version,
  bool copyRows = true,
}) async {
  final alias = 'native_snapshot_${_attachmentSequence++}';
  final target = _identifier(alias);
  await database.execute('ATTACH DATABASE ? AS $target', [path]);
  try {
    await sqlite.transactionWithBusyRetry(database, (txn) async {
      for (final table in tables) {
        final name = _identifier(table);
        final schema = await txn.rawQuery(
          'SELECT sql FROM main.sqlite_master WHERE type = ? AND name = ?',
          ['table', table],
        );
        if (schema.length != 1 || schema.single['sql'] is! String) {
          throw StateError('Missing application table $table');
        }
        final definition = schema.single['sql'] as String;
        final columnsStart = definition.indexOf('(');
        if (!definition.toUpperCase().startsWith('CREATE TABLE ') ||
            columnsStart < 0) {
          throw StateError('Unsupported application table $table');
        }
        await txn.execute(
          'CREATE TABLE $target.$name ${definition.substring(columnsStart)}',
        );
        if (copyRows) {
          final columns = await _columns(txn, table);
          await txn.execute(
            'INSERT INTO $target.$name (rowid, $columns) '
            'SELECT rowid, $columns FROM main.$name ORDER BY rowid',
          );
        }
      }
      await txn.execute('PRAGMA $target.user_version = $version');
    });
  } finally {
    await detachNativeSqliteSnapshot(database, alias, path);
  }
}

Future<String> _columns(DatabaseExecutor db, String table) async {
  final columns = await db.rawQuery(
    'PRAGMA main.table_info(${_identifier(table)})',
  );
  if (columns.isEmpty) throw StateError('Missing application table $table');
  return columns.map((row) => _identifier(row['name'] as String)).join(', ');
}

/// Publishes a completed, closed native staging file through the live owner.
/// Its existing triggers, foreign keys and rollback behavior remain active.
/// Returns whether the private file detached and can be removed. A cleanup
/// failure after a durable commit must not report the publication as failed.
Future<bool> replaceTablesFromNativeSnapshot(
  Database database,
  String path, {
  required List<String> tables,
  required List<String> deleteOrder,
}) async {
  if (tables.toSet().length != tables.length ||
      deleteOrder.toSet().length != deleteOrder.length ||
      tables.length != deleteOrder.length ||
      !tables.toSet().containsAll(deleteOrder)) {
    throw ArgumentError('Table publication requires matching unique tables');
  }
  final alias = 'native_publish_${_attachmentSequence++}';
  final source = _identifier(alias);
  await database.execute('ATTACH DATABASE ? AS $source', [path]);
  var committed = false;
  var detached = true;
  try {
    await sqlite.transactionWithBusyRetry(database, (txn) async {
      for (final table in deleteOrder) {
        await txn.execute('DELETE FROM main.${_identifier(table)}');
      }
      for (final table in tables) {
        final name = _identifier(table);
        final columns = await _columns(txn, table);
        await txn.execute(
          'INSERT INTO main.$name ($columns) '
          'SELECT $columns FROM $source.$name ORDER BY rowid',
        );
      }
    });
    committed = true;
  } finally {
    try {
      await detachNativeSqliteSnapshot(database, alias, path);
    } on NativeSqliteSnapshotDetachException {
      if (!committed) rethrow;
      detached = false;
    }
  }
  return detached;
}
