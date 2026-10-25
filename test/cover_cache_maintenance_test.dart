import 'dart:async';
import 'dart:io';
import 'package:mornye/utils/cache_byte_budget.dart';
import 'package:mornye/utils/periodic_async_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'maintenance repeats without overlapping and survives pause/resume and failure',
    (tester) async {
      final pending = <Completer<void>>[];
      var errors = 0;
      final task = PeriodicAsyncTask(
        interval: const Duration(minutes: 15),
        run: () {
          final done = Completer<void>();
          pending.add(done);
          return done.future;
        },
        onError: (_, _) => errors++,
      );
      addTearDown(task.stop);
      task.start(delay: const Duration(seconds: 20));
      task.start(delay: Duration.zero);
      await tester.pump(const Duration(seconds: 19));
      expect(pending, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(pending, hasLength(1));
      await tester.pump(const Duration(minutes: 30));
      expect(pending, hasLength(1));
      task.stop();
      task.start(delay: Duration.zero);
      await tester.pump(const Duration(milliseconds: 1));
      expect(pending, hasLength(1));
      pending[0].complete();
      await tester.pump();
      expect(pending, hasLength(2));
      pending[1].completeError(StateError('temporary I/O error'));
      await tester.pump();
      expect(errors, 1);
      await tester.pump(const Duration(minutes: 15));
      expect(pending, hasLength(3));
      task.stop();
      pending[2].complete();
      await tester.pump(const Duration(hours: 1));
      expect(pending, hasLength(3));
    },
  );

  test(
    'cache budget trims oldest payloads while retaining metadata and new files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cover-budget-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      Future<File> file(String name, int minutesOld) async {
        final file = File('${directory.path}/$name');
        await file.writeAsBytes(List.filled(100, 0));
        await file.setLastModified(
          DateTime.now().subtract(Duration(minutes: minutesOld)),
        );
        return file;
      }

      final oldest = await file('old-cover', 60);
      final newer = await file('newer-cover', 10);
      final active = await file('active-cover', 0);
      final metadata = await file('cache.json', 120);
      expect(
        await trimCacheToByteBudget(directory, maxBytes: 350, targetBytes: 150),
        0,
      );
      expect(
        await trimCacheToByteBudget(directory, maxBytes: 250, targetBytes: 150),
        2,
      );
      expect(await oldest.exists(), isFalse);
      expect(await newer.exists(), isFalse);
      expect(await active.exists(), isTrue);
      expect(await metadata.exists(), isTrue);
    },
  );

  test('mobile budget uses a single native operation with exact age', () async {
    final directory = await Directory.systemTemp.createTemp('native-budget-');
    addTearDown(() => directory.delete(recursive: true));
    final payload = await File('${directory.path}/keep').writeAsBytes([1]);
    final deleted = await trimCacheToByteBudget(
      directory,
      maxBytes: 100,
      targetBytes: 50,
      minimumAge: const Duration(microseconds: 60000001),
      nativeJobRunner: (request, {requestId}) async {
        expect(request, {
          'operation': 'cache_trim_budget',
          'directory': directory.absolute.path,
          'max_bytes': 100,
          'target_bytes': 50,
          'minimum_age_us': 60000001,
        });
        return {'deleted': 7};
      },
    );
    expect(deleted, 7);
    expect(await payload.exists(), isTrue);
  });

  test(
    'invalid native budget results never trigger destructive fallback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'invalid-budget-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final payload = await File('${directory.path}/keep').writeAsBytes([1]);
      await payload.setLastModified(DateTime(2020));
      await expectLater(
        trimCacheToByteBudget(
          directory,
          maxBytes: 0,
          targetBytes: 0,
          nativeJobRunner: (request, {requestId}) async => {'deleted': -1},
        ),
        throwsStateError,
      );
      expect(await payload.exists(), isTrue);
    },
  );
}
