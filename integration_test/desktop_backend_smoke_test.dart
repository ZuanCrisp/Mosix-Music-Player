import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/backend/backend_channel.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Runs the desktop app against the bundled Rust library (set
/// `MORNYE_DESKTOP_LIB` to test another build):
/// `fvm flutter test integration_test/desktop_backend_smoke_test.dart -d macos`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final desktopHost =
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  setUpAll(() => debugDesktopPlatformOverride = true);
  tearDownAll(() => debugDesktopPlatformOverride = null);

  testWidgets('backend calls reach the Rust library', (tester) async {
    final implementations = await PlatformBridge.getBackendImplementations();
    expect(implementations, isNotEmpty);

    final sanitized = await PlatformBridge.sanitizeFilename('a/b:c?.flac');
    expect(sanitized, isNot(contains('/')));
    expect(sanitized, endsWith('.flac'));

    final filename = await PlatformBridge.buildFilename('{artist} - {title}', {
      'artist': 'Artist',
      'title': 'Title',
    });
    expect(filename, 'Artist - Title');
  }, skip: !desktopHost);

  testWidgets('mobile-only methods report a missing plugin', (tester) async {
    await expectLater(
      backendChannel.invokeMethod('pickSafTree'),
      throwsA(isA<MissingPluginException>()),
    );
  }, skip: !desktopHost);
}
