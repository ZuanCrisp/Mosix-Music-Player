part of 'download_queue_provider.dart';

// Per-track fake Hi-Res check (AppSettings.redownloadFakeHiRes), ported from
// a Python reference checker's --redownload-fake-hires.
//
// Runs inside one _DownloadRun, right after the file is decoded and before
// anything is published, tagged or converted: the verdict decides which file
// the rest of the pipeline works on. A flagged file is set aside, the same
// track is downloaded again at LOSSLESS. The original is only deleted after
// full PCM verification and successful finalization, publication and history.
// If any step fails, including cancellation, the original is restored.

enum _FakeHiResOutcome {
  /// Nothing to do, or the replacement failed: finish with the current file.
  kept,

  /// The verified replacement is already finalized and persisted.
  completed,

  /// The item was cancelled or paused mid-replacement; stop the run.
  aborted,
}

/// Everything a replacement attempt may overwrite, so a failed one can put
/// the run back exactly as it was.
class _FakeHiResRunState {
  _FakeHiResRunState(_DownloadRun run)
    : result = Map<String, dynamic>.from(run.result),
      quality = run.quality,
      safOutputExt = run.safOutputExt,
      safFileName = run.safFileName,
      safBaseName = run.safBaseName,
      finalSafFileName = run.finalSafFileName,
      effectiveSafMode = run.effectiveSafMode,
      effectiveOutputDir = run.effectiveOutputDir,
      trackToDownload = run.trackToDownload,
      appOutputDir = run.appOutputDir,
      filePath = run.filePath,
      wasExisting = run.wasExisting,
      actualQuality = run.actualQuality,
      resultOutputExt = run.resultOutputExt,
      shouldPreserveNativeM4a = run.shouldPreserveNativeM4a,
      probedFinalMetadata = run.probedFinalMetadata,
      externalLrcWritten = run.externalLrcWritten;

  final Map<String, dynamic> result;
  final String quality;
  final String safOutputExt;
  final String? safFileName;
  final String? safBaseName;
  final String? finalSafFileName;
  final bool effectiveSafMode;
  final String effectiveOutputDir;
  final Track trackToDownload;
  final String? appOutputDir;
  final String? filePath;
  final bool wasExisting;
  final String actualQuality;
  final String? resultOutputExt;
  final bool shouldPreserveNativeM4a;
  final Map<String, dynamic>? probedFinalMetadata;
  final bool externalLrcWritten;

  void restore(_DownloadRun run) {
    run.result = DownloadResult.fromMap(result);
    run.quality = quality;
    run.safOutputExt = safOutputExt;
    run.safFileName = safFileName;
    run.safBaseName = safBaseName;
    run.finalSafFileName = finalSafFileName;
    run.effectiveSafMode = effectiveSafMode;
    run.effectiveOutputDir = effectiveOutputDir;
    run.trackToDownload = trackToDownload;
    run.appOutputDir = appOutputDir;
    run.filePath = filePath;
    run.wasExisting = wasExisting;
    run.actualQuality = actualQuality;
    run.resultOutputExt = resultOutputExt;
    run.shouldPreserveNativeM4a = shouldPreserveNativeM4a;
    run.probedFinalMetadata = probedFinalMetadata;
    run.externalLrcWritten = externalLrcWritten;
  }
}

