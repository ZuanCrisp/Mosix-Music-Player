// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _DownloadQueueProgress on DownloadQueueNotifier {
  void _startMultiProgressPolling() {
    _progressTracker.resetPolling();
    _progressPoller.start(useStream: Platform.isAndroid || Platform.isIOS);
  }

  void _processAllDownloadProgress(Map<String, dynamic> allProgress) {
    final rawItems = allProgress['items'];
    // Native progress maps are only read here, so view them without copying
    // the queue map and every item map on each tick.
    final items = rawItems is Map ? rawItems : const <Object?, Object?>{};
    final currentItems = state.items;
    final lookup = state.lookup;
    _progressTracker.pruneLogs(lookup);
    final queuedCount = lookup.queuedCount;
    final downloadingCount = lookup.activeDownloadsCount;
    final firstDownloading = lookup.firstDownloading;
    final firstFinalizing = lookup.firstFinalizing;
    bool hasFinalizingItem = lookup.finalizingCount > 0;
    String? finalizingTrackName = firstFinalizing?.track.name;
    String? finalizingArtistName = firstFinalizing?.track.artistName;
    final replacements = <int, DownloadItem>{};

    for (final entry in items.entries) {
      final itemId = entry.key.toString();
      final localItem = lookup.byItemId[itemId];
      if (localItem == null) {
        continue;
      }
      if (_isPausePending(itemId)) {
        PlatformBridge.clearItemProgress(itemId).catchError((_) {});
        continue;
      }
      if (localItem.status == DownloadStatus.skipped) {
        PlatformBridge.clearItemProgress(itemId).catchError((_) {});
        continue;
      }
      if (localItem.status == DownloadStatus.completed ||
          localItem.status == DownloadStatus.failed) {
        continue;
      }
      if (localItem.status == DownloadStatus.finalizing) {
        PlatformBridge.clearItemProgress(itemId).catchError((_) {});
        hasFinalizingItem = true;
        finalizingTrackName = localItem.track.name;
        finalizingArtistName = localItem.track.artistName;
        continue;
      }
      final rawItemProgress = entry.value;
      if (rawItemProgress is! Map) {
        continue;
      }
      final sample = DownloadProgressSample.fromNative(rawItemProgress);
      final next = sample.applyTo(localItem);
      if (!identical(next, localItem)) {
        replacements[lookup.indexByItemId[itemId]!] = next;
      }
      if (sample.status == 'finalizing') {
        hasFinalizingItem = true;
        finalizingTrackName = localItem.track.name;
        finalizingArtistName = localItem.track.artistName;
        continue;
      }

      if (sample.status == 'preparing') {
        if (LogBuffer.loggingEnabled &&
            _progressTracker.shouldLog(itemId, 0, preparing: true)) {
          _log.d('Preparing [$itemId]: waiting for real download bytes');
        }
        continue;
      }

      if (sample.hasProgress &&
          LogBuffer.loggingEnabled &&
          _progressTracker.shouldLog(itemId, sample.progress)) {
        final percentage = sample.progress;
        final mbReceived = sample.bytesReceived / (1024 * 1024);
        final mbTotal = sample.bytesTotal / (1024 * 1024);
        final speedMBps = sample.speedMBps;
        if (sample.bytesTotal > 0) {
          _log.d(
            'Progress [$itemId]: ${(percentage * 100).toStringAsFixed(1)}% (${mbReceived.toStringAsFixed(2)}/${mbTotal.toStringAsFixed(2)} MB) @ ${speedMBps.toStringAsFixed(2)} MB/s',
          );
        } else {
          _log.d(
            'Progress [$itemId]: ${(percentage * 100).toStringAsFixed(1)}% (stream/unknown size) @ ${speedMBps.toStringAsFixed(2)} MB/s',
          );
        }
      }
    }

    if (replacements.isNotEmpty) {
      final updatedItems = ChunkedList<DownloadItem>.from(
        currentItems,
      ).updated(replacements);
      state = state.copyWith(
        items: updatedItems,
        lookup: state.lookup.updatedForIndices(
          previousItems: currentItems,
          nextItems: updatedItems,
          changedIndices: replacements.keys,
        ),
      );
    }

    if (hasFinalizingItem && finalizingTrackName != null) {
      final safeArtistName = finalizingArtistName ?? '';
      if (Platform.isAndroid) {
        _maybeUpdateAndroidDownloadService(
          trackName: finalizingTrackName,
          artistName: _notificationService.embeddingMetadataLabel,
          progress: 100,
          total: 100,
          queueCount: queuedCount,
          status: 'finalizing',
        );
      } else if (_progressTracker.shouldNotifyFinalizing(
        finalizingTrackName,
        safeArtistName,
      )) {
        _notificationService.showDownloadFinalizing(
          trackName: finalizingTrackName,
          artistName: safeArtistName,
        );
      }
      return;
    }
    _progressTracker.shouldNotifyFinalizing(null, '');

    if (items.isNotEmpty) {
      if (downloadingCount > 0 && firstDownloading != null) {
        final rawProgress = items[firstDownloading.id];
        if (rawProgress is! Map) {
          return;
        }
        final selectedProgress = rawProgress;
        final bytesReceived =
            (selectedProgress['bytes_received'] as num?)?.toInt() ?? 0;
        final bytesTotal =
            (selectedProgress['bytes_total'] as num?)?.toInt() ?? 0;
        final backendStatus =
            selectedProgress['status'] as String? ?? 'downloading';
        final trackName = downloadingCount == 1
            ? firstDownloading.track.name
            : '$downloadingCount downloads';
        final artistName = downloadingCount == 1
            ? firstDownloading.track.artistName
            : 'Downloading...';

        int notifProgress = bytesReceived;
        int notifTotal = bytesTotal;

        final progressPercent =
            (selectedProgress['progress'] as num?)?.toDouble() ?? 0.0;
        if (backendStatus == 'preparing') {
          notifProgress = 0;
          notifTotal = 0;
        } else if (bytesTotal <= 0) {
          notifTotal = PlatformBridge.notificationPercentTotal;
          notifProgress = (progressPercent * notifTotal)
              .round()
              .clamp(0, notifTotal)
              .toInt();
        }
        final serviceStatus = notifTotal <= 0 ? 'preparing' : 'downloading';

        if (!Platform.isAndroid &&
            _progressTracker.shouldNotify(
              trackName: trackName,
              artistName: artistName,
              progress: notifProgress,
              total: notifTotal,
              queueCount: queuedCount,
            )) {
          final safeNotifTotal = notifTotal > 0 ? notifTotal : 1;
          _notificationService.showDownloadProgress(
            trackName: trackName,
            artistName: artistName,
            progress: notifProgress,
            total: safeNotifTotal,
          );
        }

        if (Platform.isAndroid) {
          _maybeUpdateAndroidDownloadService(
            trackName: firstDownloading.track.name,
            artistName: firstDownloading.track.artistName,
            progress: notifProgress,
            total: notifTotal,
            queueCount: queuedCount,
            status: serviceStatus,
          );
        }
      }
    }
  }

  void _maybeUpdateAndroidDownloadService({
    required String trackName,
    required String artistName,
    required int progress,
    required int total,
    required int queueCount,
    String status = 'downloading',
  }) {
    if (!_progressTracker.shouldUpdateService(
      trackName: trackName,
      artistName: artistName,
      progress: progress,
      total: total,
      queueCount: queueCount,
      status: status,
      now: DateTime.now(),
    )) {
      return;
    }

    PlatformBridge.updateDownloadServiceProgress(
      trackName: trackName,
      artistName: artistName,
      progress: progress,
      total: total,
      queueCount: queueCount,
      status: status,
    ).catchError((_) {});
  }

  void _stopProgressPolling() {
    _progressPoller.stop();
    _progressTracker.reset();
  }
}
