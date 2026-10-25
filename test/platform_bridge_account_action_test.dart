import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'account form input is passed to the action without saving settings',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return '{"success":true,"state":"active"}';
          });
      final result = await PlatformBridge.invokeExtensionAction(
        'example.account',
        'loginAccount',
        input: {
          'username': 'fixture@example.test',
          'password': 'fixture-secret',
        },
      );
      expect(result['state'], 'active');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'invokeExtensionAction');
      final args = calls.single.arguments as Map;
      expect(jsonDecode(args['arguments_json'] as String), [
        {'username': 'fixture@example.test', 'password': 'fixture-secret'},
      ]);
    },
  );

  test('existing actions keep their original channel payload', () async {
    Map<dynamic, dynamic>? arguments;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          arguments = call.arguments as Map;
          return '{"success":true}';
        });
    await PlatformBridge.invokeExtensionAction(
      'example.account',
      'getAccountStatus',
    );
    expect(arguments!.containsKey('arguments_json'), isFalse);
  });
}