extension _DownloadRunFakeHiRes on _DownloadRun {
  /// [requestTrack] is the track as it was sent to the backend, before the
  /// first result was merged into it: the replacement gets the same brief
  /// the first attempt did, not the first attempt's conclusions.
  Future<_FakeHiResOutcome> _replaceFakeHiResIfNeeded(
    Track requestTrack,
  ) async {
    final path = filePath;
    if (!settings.redownloadFakeHiRes ||
        wasExisting ||
        path == null ||
        !HiResCheckService.isHiResQuality(quality)) {
      return _FakeHiResOutcome.kept;
    }
    if (isContentUri(path)) {
      // Already published to SAF: there is no local file to set aside, and
      // a heuristic is not worth deleting the only copy for.
      _log.d('[hires-check] skipped: output already published to SAF');
      return _FakeHiResOutcome.kept;
    }
    if (!_serviceOffersFakeHiResFallback()) {
      _log.d(
        '[hires-check] skipped: ${item.service} has no '
        '${HiResCheckService.fakeHiResFallbackQuality} quality',
      );
      return _FakeHiResOutcome.kept;
    }

    final HiResCheckResult check;
    try {
      check = await HiResCheckService.check(path);
    } catch (e) {
      // Never a reason to fail a finished download.
      _log.w('[hires-check] skipped for ${item.track.name}: $e');
      return _FakeHiResOutcome.kept;
    }
    if (!check.supported || !check.isFake) {
      _log.d(
        '[hires-check] ${item.track.name}: '
        '${check.supported ? check.verdict : 'unsupported format'}',
      );
      return _FakeHiResOutcome.kept;
    }
    if (!check.redownloadSafe) {
      // Evidence on one axis cannot justify discarding the other axis.
      _log.w(
        '[hires-check] ${item.track.name} may be fake Hi-Res '
        '(${check.reason}); kept, not certain enough to replace',
      );
      return _FakeHiResOutcome.kept;
    }

    _log.w(
      '[hires-check] ${item.track.name} looks like fake Hi-Res '
      '(${check.reason}); re-downloading as '
      '${HiResCheckService.fakeHiResFallbackQuality}',
    );

    final saved = _FakeHiResRunState(this);
    var completed = false;
    var aborted = false;
    try {
      completed = await HiResCheckService.withOriginalBackup(path, (
        backup,
      ) async {
        fakeHiResOriginalPath = backup;
        trackToDownload = requestTrack;
        result = DownloadResult.fromMap({});
        filePath = null;
        probedFinalMetadata = null;
        externalLrcWritten = false;
        var finalized = false;
        try {
          await _useFakeHiResFallbackQuality();
          n.updateItemStatus(item.id, DownloadStatus.downloading, progress: 0);
          if (!await _downloadAndMaybeFallback()) {
            aborted = true;
            return false;
          }
          aborted = await _shouldAbort('during fake Hi-Res re-download');
          if (aborted) return false;
          final replacementPath = result.filePath;
          if (!result.success ||
              result.alreadyExists ||
              normalizeOptionalString(replacementPath) == null ||
              isContentUri(replacementPath!)) {
            return false;
          }
          if (effectiveSafMode && result['saf_relative_dir'] is String) {
            effectiveOutputDir = n._sanitizeSafRelativeDir(
              result['saf_relative_dir'] as String,
            );
          }
          finalized = await _handleDownloadSuccess();
          return finalized;
        } finally {
          if (!finalized && result['already_exists'] != true) {
            for (final failedPath in {
              filePath,
              result['file_path'] as String?,
            }) {
              if (failedPath != null && failedPath != backup) {
                await deleteFile(failedPath);
              }
            }
          }
        }
      });
    } on HiResOriginalRestoreException {
      rethrow;
    } catch (e) {
      _log.w('[hires-check] re-download of ${item.track.name} failed: $e');
    } finally {
      fakeHiResOriginalPath = null;
      if (!completed) saved.restore(this);
    }
    if (completed) return _FakeHiResOutcome.completed;
    if (aborted || await _shouldAbort('after fake Hi-Res rollback')) {
      return _FakeHiResOutcome.aborted;
    }
    if (!await File(path).exists()) {
      throw StateError('Could not restore the original Hi-Res file: $path');
    }
    n.updateItemStatus(item.id, DownloadStatus.downloading, progress: 1);
    return _FakeHiResOutcome.kept;
  }

  /// Only LOSSLESS is a meaningful replacement. A provider that does not
  /// list it would silently fall back to its default, which may be the very
  /// Hi-Res tier that produced the fake.
  bool _serviceOffersFakeHiResFallback() {
    final service = item.service.trim().toLowerCase();
    final extension = extensionState.extensions
        .where((e) => e.id.toLowerCase() == service)
        .firstOrNull;
    final options = extension?.qualityOptions ?? const <QualityOption>[];
    return options.isEmpty ||
        options.any(
          (o) =>
              o.id.toUpperCase() == HiResCheckService.fakeHiResFallbackQuality,
        );
  }

  /// Points the next backend request at LOSSLESS. The output folder stays
  /// as resolved (including any storage fallback); only what depends on the
  /// quality is rebuilt.
  Future<void> _useFakeHiResFallbackQuality() async {
    quality = HiResCheckService.fakeHiResFallbackQuality;
    safOutputExt = n._determineOutputExt(quality, item.service);
    if (effectiveSafMode) {
      final name = await n._buildSafFileNameForItem(
        item,
        trackToDownload,
        filenameFormat: effectiveFilenameFormat,
        quality: quality,
        outputExt: safOutputExt,
      );
      safFileName = name;
      safBaseName = name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      finalSafFileName = name;
    }
  }
}
