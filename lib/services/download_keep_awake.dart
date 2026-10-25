import 'package:flutter/foundation.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('DownloadKeepAwake');

/// Keeps the computer awake while the download queue runs: the desktop
/// counterpart of the Android foreground service and the iOS background
/// task. Failures are logged and never stop the queue.
abstract interface class DownloadKeepAwake {
  Future<void> begin();
  Future<void> end();
}

/// The backend sleep inhibitor on desktop; nothing on mobile.
class BackendDownloadKeepAwake implements DownloadKeepAwake {
  const BackendDownloadKeepAwake();

  @override
  Future<void> begin() async {
    if (!isDesktopPlatform) return;
    try {
      if (!await PlatformBridge.beginKeepAwake()) {
        _log.w('The system did not grant a sleep inhibitor for downloads');
      }
    } catch (e) {
      _log.w('Failed to keep the system awake for downloads: $e');
    }
  }

  @override
  Future<void> end() async {
    if (!isDesktopPlatform) return;
    try {
      await PlatformBridge.endKeepAwake();
    } catch (e) {
      _log.w('Failed to release the download sleep inhibitor: $e');
    }
  }
}

DownloadKeepAwake _downloadKeepAwake = const BackendDownloadKeepAwake();

DownloadKeepAwake get downloadKeepAwake => _downloadKeepAwake;

@visibleForTesting
set debugDownloadKeepAwake(DownloadKeepAwake? value) =>
    _downloadKeepAwake = value ?? const BackendDownloadKeepAwake();
