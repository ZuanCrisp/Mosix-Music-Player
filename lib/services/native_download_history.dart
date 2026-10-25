import 'package:mornye/utils/logger.dart';

/// A completed file and a persisted Library entry are separate guarantees.
/// In particular, `already_exists` does not mean history was ever saved.
Future<void> reconcileNativeDownloadHistory({
  required Map<String, dynamic> result,
  required Future<void> Function(Map<String, dynamic>) adopt,
  required Future<void> Function() reload,
  required Future<void> Function() persistFallback,
}) async {
  final historyItem = result['history_item'];
  if (historyItem is Map) {
    try {
      await adopt(Map<String, dynamic>.from(historyItem));
      return;
    } catch (error) {
      AppLogger('DownloadHistory').w(
        'Failed to adopt native history item, retrying from download result: $error',
      );
    }
  } else if (result['history_written'] == true) {
    await reload();
    return;
  }
  await persistFallback();
}
