import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'runNativeDataJob' ? '{"value":1}' : null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'cancel before encoding completes never dispatches an idle job',
    () async {
      final expectation = expectLater(
        PlatformBridge.runNativeDataJob({
          'operation': 'hash_file',
          'path': '/unused',
        }, requestId: 'encoding'),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'CANCELLED'),
        ),
      );
      await PlatformBridge.cancelNativeDataJob('encoding');
      await expectation;
      expect(calls, isEmpty);
      expect(
        await PlatformBridge.runNativeDataJob({
          'operation': 'hash_file',
          'path': '/unused',
        }, requestId: 'encoding'),
        {'value': 1},
      );
    },
  );

  test(
    'active cancellation reaches native and preserves committed results',
    () async {
      final started = Completer<void>();
      final finished = Completer<String>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'runNativeDataJob') {
          started.complete();
          return finished.future;
        }
        return null;
      });
      final job = PlatformBridge.runNativeDataJob({
        'operation': 'library_import',
      }, requestId: 'active');
      await started.future;
      await PlatformBridge.cancelNativeDataJob('active');
      finished.complete('{"committed":true}');
      expect(await job, {'committed': true});
      expect(calls, ['runNativeDataJob', 'cancelNativeDataJob']);
      await PlatformBridge.cancelNativeDataJob('active');
      await PlatformBridge.cancelNativeDataJob('unknown');
      expect(calls, ['runNativeDataJob', 'cancelNativeDataJob']);
    },
  );

  test('failed encoding releases its request identity', () async {
    await expectLater(
      PlatformBridge.runNativeDataJob({
        'operation': Object(),
      }, requestId: 'invalid'),
      throwsA(isA<Object>()),
    );
    await PlatformBridge.cancelNativeDataJob('invalid');
    expect(calls, isEmpty);
    expect(
      await PlatformBridge.runNativeDataJob({
        'operation': 'palette',
      }, requestId: 'invalid'),
      {'value': 1},
    );
  });
}
