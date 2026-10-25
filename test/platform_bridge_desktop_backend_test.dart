import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/native_log_source.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

class _FakeTransport implements NativeBackendTransport {
  final methods = <String>[];
  final subscriptions = <int>[];
  final results = <String, Object?>{};
  late NativeMessageListener listener;

  @override
  void init(Uint8List configJson, NativeMessageListener listener) =>
      this.listener = listener;

  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    methods.add(method);
    scheduleMicrotask(
      () => listener(
        id,
        NativeMessageKind.result,
        utf8.encode(jsonEncode(results[method])),
      ),
    );
  }

  @override
  void subscribe(int kind) => subscriptions.add(kind);

  @override
  void unsubscribe(int kind) => subscriptions.remove(kind);

  void push(int kind, Object? value) =>
      listener(0, kind, utf8.encode(jsonEncode(value)));
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

  test('bridge calls reach the Rust backend on desktop', () async {
    transport.results['getAllDownloadProgress'] = {
      'items': {'a': 1},
    };
    expect(await PlatformBridge.getAllDownloadProgress(), {
      'items': {'a': 1},
    });
    await const NativeLogSource().clear();
    expect(transport.methods, ['getAllDownloadProgress', 'clearLogs']);
  });

  test('progress streams come from native events', () async {
    final events = <Map<String, dynamic>>[];
    final subscription = PlatformBridge.downloadProgressStream().listen(
      events.add,
    );
    await pumpEventQueue();
    expect(transport.subscriptions, [NativeMessageKind.downloadProgress]);
    transport.push(NativeMessageKind.downloadProgress, {
      'items': {'a': 0.25},
    });
    await pumpEventQueue();
    await subscription.cancel();
    expect(events, [
      {
        'items': {'a': 0.25},
      },
    ]);
    expect(transport.subscriptions, isEmpty);
  });

  test('inbound calls reach the bridge handler', () async {
    final grants = <ExtensionSessionGrantEvent>[];
    final subscription = PlatformBridge.extensionSessionGrantEvents().listen(
      grants.add,
    );
    final taps = PlatformBridge.verificationNotificationEvents().first;
    transport.push(NativeMessageKind.inboundCall, {
      'method': 'extensionSessionGrantCompleted',
      'arguments': {'extension_id': 'example', 'success': false},
    });
    transport.push(NativeMessageKind.inboundCall, {
      'method': 'extensionVerificationNotificationTapped',
      'arguments': null,
    });
    await taps;
    await pumpEventQueue();
    await subscription.cancel();
    expect(grants.single.extensionId, 'example');
    expect(grants.single.success, isFalse);
  });
}
