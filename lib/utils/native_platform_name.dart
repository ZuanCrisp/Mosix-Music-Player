import 'dart:io' show Platform;

import 'package:mornye/utils/desktop_platform.dart';

/// Platform label sent with native data jobs: `android`, `ios`, or the
/// desktop OS (`macos`, `windows`, `linux`). The native backend applies
/// Android SAF keys and iOS container rebasing only for those exact values,
/// so desktop paths pass through unchanged. It is never stored in backups.
String nativePlatformName() {
  if (Platform.isAndroid) return 'android';
  if (isDesktopPlatform) return Platform.operatingSystem;
  return 'ios';
}
