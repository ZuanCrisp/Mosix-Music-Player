import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/sqlite_helpers.dart';

class _SqliteError extends DatabaseException {
  _SqliteError(super.message, this.code);
  final int? code;

  @override
  int? getResultCode() => code;
  @override
  Object? get result => null;
}

class _AdmissionDatabase implements Database, Transaction {
  int attempts = 0;
  int deniedBegins = 0;
  Object? beginError;
  Object? commitError;
  bool? observedExclusive;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    attempts++;
    observedExclusive = exclusive;
    if (attempts <= deniedBegins) throw beginError!;
    final result = await action(this);
    if (commitError != null) throw commitError!;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('transient BEGIN lock retries before invoking the body once', () async {
    final db = _AdmissionDatabase()
      ..deniedBegins = 2
      ..beginError = _SqliteError('database is locked', 5);
    var writes = 0;
    final result = await transactionWithBusyRetry(db, (txn) async {
      expect(txn, same(db));
      writes++;
      return 42;
    }, exclusive: true);
    expect(result, 42);
    expect(writes, 1);
    expect(db.attempts, 3);
    expect(db.observedExclusive, isTrue);
  });

  test(
    'persistent BEGIN lock stops after three attempts without writes',
    () async {
      final error = _SqliteError('database is locked', 5);
      final db = _AdmissionDatabase()
        ..deniedBegins = 10
        ..beginError = error;
      var writes = 0;
      await expectLater(
        transactionWithBusyRetry(db, (_) async => writes++),
        throwsA(same(error)),
      );
      expect(db.attempts, 3);
      expect(writes, 0);
    },
  );

  test('busy errors from an entered body are never replayed', () async {
    final db = _AdmissionDatabase();
    final error = _SqliteError('database is locked', 5);
    var writes = 0;
    await expectLater(
      transactionWithBusyRetry(db, (_) async {
        writes++;
        throw error;
      }),
      throwsA(same(error)),
    );
    expect(db.attempts, 1);
    expect(writes, 1);
  });

  test(
    'COMMIT errors are never replayed after the callback succeeds',
    () async {
      final error = _SqliteError('database is locked', 5);
      final db = _AdmissionDatabase()..commitError = error;
      var writes = 0;
      await expectLater(
        transactionWithBusyRetry(db, (_) async => writes++),
        throwsA(same(error)),
      );
      expect(db.attempts, 1);
      expect(writes, 1);
    },
  );

  test('non-lock BEGIN errors surface immediately', () async {
    final error = _SqliteError('no such table: library', 1);
    final db = _AdmissionDatabase()
      ..deniedBegins = 10
      ..beginError = error;
    await expectLater(
      transactionWithBusyRetry(db, (_) async => fail('body must not run')),
      throwsA(same(error)),
    );
    expect(db.attempts, 1);
  });

  test('extended BUSY codes and iOS lock messages are recognized', () async {
    for (final error in [
      _SqliteError('SQLITE_BUSY_SNAPSHOT', 517),
      _SqliteError('database table is locked', null),
    ]) {
      final db = _AdmissionDatabase()
        ..deniedBegins = 1
        ..beginError = error;
      expect(await transactionWithBusyRetry(db, (_) async => 'ok'), 'ok');
      expect(db.attempts, 2);
    }
  });
}
