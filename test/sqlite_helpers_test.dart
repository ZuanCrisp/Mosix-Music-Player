import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/sqlite_helpers.dart';

void main() {
  group('SingleFlightInitializer', () {
    test('coalesces concurrent initialization and caches the result', () async {
      final initializer = SingleFlightInitializer<int>();
      final gate = Completer<void>();
      var calls = 0;

      Future<int> create() async {
        calls++;
        await gate.future;
        return 42;
      }

      final first = initializer.getOrCreate(create);
      final second = initializer.getOrCreate(create);

      expect(identical(first, second), isTrue);
      expect(calls, 1);

      gate.complete();
      expect(await Future.wait([first, second]), [42, 42]);
      expect(await initializer.getOrCreate(create), 42);
      expect(calls, 1);
    });

    test('allows retry after initialization fails', () async {
      final initializer = SingleFlightInitializer<int>();
      var calls = 0;

      Future<int> create() {
        calls++;
        if (calls == 1) throw StateError('first attempt failed');
        return Future<int>.value(7);
      }

      await expectLater(initializer.getOrCreate(create), throwsStateError);
      expect(await initializer.getOrCreate(create), 7);
      expect(calls, 2);
    });

    test('reset permits a fresh initialization', () async {
      final initializer = SingleFlightInitializer<int>();
      var value = 1;

      expect(await initializer.getOrCreate(() async => value), 1);
      value = 2;
      expect(await initializer.getOrCreate(() async => value), 1);

      initializer.reset();
      expect(await initializer.getOrCreate(() async => value), 2);
    });
  });

  group('SQLite startup configuration', () {
    final source = File('lib/services/sqlite_helpers.dart').readAsStringSync();

    test('waits for transient locks before configuring the connection', () {
      final configureIndex = source.indexOf('onConfigure:');
      final busyTimeoutIndex = source.indexOf('PRAGMA busy_timeout');
      final journalModeIndex = source.indexOf('PRAGMA journal_mode');

      expect(configureIndex, greaterThanOrEqualTo(0));
      expect(busyTimeoutIndex, greaterThan(configureIndex));
      expect(busyTimeoutIndex, lessThan(journalModeIndex));
    });

    test('sets incremental auto-vacuum only before app tables exist', () {
      final schemaCheckIndex = source.indexOf('FROM sqlite_master');
      final emptySchemaGuardIndex = source.indexOf('if (tables.isEmpty)');
      final autoVacuumMatches = RegExp(
        r"PRAGMA auto_vacuum = INCREMENTAL",
      ).allMatches(source).toList();
      final onCreateIndex = source.indexOf('onCreate:');

      expect(autoVacuumMatches, hasLength(1));
      expect(schemaCheckIndex, greaterThanOrEqualTo(0));
      expect(emptySchemaGuardIndex, greaterThan(schemaCheckIndex));
      expect(
        autoVacuumMatches.single.start,
        greaterThan(emptySchemaGuardIndex),
      );
      expect(autoVacuumMatches.single.start, lessThan(onCreateIndex));
    });

    test('enables delete triggers for replace-backed FTS synchronization', () {
      expect(source, contains('PRAGMA recursive_triggers = ON'));
    });
  });

  group('FTS5 search query', () {
    test(
      'quotes literal input and leaves unsupported short terms to fallback',
      () {
        expect(ftsPhraseSearchQuery('ab'), isNull);
        expect(ftsPhraseSearchQuery('beat'), '"beat"');
        expect(ftsPhraseSearchQuery('foo"bar'), '"foo""bar"');
        expect(ftsPhraseSearchQuery('a\u0000b'), isNull);
      },
    );

    test('recognizes missing FTS5 and trigram capability errors', () {
      expect(
        isTrigramFts5UnavailableError(
          Exception('DatabaseException(no such module: fts5)'),
        ),
        isTrue,
      );
      expect(
        isTrigramFts5UnavailableError(
          Exception('DatabaseException(no such tokenizer: trigram)'),
        ),
        isTrue,
      );
      expect(
        isTrigramFts5UnavailableError(Exception('database is locked')),
        isFalse,
      );
    });

    test('probes the runtime with a temporary trigram FTS5 table', () {
      final source = File(
        'lib/services/sqlite_helpers.dart',
      ).readAsStringSync();

      expect(source, contains('CREATE VIRTUAL TABLE temp.'));
      expect(source, contains("tokenize='trigram'"));
      expect(source, contains('DROP TABLE IF EXISTS temp.'));
      expect(source, contains('_trigramFts5Capability ??='));
    });
  });
}
