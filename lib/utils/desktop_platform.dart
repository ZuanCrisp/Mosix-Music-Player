import 'dart:io' show Platform;

/// Overrides [isDesktopPlatform] in tests.
bool? debugDesktopPlatformOverride;

// `flutter test` runs on a desktop host; tests see a mobile app unless they
// opt in through [debugDesktopPlatformOverride].
final bool _hostIsDesktop =
    !Platform.environment.containsKey('FLUTTER_TEST') &&
    (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// True in Windows, Linux and macOS builds of the app.
bool get isDesktopPlatform => debugDesktopPlatformOverride ?? _hostIsDesktop;
