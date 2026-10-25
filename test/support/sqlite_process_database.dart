import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

/// Executes repository SQL in real SQLite without a platform plugin.
/// Python's standard-library SQLite is also used by the existing SQL tests.
class SqliteProcessDatabase implements Database, Transaction {
  SqliteProcessDatabase._(this._process, this.path)
    : _responses = StreamIterator(
        _process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );

  final Process _process;
  final StreamIterator<String> _responses;
  @override
  final String path;

  static Future<SqliteProcessDatabase> open({String path = ':memory:'}) async =>
      SqliteProcessDatabase._(
        await Process.start('python3', [
          '-u',
          '-c',
          r'''
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1], isolation_level=None)
db.row_factory = sqlite3.Row
for line in sys.stdin:
    try:
        request = json.loads(line)
        cursor = db.execute(request['sql'], request.get('args', []))
        value = ([dict(row) for row in cursor.fetchall()] if request['rows']
                 else cursor.lastrowid if request.get('insert')
                 else max(cursor.rowcount, 0))
        print(json.dumps({'value': value}), flush=True)
    except Exception as error:
        print(json.dumps({'error': str(error)}), flush=True)
''',
          path,
        ]),
        path,
      );

  Future<Object?> _request(
    String sql,
    List<Object?>? args, {
    bool rows = false,
    bool insert = false,
  }) async {
    _process.stdin.writeln(
      jsonEncode({
        'sql': sql,
        'args': args ?? [],
        'rows': rows,
        'insert': insert,
      }),
    );
    await _process.stdin.flush();
    if (!await _responses.moveNext()) throw StateError('SQLite process exited');
    final response = jsonDecode(_responses.current) as Map;
    if (response['error'] != null) {
      throw StateError('${response['error']}\n$sql');
    }
    return response['value'];
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    await _request(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async => (await _request(sql, arguments, rows: true) as List)
      .map((row) => Map<String, Object?>.from(row as Map))
      .toList();

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async =>
      (await _request(sql, arguments, insert: true) as num).toInt();

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async =>
      (await _request(sql, arguments) as num).toInt();

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      rawUpdate(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => rawQuery(
    [
      'SELECT ${distinct == true ? 'DISTINCT ' : ''}${columns?.join(', ') ?? '*'} FROM $table',
      if (where != null) 'WHERE $where',
      if (groupBy != null) 'GROUP BY $groupBy',
      if (having != null) 'HAVING $having',
      if (orderBy != null) 'ORDER BY $orderBy',
      if (limit != null) 'LIMIT $limit',
      if (offset != null) 'OFFSET $offset',
    ].join(' '),
    whereArgs,
  );

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => rawInsert(
    'INSERT ${conflictAlgorithm == ConflictAlgorithm.ignore
        ? 'OR IGNORE '
        : conflictAlgorithm == ConflictAlgorithm.replace
        ? 'OR REPLACE '
        : ''}'
    'INTO $table (${values.keys.join(', ')}) VALUES (${List.filled(values.length, '?').join(', ')})',
    values.values.toList(),
  );

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => rawUpdate(
    'UPDATE $table SET ${values.keys.map((key) => '$key = ?').join(', ')}'
    '${where == null ? '' : ' WHERE $where'}',
    [...values.values, ...?whereArgs],
  );

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      rawDelete(
        'DELETE FROM $table${where == null ? '' : ' WHERE $where'}',
        whereArgs,
      );

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    await execute(exclusive == true ? 'BEGIN EXCLUSIVE' : 'BEGIN');
    try {
      final result = await action(this);
      await execute('COMMIT');
      return result;
    } catch (_) {
      await execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Batch batch() => _Batch(this);

  @override
  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode;
    await _responses.cancel();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Batch implements Batch {
  _Batch(this.database);
  final SqliteProcessDatabase database;
  final _operations = <Future<int> Function()>[];

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => _operations.add(
    () => database.insert(table, values, conflictAlgorithm: conflictAlgorithm),
  );

  @override
  void update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => _operations.add(
    () => database.update(table, values, where: where, whereArgs: whereArgs),
  );

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _operations.add(
        () => database.delete(table, where: where, whereArgs: whereArgs),
      );

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async {
    final results = <Object?>[];
    for (final operation in _operations) {
      final result = await operation();
      if (noResult != true) results.add(result);
    }
    _operations.clear();
    return results;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
