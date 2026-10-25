import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('DeepLinks');

/// Receives `mornye://` URLs on desktop. The mobile hosts handle the scheme
/// natively; desktop gets the launch URL and later ones through app_links
/// (Apple events on macOS, the single-instance forwarding in the Windows and
/// Linux runners). Extension callbacks go to the backend inbox, which then
/// raises `extensionAuthCallbackReceived` like the mobile hosts do.
class DesktopDeepLinks {
  DesktopDeepLinks({
    Stream<Uri>? links,
    Future<bool> Function(String url)? queueCallback,
  }) : _links = links,
       _queueCallback =
           queueCallback ?? PlatformBridge.queueExtensionCallbackUrl;

  final Stream<Uri>? _links;
  final Future<bool> Function(String url) _queueCallback;
  StreamSubscription<Uri>? _subscription;

  static bool isAppLink(Uri uri) => uri.scheme.toLowerCase() == 'mornye';

  /// The URL without its query, which carries one time codes and grants.
  static String describe(Uri uri) =>
      '${uri.scheme}://${uri.host}${uri.path}${uri.hasQuery ? '?...' : ''}';

  /// Starts listening; app_links replays the launch URL to the first
  /// listener.
  void start() {
    _subscription ??= (_links ?? AppLinks().uriLinkStream).listen(
      (uri) => unawaited(handle(uri)),
      onError: (Object error) => _log.w('Deep link stream failed: $error'),
    );
  }

  /// Returns whether the backend accepted [uri] as an extension callback.
  Future<bool> handle(Uri uri) async {
    if (!isAppLink(uri)) return false;
    _log.i('Received deep link ${describe(uri)}');
    try {
      final queued = await _queueCallback(uri.toString());
      if (!queued) _log.d('Deep link is not an extension callback');
      return queued;
    } catch (error) {
      _log.w('Could not hand the deep link to the backend: $error');
      return false;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}
