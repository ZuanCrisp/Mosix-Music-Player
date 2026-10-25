import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/desktop_deep_links.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

class _FakeTransport implements NativeBackendTransport {
  final calls = <(String, Object?)>[];
  late NativeMessageListener listener;

  @override
  void init(Uint8List configJson, NativeMessageListener listener) =>
      this.listener = listener;

  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    final args = jsonDecode(utf8.decode(argsJson));
    calls.add((method, args));
    final url = args is Map ? args['url']?.toString() ?? '' : '';
    final result = method == 'queueExtensionCallbackUrl'
        ? url.contains('callback')
        : null;
    scheduleMicrotask(
      () => listener(
        id,
        NativeMessageKind.result,
        utf8.encode(jsonEncode(result)),
      ),
    );
    if (result == true) {
      // The backend raises the same inbound call the mobile hosts send.
      scheduleMicrotask(
        () => listener(
          0,
          NativeMessageKind.inboundCall,
          utf8.encode(
            jsonEncode({
              'method': 'extensionAuthCallbackReceived',
              'arguments': null,
            }),
          ),
        ),
      );
    }
  }

  @override
  void subscribe(int kind) {}

  @override
  void unsubscribe(int kind) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final transport = _FakeTransport();

  setUpAll(() {
    debugDesktopPlatformOverride = true;
    RustFfiBackend.debugShared = RustFfiBackend(
      openTransport: () => transport,
      loadConfig: () async => const DesktopBackendConfig(
        appSupportDir: '/support',
        documentsDir: '/documents',
        tempDir: '/tmp',
      ),
    );
  });

  tearDownAll(() {
    debugDesktopPlatformOverride = null;
    RustFfiBackend.debugShared = null;
  });

  setUp(transport.calls.clear);

  test('only mornye URLs are app links, logged without the query', () {
    expect(DesktopDeepLinks.isAppLink(Uri.parse('MORNYE://callback')), true);
    expect(DesktopDeepLinks.isAppLink(Uri.parse('https://example.com')), false);
    expect(
      DesktopDeepLinks.describe(
        Uri.parse('mornye://callback?code=secret&state=nonce'),
      ),
      'mornye://callback?...',
    );
    expect(
      DesktopDeepLinks.describe(Uri.parse('mornye://test')),
      'mornye://test',
    );
  });

  test(
    'a callback URL reaches the backend and raises the auth event',
    () async {
      final events = <void>[];
      final subscription = PlatformBridge.extensionAuthCallbackEvents().listen(
        events.add,
      );
      addTearDown(subscription.cancel);
      final links = StreamController<Uri>();
      addTearDown(links.close);
      final deepLinks = DesktopDeepLinks(links: links.stream)..start();
      addTearDown(deepLinks.dispose);

      links.add(Uri.parse('https://example.com/ignored'));
      links.add(Uri.parse('mornye://callback?code=a&state=b'));
      await pumpEventQueue();

      expect(transport.calls, hasLength(1));
      expect(transport.calls.single.$1, 'queueExtensionCallbackUrl');
      expect(transport.calls.single.$2, {
        'url': 'mornye://callback?code=a&state=b',
      });
      expect(events, hasLength(1));
    },
  );

  test('a non-callback mornye URL is reported as not queued', () async {
    final deepLinks = DesktopDeepLinks();
    expect(await deepLinks.handle(Uri.parse('mornye://test')), false);
    expect(transport.calls.single.$1, 'queueExtensionCallbackUrl');
  });

  test('backend failures do not escape the handler', () async {
    final deepLinks = DesktopDeepLinks(
      queueCallback: (_) async => throw StateError('backend gone'),
    );
    expect(await deepLinks.handle(Uri.parse('mornye://callback?x')), false);
  });
}
