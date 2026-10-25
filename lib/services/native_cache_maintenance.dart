import 'package:mornye/services/platform_bridge.dart';

typedef NativeCacheJobRunner =
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> request, {
      String? requestId,
    });

/// Returns null on the desktop adapter. Mobile filesystem work uses the
/// existing cancellable native worker without changing the public FFI API.
Future<Map<String, dynamic>?> runNativeCacheMaintenance(
  Map<String, dynamic> request, {
  String? requestId,
  NativeCacheJobRunner? nativeJobRunner,
}) async {
  if (nativeJobRunner != null) {
    return nativeJobRunner(request, requestId: requestId);
  }
  if (!PlatformBridge.supportsCoreBackend) return null;
  return PlatformBridge.runNativeDataJob(request, requestId: requestId);
}

int cacheMaintenanceDeletedCount(Map<String, dynamic> result) {
  final deleted = result['deleted'];
  if (deleted is! int || deleted < 0) {
    throw StateError('Invalid native cache maintenance result');
  }
  return deleted;
}
