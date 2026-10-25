import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/sqlite_helpers.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:sqflite/sqflite.dart';

class _RecordingBatch implements Batch {
  final operations = <String>[];

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    operations.add('delete $table ${whereArgs?.single}');
  }

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    expect(conflictAlgorithm, ConflictAlgorithm.ignore);
    operations.add('insert $table ${values['item_id']} ${values['path_key']}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const path = '/storage/emulated/0/Music/Album/01 Song.flac';

  test('path keys replace existing rows by default', () {
    final batch = _RecordingBatch();
    putPathKeysInBatch(batch, 'stage_keys', 'lib_1', path);
    expect(batch.operations.first, 'delete stage_keys lib_1');
    expect(batch.operations.skip(1), [
      for (final key in buildPathMatchKeys(path))
        'insert stage_keys lib_1 $key',
    ]);
  });

  test('first row in a fresh stage writes the same keys without a delete', () {
    final batch = _RecordingBatch();
    putPathKeysInBatch(
      batch,
      'stage_keys',
      'lib_1',
      path,
      replaceExisting: false,
    );
    expect(batch.operations, [
      for (final key in buildPathMatchKeys(path))
        'insert stage_keys lib_1 $key',
    ]);
  });
}
