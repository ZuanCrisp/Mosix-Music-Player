import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_state.dart';

/// A native transfer sample, preserving raw values for logging/notifications.
/// Applying it handles UI quantization and protects terminal queue states.
class DownloadProgressSample {
  DownloadProgressSample.fromNative(Map<Object?, Object?> data)
    : status = data['status'] as String? ?? 'downloading',
      preparationStage = data['stage']?.toString() ?? '',
      bytesReceived = (data['bytes_received'] as num?)?.toInt() ?? 0,
      bytesTotal = (data['bytes_total'] as num?)?.toInt() ?? 0,
      speedMBps = (data['speed_mbps'] as num?)?.toDouble() ?? 0,
      backendProgress = (data['progress'] as num?)?.toDouble() ?? 0,
      isDownloading = data['is_downloading'] as bool? ?? false;

  final String status;
  final String preparationStage;
  final int bytesReceived;
  final int bytesTotal;
  final double speedMBps;
  final double backendProgress;
  final bool isDownloading;

  double get progress =>
      bytesTotal > 0 ? bytesReceived / bytesTotal : backendProgress;
  bool get hasProgress =>
      isDownloading ||
      bytesReceived > 0 ||
      bytesTotal > 0 ||
      backendProgress > 0;

  DownloadItem applyTo(DownloadItem current) {
    if (current.status == DownloadStatus.completed ||
        current.status == DownloadStatus.failed ||
        current.status == DownloadStatus.skipped ||
        (current.status == DownloadStatus.finalizing &&
            status != 'finalizing')) {
      return current;
    }
    final DownloadItem next;
    if (status == 'finalizing') {
      next = current.copyWith(
        status: DownloadStatus.finalizing,
        progress: 1,
        preparationStage: '',
      );
    } else if (status == 'preparing') {
      next = current.copyWith(
        status: DownloadStatus.downloading,
        progress: 0,
        speedMBps: 0,
        bytesReceived: 0,
        bytesTotal: 0,
        preparationStage: preparationStage,
      );
    } else if (hasProgress) {
      final clamped = progress.clamp(0.0, 1.0).toDouble();
      final rounded = double.parse(clamped.toStringAsFixed(2));
      next = current.copyWith(
        status: DownloadStatus.downloading,
        progress: clamped > 0 && rounded == 0 ? 0.01 : rounded,
        speedMBps: speedMBps <= 0
            ? 0
            : double.parse(speedMBps.toStringAsFixed(1)),
        // ~0.1 MiB, matching the queue's one-decimal MB display.
        bytesReceived: bytesReceived <= 0
            ? 0
            : (bytesReceived ~/ 104857) * 104857,
        bytesTotal: bytesTotal,
        preparationStage: '',
      );
    } else {
      return current;
    }
    return current.status == next.status &&
            current.progress == next.progress &&
            current.speedMBps == next.speedMBps &&
            current.bytesReceived == next.bytesReceived &&
            current.bytesTotal == next.bytesTotal &&
            current.preparationStage == next.preparationStage
        ? current
        : next;
  }
}

/// Tracks sampling cadence and notification deduplication for one queue run.
/// Platform calls remain in the orchestrator; this policy is platform-neutral.
class DownloadProgressTracker {
  int _idleTick = 0;
  final Map<String, int> _logBuckets = {};
  (String, String, int, int)? _notification;
  (String, String)? _finalizing;
  (String, String, String, int, int)? _service;
  DateTime? _serviceUpdatedAt;

  void resetPolling() => _idleTick = 0;

  bool shouldPoll(DownloadQueueState state) {
    final lookup = state.lookup;
    if (state.items.isNotEmpty &&
        (lookup.activeDownloadsCount > 0 || lookup.finalizingCount > 0)) {
      resetPolling();
      return true;
    }
    if (state.isPaused || state.items.isEmpty || lookup.queuedCount == 0) {
      resetPolling();
      return false;
    }
    _idleTick = (_idleTick + 1) % 3;
    return _idleTick == 0;
  }

  void pruneLogs(DownloadQueueLookup lookup) =>
      _logBuckets.removeWhere((id, _) {
        final status = lookup.byItemId[id]?.status;
        return status == null ||
            status == DownloadStatus.completed ||
            status == DownloadStatus.failed ||
            status == DownloadStatus.skipped;
      });

  bool shouldLog(String id, double progress, {bool preparing = false}) {
    final percent = (progress * 100).floor().clamp(0, 100);
    final bucket = preparing ? -1 : (percent ~/ 10) * 10;
    if (_logBuckets[id] == bucket) return false;
    _logBuckets[id] = bucket;
    return true;
  }

  static int _percent(int progress, int total) =>
      ((progress * 100) / (total > 0 ? total : 1)).round().clamp(0, 100);

  bool shouldNotify({
    required String trackName,
    required String artistName,
    required int progress,
    required int total,
    required int queueCount,
  }) {
    final content = (
      trackName,
      artistName,
      _percent(progress, total),
      queueCount,
    );
    if (content == _notification) return false;
    _notification = content;
    return true;
  }

  bool shouldNotifyFinalizing(String? trackName, String artistName) {
    final content = trackName == null ? null : (trackName, artistName);
    if (content == _finalizing) return false;
    _finalizing = content;
    return content != null;
  }

  bool shouldUpdateService({
    required String trackName,
    required String artistName,
    required int progress,
    required int total,
    required int queueCount,
    required String status,
    required DateTime now,
  }) {
    final bucket = total <= 0 ? -1 : (_percent(progress, total) ~/ 2) * 2;
    final content = (trackName, artistName, status, queueCount, bucket);
    if (content == _service &&
        now.difference(_serviceUpdatedAt!) < const Duration(seconds: 5)) {
      return false;
    }
    _service = content;
    _serviceUpdatedAt = now;
    return true;
  }

  void reset() {
    resetPolling();
    _logBuckets.clear();
    _notification = null;
    _finalizing = null;
    _service = null;
    _serviceUpdatedAt = null;
  }
}
