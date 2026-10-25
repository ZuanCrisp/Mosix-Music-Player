import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_database.dart';
import 'package:sqflite/sqflite.dart';

class _SourcesDatabase implements Database, Transaction {
  final rows = <String, Map<String, Object?>>{};
  int transactions = 0;
  int inserts = 0;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    transactions++;
    return action(this);
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    expect(table, 'library_sources');
    final row = rows[whereArgs!.single];
    if (row == null) return 0;
    row.addAll(values);
    return 1;
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    expect(table, 'library_sources');
    inserts++;
    rows[values['id'] as String] = Map.of(values);
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const source = LocalLibrarySource(
    id: LibraryDatabase.legacySourceId,
    path: 'content://example.documents/tree/card%3AMusic',
    displayName: 'Music',
    isRemovable: true,
    available: false,
    bookmark: 'saved-bookmark',
  );

  test(
    'upgrade restores the old folder when the placeholder is missing',
    () async {
      final database = _SourcesDatabase();
      await persistLegacyLibrarySource(database, source);
      final restored = database.rows[LibraryDatabase.legacySourceId]!;
      expect(restored['path'], source.path);
      expect(restored['bookmark'], source.bookmark);
      expect(restored['available'], 0);
      expect(restored['enabled'], 1);
      expect(restored['is_removable'], 1);
      expect(database.transactions, 1);
      await persistLegacyLibrarySource(database, source);
      expect(database.rows.length, 1);
      expect(database.inserts, 1);
    },
  );

  test(
    'migration preserves the existing source identity and disabled state',
    () async {
      final database = _SourcesDatabase();
      database.rows[LibraryDatabase.legacySourceId] = {
        'id': LibraryDatabase.legacySourceId,
        'path': 'legacy://local-library',
        'enabled': 0,
        'last_scan_error': 'previous scan error',
      };
      await persistLegacyLibrarySource(database, source);
      final restored = database.rows[LibraryDatabase.legacySourceId]!;
      expect(restored['id'], LibraryDatabase.legacySourceId);
      expect(restored['enabled'], 0);
      expect(restored['last_scan_error'], 'previous scan error');
      expect(restored['path'], source.path);
      expect(database.inserts, 0);
    },
  );
}
