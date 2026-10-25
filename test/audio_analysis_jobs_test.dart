import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';

void main() {
  test(
    'replacement waits for cancelled session and skips stale queued work',
    () async {
      final completions = <Completer<String>>[];
      final started = <String>[];
      final cancelled = <int>[];
      final jobs = AudioAnalysisJobs<String>(
        start: (args) async {
          started.add(args.single);
          final done = Completer<String>();
          completions.add(done);
          return (id: completions.length, completed: done.future);
        },
        cancel: (id) async => cancelled.add(id),
      );
      final first = jobs.run(['old']);
      final firstCheck = expectLater(
        first,
        throwsA(isA<AudioAnalysisCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      final stale = jobs.run(['stale']);
      final staleCheck = expectLater(
        stale,
        throwsA(isA<AudioAnalysisCancelled>()),
      );
      jobs.invalidate();
      final latest = jobs.run(['latest']);
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, [1]);
      expect(started, ['old']);
      completions.first.complete('discarded');
      await firstCheck;
      await staleCheck;
      await Future<void>.delayed(Duration.zero);
      expect(started, ['old', 'latest']);
      completions.last.complete('result');
      expect(await latest, 'result');
      jobs.dispose();
    },
  );

  test(
    'dispose during session creation cancels its eventual session ID',
    () async {
      final creation = Completer<({int id, Future<String> completed})>();
      final completion = Completer<String>();
      final cancelled = <int>[];
      final jobs = AudioAnalysisJobs<String>(
        start: (_) => creation.future,
        cancel: (id) async => cancelled.add(id),
      );
      final result = jobs.run(['analysis']);
      final check = expectLater(result, throwsA(isA<AudioAnalysisCancelled>()));
      await Future<void>.delayed(Duration.zero);
      jobs.dispose();
      creation.complete((id: 42, completed: completion.future));
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, [42]);
      completion.complete('discarded');
      await check;
      await expectLater(
        jobs.run(['later']),
        throwsA(isA<AudioAnalysisCancelled>()),
      );
    },
  );
}
