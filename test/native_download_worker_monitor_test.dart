import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/native_download_worker_monitor.dart';

void main() {
  Map<String, dynamic> snapshot({
    bool running = true,
    bool paused = false,
    int serial = 1,
    String run = 'run-a',
  }) => {
    'run_id': run,
    'is_running': running,
    'is_paused': paused,
    'state_serial': serial,
    'items': [
      {
        'item_id': 'done',
        'status': 'completed',
        'result': {'file_path': '/song.flac'},
      },
      {'item_id': 'active', 'status': 'downloading'},
      {'item_id': 'waiting', 'status': 'queued'},
    ],
  };

  NativeDownloadWorkerMonitor monitor({
    required Future<Map<String, dynamic>> Function({int sinceStateSerial}) read,
    required Future<bool> Function() alive,
  }) => NativeDownloadWorkerMonitor(
    readSnapshot: read,
    matchesRun: (value) => value['run_id'] == 'run-a',
    isServiceAlive: alive,
    pollInterval: Duration.zero,
    startupPollInterval: Duration.zero,
  );

  test(
    'a stale running snapshot releases the monitor after service death',
    () async {
      final stale = snapshot(paused: true);
      final seen = <Map<String, dynamic>>[];
      final cursors = <int>[];
      var aliveChecks = 0;
      final result = await monitor(
        read: ({int sinceStateSerial = 0}) async {
          cursors.add(sinceStateSerial);
          return stale;
        },
        alive: () async {
          aliveChecks++;
          return false;
        },
      ).run(onSnapshot: (value) async => seen.add(value));

      expect(result, NativeDownloadWorkerExit.serviceLost);
      expect(aliveChecks, 3);
      expect(cursors, [0, 1, 1]);
      expect(seen.map((value) => value['is_running']), [true, true, false]);
      expect(
        seen.last['items'],
        stale['items'],
        reason: 'Keep completed outputs for reconciliation',
      );
      expect(
        stale['is_running'],
        isTrue,
        reason: 'Do not mutate the native snapshot',
      );
    },
  );

  test(
    'temporary service probe failures do not abort a live paused run',
    () async {
      final probes = [false, false, true, false, false, true].iterator;
      var reads = 0;
      var calls = 0;
      final seen = <bool>[];
      final result = await monitor(
        read: ({int sinceStateSerial = 0}) async =>
            snapshot(running: ++reads <= 6, paused: true),
        alive: () async {
          calls++;
          expect(probes.moveNext(), isTrue);
          return probes.current;
        },
      ).run(onSnapshot: (value) async => seen.add(value['is_running'] == true));
      expect(result, NativeDownloadWorkerExit.stopped);
      expect(calls, 6);
      expect(seen, [true, true, true, true, true, true, false]);
    },
  );

  test('a stopped snapshot needs no service probe', () async {
    var reconciled = false;
    expect(
      await monitor(
        read: ({int sinceStateSerial = 0}) async => snapshot(running: false),
        alive: () async => throw StateError('Service already stopped'),
      ).run(onSnapshot: (_) async => reconciled = true),
      NativeDownloadWorkerExit.stopped,
    );
    expect(reconciled, isTrue);
  });

  test(
    'service death with another run snapshot never adopts its items',
    () async {
      var reads = 0;
      final seen = <String>[];
      final result = await monitor(
        read: ({int sinceStateSerial = 0}) async =>
            snapshot(run: ++reads == 1 ? 'run-a' : 'run-b'),
        alive: () async => false,
      ).run(onSnapshot: (value) async => seen.add(value['run_id'] as String));
      expect(result, NativeDownloadWorkerExit.serviceLost);
      expect(seen, ['run-a']);
      expect(reads, 3);
    },
  );

  test(
    'a missing initial snapshot retains the bounded startup failure',
    () async {
      var reconciled = false;
      await expectLater(
        NativeDownloadWorkerMonitor(
          readSnapshot: ({int sinceStateSerial = 0}) async =>
              snapshot(run: 'old'),
          matchesRun: (value) => value['run_id'] == 'run-a',
          isServiceAlive: () async => false,
          startupTimeout: Duration.zero,
          startupPollInterval: Duration.zero,
        ).run(onSnapshot: (_) async => reconciled = true),
        throwsA(isA<NativeDownloadWorkerStartupTimeout>()),
      );
      expect(reconciled, isFalse);
    },
  );

  test(
    'verification reconciliation completes before polling advances',
    () async {
      final verification = Completer<void>();
      final waiting = Completer<void>();
      final cursors = <int>[];
      final result =
          monitor(
            read: ({int sinceStateSerial = 0}) async {
              cursors.add(sinceStateSerial);
              return snapshot(running: cursors.length == 1, serial: 9);
            },
            alive: () async => true,
          ).run(
            onSnapshot: (value) async {
              if (value['is_running'] == true) {
                waiting.complete();
                await verification.future;
              }
            },
          );
      await waiting.future;
      await Future<void>.delayed(Duration.zero);
      expect(cursors, [0]);
      verification.complete();
      expect(await result, NativeDownloadWorkerExit.stopped);
      expect(cursors, [0, 9]);
    },
  );
}
