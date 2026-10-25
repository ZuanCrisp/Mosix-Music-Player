import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTransport implements NativeBackendTransport {
  final methods = <String>[];
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
  void subscribe(int kind) {}

  @override
  void unsubscribe(int kind) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(
    () => messenger.setMockMethodCallHandler(secure, (call) async => null),
  );
  tearDownAll(() => messenger.setMockMethodCallHandler(secure, null));

  tearDown(() {
    debugDesktopPlatformOverride = null;
    RustFfiBackend.debugShared = null;
  });

  test('desktop builds use the core backend and extension system', () {
    debugDesktopPlatformOverride = true;
    expect(PlatformBridge.supportsCoreBackend, isTrue);
    expect(PlatformBridge.supportsExtensionSystem, isTrue);

    // The test host is neither Android nor iOS.
    debugDesktopPlatformOverride = false;
    expect(PlatformBridge.supportsCoreBackend, isFalse);
    expect(PlatformBridge.supportsExtensionSystem, isFalse);
  });

  test('desktop initializes extensions through the Rust backend and drains '
      'callbacks queued at launch', () async {
    debugDesktopPlatformOverride = true;
    final transport = _FakeTransport()
      ..results.addAll({
        'loadExtensionsFromDir': {'loaded': 0, 'errors': <String>[]},
        'getInstalledExtensions': <Object?>[],
        'getProviderPriority': <String>[],
        'getMetadataProviderPriority': <String>[],
      });
    RustFfiBackend.debugShared = RustFfiBackend(
      openTransport: () => transport,
      loadConfig: () async => const DesktopBackendConfig(
        appSupportDir: '/support',
        documentsDir: '/documents',
        tempDir: '/tmp',
      ),
    );
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(extensionProvider.notifier)
        .initialize('/support/extensions', '/support/data', masterKey: 'key');

    final state = container.read(extensionProvider);
    expect(state.isInitialized, isTrue);
    expect(state.error, isNull);
    expect(
      transport.methods,
      containsAllInOrder([
        'initExtensionSystem',
        'loadExtensionsFromDir',
        'getInstalledExtensions',
        'processPendingExtensionCallbacks',
      ]),
    );
    // Android restores its process state natively; desktop has none.
    expect(transport.methods, isNot(contains('prepareRuntimeState')));
  });
}
