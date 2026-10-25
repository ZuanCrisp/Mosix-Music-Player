import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/logger.dart';

Map<String, dynamic> _batch(String? message, int nextIndex) => {
  'logs': [
    if (message != null)
      {'level': 'ERROR', 'tag': 'Native', 'message': message},
  ],
  'next_index': nextIndex,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final buffer = LogBuffer();
  const interval = Duration(milliseconds: 800);

  tearDown(() {
    buffer.stopNativeLogPolling();
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('stop and restart serialize polls and ignore a stopped batch', (
    tester,
  ) async {
    final stopped = Completer<Map<String, dynamic>>();
    final indexes = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getLogsSince') return null;
      indexes.add((call.arguments as Map<Object?, Object?>)['index'] as int);
      if (indexes.length == 1) return stopped.future;
      return _batch(indexes.length == 2 ? 'fresh' : null, 4);
    });
    buffer.clear();
    await tester.pump();

    buffer.startNativeLogPolling();
    await tester.pump(interval);
    expect(indexes, [0]);

    buffer.stopNativeLogPolling();
    buffer.startNativeLogPolling();
    await tester.pump(interval);
    expect(indexes, [0]);

    stopped.complete(_batch('stopped', 20));
    await tester.pump();
    expect(buffer.entries, isEmpty);

    await tester.pump(interval);
    expect(indexes, [0, 0]);
    expect(buffer.entries.map((entry) => entry.message), ['fresh']);

    await tester.pump(interval);
    expect(indexes, [0, 0, 4]);
    buffer.stopNativeLogPolling();
  });

  testWidgets('clear rejects old logs and waits for native cursor reset', (
    tester,
  ) async {
    final oldBatch = Completer<Map<String, dynamic>>();
    final nativeClear = Completer<void>();
    final indexes = <int>[];
    var delayClear = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'clearLogs') {
        if (delayClear) await nativeClear.future;
        return null;
      }
      if (call.method != 'getLogsSince') return null;
      indexes.add((call.arguments as Map<Object?, Object?>)['index'] as int);
      if (indexes.length == 1) return oldBatch.future;
      return _batch(indexes.length == 2 ? 'after clear' : null, 1);
    });
    buffer.clear();
    await tester.pump();

    buffer.startNativeLogPolling();
    await tester.pump(interval);
    expect(indexes, [0]);

    delayClear = true;
    buffer.clear();
    await tester.pump();
    oldBatch.complete(_batch('before clear', 30));
    await tester.pump();
    expect(buffer.entries, isEmpty);

    await tester.pump(interval);
    expect(indexes, [0]);

    nativeClear.complete();
    await tester.pump();
    expect(indexes, [0, 0]);
    expect(buffer.entries.map((entry) => entry.message), ['after clear']);

    await tester.pump(interval);
    expect(indexes, [0, 0, 1]);
    buffer.stopNativeLogPolling();
  });
}
