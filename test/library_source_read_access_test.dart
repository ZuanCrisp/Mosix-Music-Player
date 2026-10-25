import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  const tree = 'content://example.documents/tree/sd-card%3AMusic';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('readable Library never runs download write validation', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'probeSafTreeReadAccess');
      expect(call.arguments, {'tree_uri': tree});
      return true;
    });
    expect(await PlatformBridge.probeSafTreeReadAccess(tree), isTrue);
  });

  test('a transient empty root recovers before being marked offline', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'probeSafTreeReadAccess');
      return ++calls > 1;
    });
    expect(await PlatformBridge.probeSafTreeReadAccess(tree), isTrue);
    expect(calls, 2);
  });

  test('only confirmed negative read access marks a source offline', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return false;
    });
    expect(await PlatformBridge.probeSafTreeReadAccess(tree), isFalse);
    expect(calls, 2);
  });

  test('unknown provider state remains unknown and can recover', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (++calls == 1) return null;
      return true;
    });
    expect(await PlatformBridge.probeSafTreeReadAccess(tree), isNull);
    expect(await PlatformBridge.probeSafTreeReadAccess(tree), isTrue);
  });

  test('channel failure cannot confirm that a Library is offline', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'provider_busy');
    });
    expect(await PlatformBridge.probeSafTreeReadAccess(tree), isNull);
  });

  test('failed confirmation is inconclusive, not a lost grant', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (++calls == 1) return false;
      throw PlatformException(code: 'provider_busy');
    });
    expect(await PlatformBridge.probeSafTreeReadAccess(tree), isNull);
  });
}
