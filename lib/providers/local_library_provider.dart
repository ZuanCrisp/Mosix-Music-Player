import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/services/library_cleanup.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/services/network_library_scanner.dart';
import 'package:mosix/services/notification_service.dart';
import 'package:mosix/services/platform_bridge.dart';
import 'package:mosix/utils/logger.dart';
import 'package:mosix/utils/file_access.dart';
import 'package:mosix/utils/local_library_scan_prefs.dart';
import 'package:mosix/utils/progress_stream_poller.dart';

final _log = AppLogger('LocalLibrary');

const _excludedDownloadedCountKey = 'local_library_excluded_downloaded_count';
final _prefs = SharedPreferences.getInstance();

class LocalLibraryState {
  final bool isLoading;
  final bool loadFailed;
  final bool isScanning;
  final bool scanIsFinalizing;
  final bool scanIsPaused;
  final double scanProgress;
  final String? scanCurrentFile;
  final int scanTotalFiles;
  final int scannedFiles;
  final int scanErrorCount;
  final bool scanWasCancelled;
  final int totalCount;
  final int loadedIndexVersion;
  final DateTime? lastScannedAt;
  final List<LocalLibrarySource> sources;
  final String? scanningSourceId;
  final int excludedDownloadedCount;
  final Set<String> _trackKeySet;
  final Set<String> _isrcSet;

  LocalLibraryState({
    this.isLoading = false,
    this.loadFailed = false,
    this.isScanning = false,
    this.scanIsFinalizing = false,
    this.scanIsPaused = false,
    this.scanProgress = 0,
    this.scanCurrentFile,
    this.scanTotalFiles = 0,
    this.scannedFiles = 0,
    this.scanErrorCount = 0,
    this.scanWasCancelled = false,
    this.totalCount = 0,
    this.loadedIndexVersion = 0,
    this.lastScannedAt,
    this.sources = const <LocalLibrarySource>[],
    this.scanningSourceId,
    this.excludedDownloadedCount = 0,
    Set<String>? trackKeySet,
    Set<String>? isrcSet,
  }) : _trackKeySet = trackKeySet ?? const <String>{},
       _isrcSet = isrcSet ?? const <String>{};

  bool hasIsrc(String isrc) => _isrcSet.contains(isrc);

  bool hasTrack(String trackName, String artistName) {
    final key = LibraryDatabase.matchKeyFor(trackName, artistName);
    return _trackKeySet.contains(key);
  }

  bool existsInLibrary({String? isrc, String? trackName, String? artistName}) {
    if (isrc != null && isrc.isNotEmpty && hasIsrc(isrc)) {
      return true;
    }
    if (trackName != null && artistName != null) {
      return hasTrack(trackName, artistName);
    }
    return false;
  }

  LocalLibraryState copyWith({
    bool? isLoading,
    bool? loadFailed,
    bool? isScanning,
    bool? scanIsFinalizing,
    bool? scanIsPaused,
    double? scanProgress,
    String? scanCurrentFile,
    int? scanTotalFiles,
    int? scannedFiles,
    int? scanErrorCount,
    bool? scanWasCancelled,
    int? totalCount,
    int? loadedIndexVersion,
    DateTime? lastScannedAt,
    bool clearLastScannedAt = false,
    List<LocalLibrarySource>? sources,
    String? scanningSourceId,
    bool clearScanningSourceId = false,
    int? excludedDownloadedCount,
    Set<String>? trackKeySet,
    Set<String>? isrcSet,
  }) {
    return LocalLibraryState(
      isLoading: isLoading ?? this.isLoading,
      loadFailed: loadFailed ?? this.loadFailed,
      isScanning: isScanning ?? this.isScanning,
      scanIsFinalizing: scanIsFinalizing ?? this.scanIsFinalizing,
      scanIsPaused: scanIsPaused ?? this.scanIsPaused,
      scanProgress: scanProgress ?? this.scanProgress,
      scanCurrentFile: scanCurrentFile ?? this.scanCurrentFile,
      scanTotalFiles: scanTotalFiles ?? this.scanTotalFiles,
      scannedFiles: scannedFiles ?? this.scannedFiles,
      scanErrorCount: scanErrorCount ?? this.scanErrorCount,
      scanWasCancelled: scanWasCancelled ?? this.scanWasCancelled,
      totalCount: totalCount ?? this.totalCount,
      loadedIndexVersion: loadedIndexVersion ?? this.loadedIndexVersion,
      lastScannedAt: clearLastScannedAt
          ? null
          : lastScannedAt ?? this.lastScannedAt,
      sources: sources ?? this.sources,
      scanningSourceId: clearScanningSourceId
          ? null
          : scanningSourceId ?? this.scanningSourceId,
      excludedDownloadedCount:
          excludedDownloadedCount ?? this.excludedDownloadedCount,
      trackKeySet: trackKeySet ?? _trackKeySet,
      isrcSet: isrcSet ?? _isrcSet,
    );
  }
}

typedef LocalLibraryAvailabilityProbe =
    Future<bool?> Function(String path, {String? bookmark});

class LocalLibraryNotifier extends Notifier<LocalLibraryState> {
  LocalLibraryNotifier({
    LibraryDatabase? database,
    LocalLibraryAvailabilityProbe? availabilityProbe,
  }) : _db = database ?? LibraryDatabase.instance,
       _availabilityProbe = availabilityProbe;

  final LibraryDatabase _db;
  final LocalLibraryAvailabilityProbe? _availabilityProbe;
  final NotificationService _notificationService = NotificationService();
  static const _progressPollingInterval = Duration(milliseconds: 350);
  static const _progressStreamBootstrapTimeout = Duration(milliseconds: 900);
  late final ProgressStreamPoller<Map<String, dynamic>> _progressPoller =
      ProgressStreamPoller<Map<String, dynamic>>(
        streamProvider: PlatformBridge.libraryScanProgressStream,
        pollProvider: PlatformBridge.getLibraryScanProgress,
        onProgress: _handleLibraryScanProgress,
        pollingInterval: _progressPollingInterval,
        bootstrapTimeout: _progressStreamBootstrapTimeout,
        onStreamProcessingError: (e) =>
            _log.w('Library scan progress stream processing failed: $e'),
        onStreamFailed: (error) => _log.w(
          'Library scan progress stream failed, fallback to polling: $error',
        ),
        onStreamTimeout: () =>
            _log.w('Library scan progress stream timeout, fallback to polling'),
        onPollError: (e) => _log.w('Library scan progress polling failed: $e'),
      );
  bool _isLoaded = false;
  bool _hasLoadedFromDatabase = false;
  Future<void>? _loadFuture;
  bool _scanCancelRequested = false;
  bool _scanPauseRequested = false;
  bool _scanInProgress = false;
  Future<void>? _scanCompletion;
  String? _nativeLibraryRequestId;
  final Set<String> _pendingReconnectScans = {};
  bool _drainingReconnectScans = false;
  StreamSubscription<void>? _storageEventsSubscription;
  Timer? _storageEventDebounce;
  Timer? _availabilityRetry;
  int _availabilityRetryCount = 0;
  int _sourceVersion = 0;
  int _availabilityRequestVersion = 0;
  bool _scanReconnectedOnRefresh = false;
  Future<void>? _availabilityRefreshFuture;
  Future<({List<String> reconnected, bool changed, int requestVersion})>?
  _availabilityCheckFuture;
  static const _scanNotificationHeartbeat = Duration(seconds: 4);
  int _lastScanNotificationPercent = -1;
  int _lastScanNotificationTotalFiles = -1;
  DateTime _lastScanNotificationAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  LocalLibraryState build() {
    ref.onDispose(() {
      _scanCancelRequested = true;
      _scanPauseRequested = false;
      _pendingReconnectScans.clear();
      if (_scanInProgress) {
        final requestId = _nativeLibraryRequestId;
        if (requestId != null) {
          unawaited(
            PlatformBridge.cancelNativeDataJob(requestId).catchError((
              Object error,
            ) {
              _log.w('Failed to cancel disposed library ingestion: $error');
            }),
          );
        }
        unawaited(
          PlatformBridge.cancelLibraryScan().catchError((Object error) {
            _log.w('Failed to cancel disposed library scan: $error');
          }),
        );
      }
      _progressPoller.stop();
      _storageEventsSubscription?.cancel();
      _storageEventDebounce?.cancel();
      _availabilityRetry?.cancel();
    });

    if (Platform.isAndroid) {
      _storageEventsSubscription = PlatformBridge.libraryStorageEvents().listen(
        (_) {
          _storageEventDebounce?.cancel();
          _storageEventDebounce = Timer(
            const Duration(milliseconds: 900),
            () => refreshSourceAvailability(scanReconnected: true),
          );
        },
        onError: (Object e) =>
            _log.w('Library storage event stream failed: $e'),
      );
    }

    Future.microtask(_ensureLoadedFromDatabase);
    return LocalLibraryState(isLoading: true);
  }

  Future<void> _ensureLoadedFromDatabase() {
    if (_hasLoadedFromDatabase) {
      return Future<void>.value();
    }
    return _loadFuture ??= _loadFromDatabase();
  }

  Future<void> _loadFromDatabase() async {
    if (_hasLoadedFromDatabase) return;
    if (_isLoaded) {
      return _loadFuture ?? Future<void>.value();
    }
    _isLoaded = true;
    state = state.copyWith(isLoading: true, loadFailed: false);

    try {
      // Folder configuration is independent of the potentially expensive
      // track index and storage probes. Publish it before either can fail.
      final configuredSources = await _db.getSources();
      if (!ref.mounted) return;
      state = state.copyWith(sources: configuredSources);
      await ref.read(settingsProvider.notifier).ensureLoaded();
      await _migrateLegacySource();
      final reconnectedSources = await _refreshSourceAvailabilityInDatabase();
      while (ref.mounted) {
        final sourceVersion = _sourceVersion;
        final sources = await _db.getSources();
        if (!ref.mounted) return;
        if (sourceVersion != _sourceVersion) continue;
        state = state.copyWith(sources: sources);
        final summary = await Future.wait<Object>([
          _db.getCount(),
          _db.getLookupIndex(),
        ]);
        final prefsFuture = _prefs;
        final count = summary[0] as int;
        final lookupIndex = summary[1] as LocalLibraryLookupIndex;

        DateTime? lastScannedAt;
        var excludedDownloadedCount = 0;
        try {
          final prefs = await prefsFuture;
          lastScannedAt = readLocalLibraryLastScannedAt(prefs);
          excludedDownloadedCount =
              prefs.getInt(_excludedDownloadedCountKey) ?? 0;
        } catch (e) {
          _log.w('Failed to load lastScannedAt: $e');
        }

        if (!ref.mounted) return;
        if (sourceVersion != _sourceVersion) {
          if (_hasLoadedFromDatabase) break;
          continue;
        }
        state = state.copyWith(
          totalCount: count,
          loadedIndexVersion: state.loadedIndexVersion + 1,
          lastScannedAt: lastScannedAt,
          excludedDownloadedCount: excludedDownloadedCount,
          sources: sources,
          trackKeySet: lookupIndex.matchKeys,
          isrcSet: lookupIndex.isrcs,
        );
        _log.i(
          'Loaded local library summary: $count items, lastScannedAt: '
          '$lastScannedAt, excludedDownloadedCount: $excludedDownloadedCount',
        );
        _hasLoadedFromDatabase = true;
        break;
      }
      if (ref.mounted && reconnectedSources.reconnected.isNotEmpty) {
        unawaited(
          Future<void>.microtask(
            () => _scanSourcesSequentially(reconnectedSources.reconnected),
          ),
        );
      }
    } catch (e, stack) {
      _isLoaded = false;
      if (ref.mounted) state = state.copyWith(loadFailed: true);
      _log.e('Failed to load library from database: $e', e, stack);
    } finally {
      _loadFuture = null;
      if (ref.mounted) state = state.copyWith(isLoading: false);
    }
  }

  Future<void> reloadFromStorage() async {
    final loading = _loadFuture;
    if (loading != null) {
      await loading;
      return;
    }
    _isLoaded = false;
    _hasLoadedFromDatabase = false;
    _sourceVersion++;
    _loadFuture = null;
    await _ensureLoadedFromDatabase();
  }

  Future<LocalLibrarySource> addSource({
    required String path,
    required String displayName,
    String? bookmark,
    String? volumeId,
    bool isRemovable = false,
  }) async {
    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) {
      throw const FormatException('Library folder path is empty');
    }
    final existing = await _db.getSourceByPath(trimmedPath);
    if (existing != null) {
      _sourceVersion++;
      await _db.updateSourceState(
        existing.id,
        enabled: true,
        available: true,
        lastSeenAt: DateTime.now(),
      );
      await _refreshSummaryFromStorage();
      return existing.copyWith(
        enabled: true,
        available: true,
        lastSeenAt: DateTime.now(),
      );
    }

    final source = LocalLibrarySource(
      id: _newSourceId(trimmedPath),
      path: trimmedPath,
      displayName: displayName.trim().isEmpty
          ? _displayNameForPath(trimmedPath)
          : displayName.trim(),
      bookmark: bookmark?.trim().isEmpty == true ? null : bookmark,
      volumeId: volumeId?.trim().isEmpty == true ? null : volumeId,
      isRemovable: isRemovable || _looksLikeRemovablePath(trimmedPath),
      enabled: true,
      available: true,
      lastSeenAt: DateTime.now(),
    );
    _sourceVersion++;
    await _db.upsertSource(source);
    await _refreshSummaryFromStorage();
    return source;
  }

  String _newSourceId(String path) {
    const offset = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    const mask = 0xffffffffffffffff;
    var hash = offset;
    for (final unit in path.codeUnits) {
      hash = ((hash ^ unit) * prime) & mask;
    }
    return 'source_${hash.toRadixString(16).padLeft(16, '0')}';
  }

  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final source = state.sources
        .where((entry) => entry.id == sourceId)
        .firstOrNull;
    _sourceVersion++;
    await _db.updateSourceState(sourceId, enabled: enabled);
    await _refreshSummaryFromStorage();
    if (enabled &&
        source?.available == true &&
        source?.isIndexed == true &&
        !_scanInProgress) {
      unawaited(startSourceScan(sourceId));
    }
  }

  Future<void> removeSource(String sourceId) async {
    _sourceVersion++;
    await _db.removeSource(sourceId);
    await _refreshSummaryFromStorage();
  }

  Future<void> refreshSourceAvailability({bool scanReconnected = false}) {
    _availabilityRequestVersion++;
    _scanReconnectedOnRefresh |= scanReconnected;
    return _availabilityRefreshFuture ??= _refreshSourceAvailability()
        .whenComplete(() {
          _availabilityRefreshFuture = null;
          _scanReconnectedOnRefresh = false;
        });
  }

  Future<void> _refreshSourceAvailability() async {
    await _ensureLoadedFromDatabase();
    final reconnected = <String>{};
    while (ref.mounted) {
      final result = await _refreshSourceAvailabilityInDatabase();
      if (!ref.mounted) return;
      reconnected.addAll(result.reconnected);
      if (result.changed) await _refreshSummaryFromStorage();
      if (result.requestVersion == _availabilityRequestVersion) break;
    }

    // Existing rows become visible as soon as availability flips. The
    // incremental pass then verifies changes made while storage was detached
    // without re-reading metadata for unchanged files.
    if (ref.mounted && _scanReconnectedOnRefresh && reconnected.isNotEmpty) {
      _pendingReconnectScans.addAll(reconnected);
      unawaited(_drainReconnectScans());
    }
  }

  Future<void> _scanSourcesSequentially(
    Iterable<String> sourceIds, {
    bool forceFullScan = false,
  }) async {
    for (final sourceId in sourceIds) {
      if (!ref.mounted) break;
      await startSourceScan(sourceId, forceFullScan: forceFullScan);
      if (_scanCancelRequested) break;
    }
  }

  Future<void> scanAllSources({bool forceFullScan = false}) async {
    await _ensureLoadedFromDatabase();
    final sourceIds = state.sources
        .where((source) => source.enabled && source.available)
        .map((source) => source.id)
        .toList(growable: false);
    await _scanSourcesSequentially(sourceIds, forceFullScan: forceFullScan);
  }

  Future<void> startSourceScan(
    String sourceId, {
    bool forceFullScan = false,
  }) async {
    final reconnect = _pendingReconnectScans.contains(sourceId);
    while (ref.mounted) {
      final source = await _sourceForScan(sourceId);
      if (source == null ||
          (reconnect && !_pendingReconnectScans.contains(sourceId))) {
        return;
      }
      if (_scanInProgress) {
        if (!reconnect) return;
        final active = _scanCompletion;
        if (active != null) await active;
        continue;
      }
      await startScan(
        source.path,
        forceFullScan: forceFullScan,
        iosBookmark: source.bookmark,
        sourceId: source.id,
      );
      return;
    }
  }

  Future<LocalLibrarySource?> _sourceForScan(String sourceId) async {
    if (!ref.mounted) return null;
    await _ensureLoadedFromDatabase();
    if (!ref.mounted) return null;
    while (ref.mounted) {
      final sourceVersion = _sourceVersion;
      final source = (await _db.getSources())
          .where((entry) => entry.id == sourceId)
          .firstOrNull;
      if (!ref.mounted) return null;
      if (sourceVersion != _sourceVersion) continue;
      return source?.enabled == true && source?.available == true
          ? source
          : null;
    }
    return null;
  }

  Future<void> _drainReconnectScans() async {
    if (_drainingReconnectScans || !ref.mounted) return;
    _drainingReconnectScans = true;
    try {
      while (ref.mounted && _pendingReconnectScans.isNotEmpty) {
        final active = _scanCompletion;
        if (active != null) await active;
        if (!ref.mounted || _pendingReconnectScans.isEmpty) break;
        final sourceId = _pendingReconnectScans.first;
        await startSourceScan(sourceId);
        _pendingReconnectScans.remove(sourceId);
      }
    } catch (error, stack) {
      _log.e('Failed to scan reconnected library source: $error', error, stack);
    } finally {
      _drainingReconnectScans = false;
    }
  }

  Future<void> _refreshSummaryFromStorage({
    DateTime? lastScannedAt,
    int? excludedDownloadedCount,
  }) async {
    final sourceVersion = ++_sourceVersion;
    final sources = await _db.getSources();
    if (!ref.mounted || sourceVersion != _sourceVersion) return;
    state = state.copyWith(sources: sources);
    final summary = await Future.wait<Object>([
      _db.getCount(),
      _db.getLookupIndex(),
    ]);
    final count = summary[0] as int;
    final index = summary[1] as LocalLibraryLookupIndex;
    if (!ref.mounted || sourceVersion != _sourceVersion) return;
    final latestSourceScan = sources
        .map((source) => source.lastScannedAt)
        .whereType<DateTime>()
        .fold<DateTime?>(
          null,
          (latest, value) =>
              latest == null || value.isAfter(latest) ? value : latest,
        );
    state = state.copyWith(
      loadFailed: false,
      totalCount: count,
      loadedIndexVersion: state.loadedIndexVersion + 1,
      lastScannedAt: lastScannedAt ?? latestSourceScan,
      excludedDownloadedCount: excludedDownloadedCount,
      sources: sources,
      trackKeySet: index.matchKeys,
      isrcSet: index.isrcs,
    );
    _hasLoadedFromDatabase = true;
    _isLoaded = true;
  }

  Future<void> _migrateLegacySource() async {
    final settings = ref.read(settingsProvider);
    final path = settings.localLibraryPath.trim();
    if (path.isEmpty) return;
    if (await _db.getSourceByPath(path) != null) return;
    DateTime? legacyLastScannedAt;
    try {
      legacyLastScannedAt = readLocalLibraryLastScannedAt(await _prefs);
    } catch (_) {}
    _sourceVersion++;
    await _db.migrateLegacySource(
      path: path,
      displayName: _displayNameForPath(path),
      bookmark: settings.localLibraryBookmark.trim().isEmpty
          ? null
          : settings.localLibraryBookmark,
      isRemovable: _looksLikeRemovablePath(path),
      available: await _isPathAvailable(
        path,
        bookmark: settings.localLibraryBookmark,
      ),
      lastScannedAt: legacyLastScannedAt,
    );
  }

  String _displayNameForPath(String path) {
    if (path.startsWith('content://')) {
      try {
        final decoded = Uri.decodeComponent(Uri.parse(path).pathSegments.last);
        final relative = decoded.contains(':')
            ? decoded.substring(decoded.indexOf(':') + 1)
            : decoded;
        if (relative.trim().isNotEmpty) {
          return relative.split('/').last;
        }
      } catch (_) {}
      return 'Music';
    }
    final normalized = path
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    final name = normalized.split('/').last;
    return name.isEmpty ? path : name;
  }

  bool _looksLikeRemovablePath(String path) {
    if (path.startsWith('content://')) {
      try {
        final decoded = Uri.decodeComponent(Uri.parse(path).pathSegments.last);
        return !decoded.startsWith('primary:');
      } catch (_) {
        return false;
      }
    }
    final normalized = path.replaceAll('\\', '/').toLowerCase();
    return normalized.startsWith('/storage/') &&
        !normalized.startsWith('/storage/emulated/');
  }

  Future<bool> _isPathAvailable(String path, {String? bookmark}) async {
    return await _probePathAvailability(path, bookmark: bookmark) ?? true;
  }

  Future<bool?> _probePathAvailability(String path, {String? bookmark}) async {
    // Network outages are transient. Keep the indexed collection visible;
    // opening/scanning a source reports connectivity errors without dropping it.
    if (path.startsWith('network://')) return true;
    try {
      if (_availabilityProbe != null) {
        return await _availabilityProbe(path, bookmark: bookmark);
      }
      if (Platform.isAndroid && path.startsWith('content://')) {
        return await PlatformBridge.probeSafTreeReadAccess(path);
      }
      if (Platform.isIOS && bookmark != null && bookmark.trim().isNotEmpty) {
        final access = await PlatformBridge.startAccessingIosBookmark(bookmark);
        if (access == null) return false;
        try {
          return await Directory(access.path).exists();
        } finally {
          await PlatformBridge.stopAccessingIosBookmark(access);
        }
      }
      return await Directory(path).exists();
    } catch (error) {
      // A busy provider or a filesystem exception cannot prove detachment.
      _log.w('Library source access probe failed: $error');
      return null;
    }
  }

  Future<({List<String> reconnected, bool changed, int requestVersion})>
  _refreshSourceAvailabilityInDatabase() =>
      _availabilityCheckFuture ??= _checkSourceAvailability().whenComplete(() {
        _availabilityCheckFuture = null;
      });

  Future<({List<String> reconnected, bool changed, int requestVersion})>
  _checkSourceAvailability() async {
    final reconnected = <String>{};
    var changed = false;
    while (ref.mounted) {
      final sourceVersion = _sourceVersion;
      final requestVersion = _availabilityRequestVersion;
      final sources = await _db.getSources();
      var inconclusive = false;
      for (final source in sources) {
        final available = await _probePathAvailability(
          source.path,
          bookmark: source.bookmark,
        );
        if (!ref.mounted ||
            sourceVersion != _sourceVersion ||
            requestVersion != _availabilityRequestVersion) {
          break;
        }
        if (available == null) {
          inconclusive = true;
          _log.w(
            'Library source access inconclusive; retaining status: ${source.id}',
          );
          continue;
        }
        if (available != source.available) {
          await _db.updateSourceState(
            source.id,
            available: available,
            lastSeenAt: available ? DateTime.now() : null,
          );
          changed = true;
          if (available && source.enabled && source.isIndexed) {
            reconnected.add(source.id);
          }
        }
      }
      if (!ref.mounted) break;
      // A folder edit or a newer storage event supersedes pending probe
      // results. Re-read the source snapshot before applying them.
      if (sourceVersion != _sourceVersion ||
          requestVersion != _availabilityRequestVersion) {
        continue;
      }
      _availabilityRetry?.cancel();
      if (inconclusive && _availabilityRetryCount < 3) {
        _availabilityRetryCount++;
        _availabilityRetry = Timer(const Duration(seconds: 2), () {
          unawaited(refreshSourceAvailability(scanReconnected: true));
        });
      } else if (!inconclusive) {
        _availabilityRetryCount = 0;
      }
      return (
        reconnected: reconnected.toList(growable: false),
        changed: changed,
        requestVersion: requestVersion,
      );
    }
    return (
      reconnected: reconnected.toList(growable: false),
      changed: changed,
      requestVersion: _availabilityRequestVersion,
    );
  }

  Future<({int inserted, int skipped})?> _replaceFromFullScanStream({
    required String sourceId,
    required String folderPath,
    required bool isSaf,
    required bool forceFullScan,
  }) async {
    if (_scanCancelRequested) return null;
    final scanFile = folderPath.startsWith('network://')
        ? await NetworkLibraryScanner().scan(
            folderPath,
            checkpoint: () async {
              while (_scanPauseRequested &&
                  !_scanCancelRequested &&
                  ref.mounted) {
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }
              if (_scanCancelRequested || !ref.mounted) {
                throw StateError('Network library scan cancelled');
              }
            },
            onProgress: (processed, errors, name) {
              if (!ref.mounted) return;
              state = state.copyWith(
                scannedFiles: processed,
                scanErrorCount: errors,
                scanCurrentFile: name,
              );
              if (_shouldShowScanProgressNotification(
                progress: 0,
                totalFiles: 0,
                isComplete: false,
              )) {
                unawaited(
                  _showScanProgressNotification(
                    progress: 0,
                    scannedFiles: processed,
                    totalFiles: 0,
                    currentFile: name,
                  ),
                );
              }
            },
          )
        : isSaf
        ? await PlatformBridge.scanSafTreeToNDJSONFile(
            folderPath,
            forceFullScan: forceFullScan,
            isCancelled: () => _scanCancelRequested,
          )
        : await PlatformBridge.scanLibraryFolderToNDJSONFile(
            folderPath,
            forceFullScan: forceFullScan,
            isCancelled: () => _scanCancelRequested,
          );
    var ingested = false;
    try {
      if (_scanCancelRequested) return null;
      await _endPauseForFinalization();
      state = state.copyWith(
        scanIsFinalizing: true,
        scanProgress: state.scanProgress >= 99 ? state.scanProgress : 99,
        scanCurrentFile: null,
        scannedFiles: scanFile.expectedCount,
        scanErrorCount: scanFile.errorCount,
      );
      final result = await _db.replaceSourceScanFile(
        sourceId,
        scanFile,
        requestId: _nativeLibraryRequestId ?? 'desktop-library-scan',
        isCancelled: () => _scanCancelRequested || !ref.mounted,
      );
      _log.i(
        'Stream-ingested ${result.inserted}/${scanFile.expectedCount} scan rows '
        '(${result.skipped} downloads excluded)',
      );
      ingested = true;
      return result;
    } finally {
      if (ingested || folderPath.startsWith('network://')) {
        await scanFile.delete();
      }
    }
  }

  Future<void> startScan(
    String folderPath, {
    bool forceFullScan = false,
    String? iosBookmark,
    String? sourceId,
  }) async {
    if (!ref.mounted) return;
    if (_scanInProgress || state.isScanning) {
      _log.w('Scan already in progress');
      return;
    }

    final completion = Completer<void>();
    _scanCompletion = completion.future;
    _scanInProgress = true;
    if (sourceId != null) _pendingReconnectScans.remove(sourceId);
    _scanCancelRequested = false;
    _scanPauseRequested = false;
    _nativeLibraryRequestId = PlatformBridge.supportsCoreBackend
        ? 'library-scan-${DateTime.now().microsecondsSinceEpoch}'
        : null;
    try {
      await _runScan(
        folderPath,
        forceFullScan: forceFullScan,
        iosBookmark: iosBookmark,
        sourceId: sourceId,
      );
    } finally {
      if (ref.mounted) {
        state = state.copyWith(
          isScanning: false,
          scanIsFinalizing: false,
          clearScanningSourceId: true,
          scanIsPaused: false,
        );
      }
      _scanInProgress = false;
      _scanCompletion = null;
      _nativeLibraryRequestId = null;
      completion.complete();
    }
  }

  Future<void> _runScan(
    String folderPath, {
    required bool forceFullScan,
    required String? iosBookmark,
    required String? sourceId,
  }) async {
    var activeSourceId = sourceId;
    IosSecurityScopedAccess? securityAccess;
    try {
      if (activeSourceId == null) {
        final existingSource = await _db.getSourceByPath(folderPath);
        if (!ref.mounted || _scanCancelRequested) return;
        activeSourceId = existingSource?.id;
        if (activeSourceId == null) {
          final source = await addSource(
            path: folderPath,
            displayName: _displayNameForPath(folderPath),
            bookmark: iosBookmark,
            isRemovable: _looksLikeRemovablePath(folderPath),
          );
          activeSourceId = source.id;
        }
      }

      final available = await _isPathAvailable(
        folderPath,
        bookmark: iosBookmark,
      );
      if (!ref.mounted || _scanCancelRequested) return;
      if (!available) {
        _sourceVersion++;
        await _db.updateSourceState(activeSourceId, available: false);
        await _refreshSummaryFromStorage();
        return;
      }
      if (await _sourceForScan(activeSourceId) == null ||
          !ref.mounted ||
          _scanCancelRequested) {
        return;
      }

      // A pause left behind by an interrupted Dart session would hold the new
      // native scan forever; clear it before the pause control becomes visible.
      await _releaseNativeScanPause();
      try {
        final prefs = await _prefs;
        await prefs.setString(localLibraryActiveScanSourceKey, activeSourceId);
      } catch (e) {
        _log.w('Failed to persist active library scan marker: $e');
      }
      if (!ref.mounted || _scanCancelRequested) return;
      _log.i(
        'Starting library scan: $folderPath (incremental: ${!forceFullScan})',
      );
      state = state.copyWith(
        isScanning: true,
        scanIsFinalizing: false,
        scanIsPaused: false,
        scanProgress: 0,
        scanCurrentFile: null,
        scanTotalFiles: 0,
        scannedFiles: 0,
        scanErrorCount: 0,
        scanWasCancelled: false,
        scanningSourceId: activeSourceId,
      );
      _resetScanNotificationTracking();
      // Hold before the first progress notification so Android shows a single
      // foreground-service notification; released in the final cleanup below.
      await _notificationService.beginLibraryScanWork();
      if (_shouldShowScanProgressNotification(
        progress: 0,
        totalFiles: 0,
        isComplete: false,
      )) {
        await _showScanProgressNotification(
          progress: 0,
          scannedFiles: 0,
          totalFiles: 0,
          currentFile: null,
        );
      }

      try {
        final appSupportDir = await getApplicationSupportDirectory();
        final coverCacheDir = '${appSupportDir.path}/library_covers';
        await PlatformBridge.setLibraryCoverCacheDir(coverCacheDir);
        _log.i('Cover cache directory set to: $coverCacheDir');
      } catch (e) {
        _log.w('Failed to set cover cache directory: $e');
      }
      if (!ref.mounted || _scanCancelRequested) return;

      if (!folderPath.startsWith('network://')) _startProgressPolling();

      String? resolvedPath;
      if (Platform.isIOS && iosBookmark != null && iosBookmark.isNotEmpty) {
        securityAccess = await PlatformBridge.startAccessingIosBookmark(
          iosBookmark,
        );
        resolvedPath = securityAccess?.path;
        if (securityAccess != null) {
          _log.i('Started iOS security-scoped access: $resolvedPath');
        } else {
          _log.w(
            'Failed to start iOS security-scoped access, '
            'falling back to original path',
          );
        }
      }
      if (!ref.mounted || _scanCancelRequested) return;
      final effectiveFolderPath = resolvedPath ?? folderPath;

      final isSaf = effectiveFolderPath.startsWith('content://');

      final useStreamingFullScan =
          effectiveFolderPath.startsWith('network://') ||
          forceFullScan ||
          await _db.getSourceCount(activeSourceId) == 0;
      if (useStreamingFullScan) {
        if (await _sourceForScan(activeSourceId) == null ||
            !ref.mounted ||
            _scanCancelRequested) {
          return;
        }
        final scanResult = await _replaceFromFullScanStream(
          sourceId: activeSourceId,
          folderPath: effectiveFolderPath,
          isSaf: isSaf,
          forceFullScan: forceFullScan,
        );
        if (!ref.mounted) return;
        if (scanResult == null || _scanCancelRequested) {
          if (scanResult != null) {
            await _refreshSummaryFromStorage(
              excludedDownloadedCount: scanResult.skipped,
            );
          }
          if (!ref.mounted) return;
          state = state.copyWith(
            isScanning: false,
            scanIsFinalizing: false,
            scanWasCancelled: true,
          );
          await _showScanCancelledNotification();
          return;
        }

        state = state.copyWith(
          scanIsFinalizing: true,
          scanProgress: state.scanProgress >= 99 ? state.scanProgress : 99,
          scanCurrentFile: null,
        );

        final skippedDownloads = scanResult.skipped;

        if (skippedDownloads > 0) {
          _log.i('Skipped $skippedDownloads files already in download history');
        }

        final now = DateTime.now();
        _sourceVersion++;
        await _db.updateSourceState(
          activeSourceId,
          available: true,
          lastSeenAt: now,
          lastScannedAt: now,
          clearLastScanError: true,
        );
        try {
          final prefs = await SharedPreferences.getInstance();
          await writeLocalLibraryLastScannedAt(prefs, now);
          await prefs.setInt(_excludedDownloadedCountKey, skippedDownloads);
          _log.d('Saved lastScannedAt: $now');
        } catch (e) {
          _log.w('Failed to save lastScannedAt: $e');
        }

        await _refreshSummaryFromStorage(
          lastScannedAt: now,
          excludedDownloadedCount: skippedDownloads,
        );
        if (!ref.mounted) return;
        state = state.copyWith(
          isScanning: false,
          scanIsFinalizing: false,
          scanProgress: 100,
          lastScannedAt: now,
          scanWasCancelled: false,
          excludedDownloadedCount: skippedDownloads,
        );
        await _pruneLibraryCoverCache();

        final summary =
            'Full scan complete: ${state.totalCount} tracks found, '
            '$skippedDownloads already in downloads, '
            '${state.scanErrorCount} errors';
        if (state.scanErrorCount > 0) {
          _log.e(summary);
        } else {
          _log.i(summary);
        }
        await _showScanCompleteNotification(
          totalTracks: state.totalCount,
          excludedDownloadedCount: skippedDownloads,
          errorCount: state.scanErrorCount,
        );
      } else {
        final nativeIngestion = PlatformBridge.supportsCoreBackend;
        final existingFiles = nativeIngestion
            ? const <String, int>{}
            : await _db.getFileModTimes(sourceId: activeSourceId);
        if (!nativeIngestion) {
          _log.i(
            'Incremental scan: ${existingFiles.length} existing files in database',
          );
          final backfilledModTimes = await _backfillLegacyFileModTimes(
            isSaf: isSaf,
            existingFiles: existingFiles,
          );
          if (backfilledModTimes.isNotEmpty) {
            await _db.updateFileModTimes(backfilledModTimes);
            existingFiles.addAll(backfilledModTimes);
            _log.i('Backfilled ${backfilledModTimes.length} legacy mod times');
          }
        }

        final useSnapshotBridge =
            Platform.isAndroid && existingFiles.isNotEmpty;
        final snapshotPath = nativeIngestion
            ? await _db.writeNativeFileModTimesSnapshot(
                activeSourceId,
                requestId: _nativeLibraryRequestId!,
                isCancelled: () => _scanCancelRequested || !ref.mounted,
              )
            : useSnapshotBridge
            ? await _db.writeFileModTimesSnapshot(existingFiles)
            : null;

        Map<String, dynamic> result;
        try {
          if (await _sourceForScan(activeSourceId) == null ||
              _scanCancelRequested ||
              !ref.mounted) {
            return;
          }
          if (nativeIngestion) {
            result = await _db.scanIncrementalNative(
              activeSourceId,
              effectiveFolderPath,
              snapshotPath!,
              isSaf: isSaf,
              requestId: _nativeLibraryRequestId!,
              isCancelled: () => _scanCancelRequested || !ref.mounted,
            );
          } else if (isSaf) {
            result = useSnapshotBridge && snapshotPath != null
                ? await PlatformBridge.scanSafTreeIncrementalFromSnapshot(
                    effectiveFolderPath,
                    snapshotPath,
                  )
                : await PlatformBridge.scanSafTreeIncremental(
                    effectiveFolderPath,
                    existingFiles,
                  );
          } else {
            result = useSnapshotBridge && snapshotPath != null
                ? await PlatformBridge.scanLibraryFolderIncrementalFromSnapshot(
                    effectiveFolderPath,
                    snapshotPath,
                  )
                : await PlatformBridge.scanLibraryFolderIncremental(
                    effectiveFolderPath,
                    existingFiles,
                  );
          }
        } finally {
          if (snapshotPath != null) {
            try {
              await File(snapshotPath).delete();
            } catch (_) {}
          }
        }

        if (!ref.mounted) return;
        if (_scanCancelRequested || result['cancelled'] == true) {
          if (result['committed'] == true) {
            await _refreshSummaryFromStorage(
              excludedDownloadedCount: (result['skipped'] as num?)?.toInt(),
            );
          }
          if (!ref.mounted) return;
          state = state.copyWith(
            isScanning: false,
            scanIsFinalizing: false,
            scanWasCancelled: true,
          );
          await _showScanCancelledNotification();
          return;
        }

        await _endPauseForFinalization();
        state = state.copyWith(
          scanIsFinalizing: true,
          scanProgress: state.scanProgress >= 99 ? state.scanProgress : 99,
          scanCurrentFile: null,
        );

        final scannedList =
            (result['files'] as List<dynamic>?) ??
            (result['scanned'] as List<dynamic>?) ??
            [];
        final deletedPaths =
            (result['removedUris'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            (result['deletedPaths'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [];
        final skippedCount = result['skippedCount'] as int? ?? 0;
        final totalFiles = result['totalFiles'] as int? ?? 0;
        final scannedCount = nativeIngestion
            ? (result['scanned_count'] as num).toInt()
            : scannedList.length;
        final deletedCount = nativeIngestion
            ? (result['deleted_count'] as num).toInt()
            : deletedPaths.length;
        if (nativeIngestion && result['committed'] != true) {
          throw StateError('Native Library scan did not commit its index');
        }

        _log.i(
          'Incremental result: $scannedCount scanned, '
          '$skippedCount skipped, $deletedCount deleted, $totalFiles total',
        );

        final removedDownloaded = nativeIngestion
            ? 0
            : await _db.deleteDownloadedRowsForSource(activeSourceId);
        if (removedDownloaded > 0) {
          _log.i(
            'Removed $removedDownloaded downloaded tracks already present in '
            'the local Library index',
          );
        }

        final updatedItems = <LocalLibraryItem>[];
        var skippedDownloads = nativeIngestion
            ? (result['skipped'] as num).toInt()
            : removedDownloaded;
        if (!nativeIngestion && scannedList.isNotEmpty) {
          for (final json in scannedList) {
            final map = json as Map<String, dynamic>;
            final item = LocalLibraryItem.fromJson(map);
            updatedItems.add(item);
          }
          if (updatedItems.isNotEmpty) {
            final upsertResult = await _db.upsertBatchExcludingHistory(
              updatedItems.map((e) => e.toJson()).toList(),
              sourceId: activeSourceId,
            );
            skippedDownloads += upsertResult.skipped;
            _log.i('Upserted ${upsertResult.upserted} items');
          }
          if (skippedDownloads > 0) {
            _log.i(
              'Skipped $skippedDownloads files already in download history',
            );
          }
        }

        if (!nativeIngestion && deletedPaths.isNotEmpty) {
          final deleteCount = await _db.deleteByPaths(deletedPaths);
          _log.i('Deleted $deleteCount items from database');
        }

        final now = DateTime.now();
        _sourceVersion++;
        await _db.updateSourceState(
          activeSourceId,
          available: true,
          lastSeenAt: now,
          lastScannedAt: now,
          clearLastScanError: true,
        );
        try {
          final prefs = await SharedPreferences.getInstance();
          await writeLocalLibraryLastScannedAt(prefs, now);
          await prefs.setInt(_excludedDownloadedCountKey, skippedDownloads);
          _log.d('Saved lastScannedAt: $now');
        } catch (e) {
          _log.w('Failed to save lastScannedAt: $e');
        }

        await _refreshSummaryFromStorage(
          lastScannedAt: now,
          excludedDownloadedCount: skippedDownloads,
        );
        if (!ref.mounted) return;
        state = state.copyWith(
          isScanning: false,
          scanIsFinalizing: false,
          scanProgress: 100,
          lastScannedAt: now,
          scanWasCancelled: false,
          excludedDownloadedCount: skippedDownloads,
        );

        final summary =
            'Incremental scan complete: ${state.totalCount} total tracks '
            '($scannedCount new/updated, $skippedCount unchanged, '
            '$deletedCount removed, $skippedDownloads already in downloads, '
            '${state.scanErrorCount} errors)';
        if (state.scanErrorCount > 0) {
          _log.e(summary);
        } else {
          _log.i(summary);
        }
        await _showScanCompleteNotification(
          totalTracks: state.totalCount,
          excludedDownloadedCount: skippedDownloads,
          errorCount: state.scanErrorCount,
        );
      }
    } catch (e, stack) {
      if (!ref.mounted) return;
      if (_scanCancelRequested) {
        _log.i('Library scan cancelled');
        state = state.copyWith(
          isScanning: false,
          scanIsFinalizing: false,
          scanWasCancelled: true,
        );
        await _showScanCancelledNotification();
        return;
      }
      _log.e('Library scan failed: $e', e, stack);
      if (activeSourceId != null) {
        await _db.updateSourceState(
          activeSourceId,
          lastScanError: e.toString(),
        );
        await _refreshSummaryFromStorage();
      }
      if (!ref.mounted) return;
      state = state.copyWith(
        isScanning: false,
        scanIsFinalizing: false,
        scanWasCancelled: false,
      );
      await _showScanFailedNotification(e.toString());
    } finally {
      await _notificationService.endBackgroundWork(
        NotificationService.libraryScanWorkKind,
      );
      if (securityAccess != null) {
        await PlatformBridge.stopAccessingIosBookmark(securityAccess);
        _log.i('Stopped iOS security-scoped access');
      }
      _stopProgressPolling();
      if (_scanPauseRequested) {
        _scanPauseRequested = false;
        await _releaseNativeScanPause();
      }
      try {
        final prefs = await _prefs;
        if (prefs.getString(localLibraryActiveScanSourceKey) ==
            activeSourceId) {
          await prefs.remove(localLibraryActiveScanSourceKey);
        }
      } catch (e) {
        _log.w('Failed to clear active library scan marker: $e');
      }
    }
  }

  void _startProgressPolling() {
    final useStream = Platform.isAndroid || Platform.isIOS;
    _progressPoller.start(useStream: useStream);
    if (useStream) {
      Future<void>.microtask(
        () => _progressPoller.pollOnce(
          (e) => _log.w('Initial library scan progress fetch failed: $e'),
        ),
      );
    }
  }

  Future<void> _handleLibraryScanProgress(Map<String, dynamic> progress) async {
    // A newly subscribed native stream may still contain the previous scan's
    // terminal snapshot (including the initial idle snapshot). Only the scan
    // method's result can start finalization; never stop polling on that replay.
    if (_scanCancelRequested ||
        !state.isScanning ||
        state.scanIsFinalizing ||
        progress['is_complete'] == true) {
      return;
    }
    final nextProgress = (progress['progress_pct'] as num?)?.toDouble() ?? 0;
    final normalizedProgress = ((nextProgress * 10).round() / 10).clamp(
      0.0,
      100.0,
    );
    final displayProgress = normalizedProgress >= 100.0
        ? 99.0
        : normalizedProgress;
    final currentFile = progress['current_file'] as String?;
    final totalFiles = (progress['total_files'] as num?)?.toInt() ?? 0;
    final scannedFiles = (progress['scanned_files'] as num?)?.toInt() ?? 0;
    final errorCount = (progress['error_count'] as num?)?.toInt() ?? 0;

    final shouldUpdateState =
        state.scanProgress != displayProgress ||
        state.scanCurrentFile != currentFile ||
        state.scanTotalFiles != totalFiles ||
        state.scannedFiles != scannedFiles ||
        state.scanErrorCount != errorCount;

    if (shouldUpdateState) {
      state = state.copyWith(
        scanProgress: displayProgress,
        scanCurrentFile: currentFile,
        scanTotalFiles: totalFiles,
        scannedFiles: scannedFiles,
        scanErrorCount: errorCount,
      );
    }

    // Files already in flight still finish after a pause; count them, but
    // keep the paused notice instead of reposting progress.
    if (!state.scanIsPaused &&
        _shouldShowScanProgressNotification(
          progress: normalizedProgress,
          totalFiles: totalFiles,
          isComplete: false,
        )) {
      await _showScanProgressNotification(
        progress: normalizedProgress,
        scannedFiles: scannedFiles,
        totalFiles: totalFiles,
        currentFile: currentFile,
      );
    }
  }

  void _stopProgressPolling() {
    _progressPoller.stop();
    _resetScanNotificationTracking();
  }

  void _resetScanNotificationTracking() {
    _lastScanNotificationPercent = -1;
    _lastScanNotificationTotalFiles = -1;
    _lastScanNotificationAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  bool _shouldShowScanProgressNotification({
    required double progress,
    required int totalFiles,
    required bool isComplete,
  }) {
    final now = DateTime.now();
    final percent = progress.round().clamp(0, 100);
    final percentChanged = percent != _lastScanNotificationPercent;
    final totalFilesChanged = totalFiles != _lastScanNotificationTotalFiles;
    final heartbeatDue =
        now.difference(_lastScanNotificationAt) >= _scanNotificationHeartbeat;

    if (!percentChanged && !totalFilesChanged && !isComplete && !heartbeatDue) {
      return false;
    }

    _lastScanNotificationPercent = percent;
    _lastScanNotificationTotalFiles = totalFiles;
    _lastScanNotificationAt = now;
    return true;
  }

  bool get _isScanningNetwork => state.sources.any(
    (source) =>
        source.id == state.scanningSourceId &&
        source.path.startsWith('network://'),
  );

  Future<void> cancelScan() async {
    if (!ref.mounted || (!_scanInProgress && !state.isScanning)) return;

    _log.i('Cancelling library scan');
    _scanCancelRequested = true;
    final requestId = _nativeLibraryRequestId;
    if (requestId != null) {
      try {
        await PlatformBridge.cancelNativeDataJob(requestId);
      } catch (error) {
        _log.w('Failed to cancel library data job: $error');
      }
    }
    _pendingReconnectScans.clear();
    _availabilityRequestVersion++;
    _scanReconnectedOnRefresh = false;
    // Native cancel also releases a paused scan.
    _scanPauseRequested = false;
    if (state.isScanning && !_isScanningNetwork) {
      await PlatformBridge.cancelLibraryScan();
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      scanIsFinalizing: false,
      scanIsPaused: false,
      scanWasCancelled: true,
    );
    _stopProgressPolling();
    await _showScanCancelledNotification();
  }

  /// Holds the running scan in place. Files already processed stay in the
  /// native scan's memory, so [resumeScan] continues with the next file.
  Future<void> pauseScan() async {
    if (!state.isScanning ||
        state.scanIsFinalizing ||
        state.scanIsPaused ||
        _scanCancelRequested) {
      return;
    }
    _log.i('Pausing library scan at ${state.scannedFiles} files');
    _scanPauseRequested = true;
    state = state.copyWith(scanIsPaused: true);
    try {
      if (!_isScanningNetwork) await PlatformBridge.pauseLibraryScan();
    } catch (e) {
      _log.w('Failed to pause library scan: $e');
      _scanPauseRequested = false;
      state = state.copyWith(scanIsPaused: false);
      return;
    }
    // A paused scan does no work; release the foreground service and wake
    // lock (iOS background task) until the user resumes.
    await _notificationService.endBackgroundWork(
      NotificationService.libraryScanWorkKind,
    );
    await _showScanPausedNotification(state.scannedFiles);
  }

  Future<void> resumeScan() async {
    if (!state.isScanning || !state.scanIsPaused || !_scanPauseRequested) {
      return;
    }
    _log.i('Resuming library scan from ${state.scannedFiles} files');
    // Reacquire background work first so resumed reads survive screen-off.
    await _notificationService.beginLibraryScanWork();
    await _cancelScanPausedNotification();
    _scanPauseRequested = false;
    _resetScanNotificationTracking();
    state = state.copyWith(scanIsPaused: false);
    await _releaseNativeScanPause();
  }

  Future<void> _releaseNativeScanPause() async {
    try {
      await PlatformBridge.resumeLibraryScan();
    } catch (e) {
      _log.w('Failed to release library scan pause: $e');
    }
  }

  /// The native scan can finish while paused when the pause lands after its
  /// last file. Ingestion then runs normally, so restore background work.
  Future<void> _endPauseForFinalization() async {
    if (!_scanPauseRequested) return;
    _scanPauseRequested = false;
    state = state.copyWith(scanIsPaused: false);
    await _notificationService.beginLibraryScanWork();
    await _cancelScanPausedNotification();
    await _releaseNativeScanPause();
  }

  Future<void> _showScanPausedNotification(int scannedFiles) async {
    try {
      await _notificationService.showLibraryScanPaused(
        scannedFiles: scannedFiles,
      );
    } catch (e) {
      _log.w('Failed to show scan paused notification: $e');
    }
  }

  Future<void> _cancelScanPausedNotification() async {
    try {
      await _notificationService.cancelLibraryScanNotification();
    } catch (e) {
      _log.w('Failed to clear scan paused notification: $e');
    }
  }

  Future<void> _showScanProgressNotification({
    required double progress,
    required int scannedFiles,
    required int totalFiles,
    required String? currentFile,
  }) async {
    try {
      await _notificationService.showLibraryScanProgress(
        progress: progress,
        scannedFiles: scannedFiles,
        totalFiles: totalFiles,
        currentFile: _shortenFileForNotification(currentFile),
      );
    } catch (e) {
      _log.w('Failed to show scan progress notification: $e');
    }
  }

  Future<void> _showScanCompleteNotification({
    required int totalTracks,
    required int excludedDownloadedCount,
    required int errorCount,
  }) async {
    try {
      await _notificationService.showLibraryScanComplete(
        totalTracks: totalTracks,
        excludedDownloadedCount: excludedDownloadedCount,
        errorCount: errorCount,
      );
    } catch (e) {
      _log.w('Failed to show scan complete notification: $e');
    }
  }

  Future<void> _showScanFailedNotification(String message) async {
    try {
      await _notificationService.showLibraryScanFailed(message);
    } catch (e) {
      _log.w('Failed to show scan failure notification: $e');
    }
  }

  Future<void> _showScanCancelledNotification() async {
    try {
      await _notificationService.showLibraryScanCancelled();
    } catch (e) {
      _log.w('Failed to show scan cancelled notification: $e');
    }
  }

  String? _shortenFileForNotification(String? path) {
    final raw = path?.trim() ?? '';
    if (raw.isEmpty) return null;

    var decoded = raw;
    try {
      decoded = Uri.decodeFull(raw);
    } catch (_) {}

    final slashIdx = decoded.lastIndexOf('/');
    final backslashIdx = decoded.lastIndexOf('\\');
    final cut = slashIdx > backslashIdx ? slashIdx : backslashIdx;
    if (cut >= 0 && cut < decoded.length - 1) {
      return decoded.substring(cut + 1);
    }
    return decoded;
  }

  Future<int> cleanupMissingFiles({String? iosBookmark}) async {
    await refreshSourceAvailability();
    var removed = 0;
    for (final source in state.sources) {
      if (!source.enabled || !source.available) continue;
      IosSecurityScopedAccess? securityAccess;
      try {
        if (Platform.isIOS &&
            source.bookmark != null &&
            source.bookmark!.isNotEmpty) {
          securityAccess = await PlatformBridge.startAccessingIosBookmark(
            source.bookmark!,
          );
          if (securityAccess == null) continue;
        }
        removed += await _db.cleanupMissingFiles(
          sourceId: source.id,
          canDelete: () async {
            if (isContentUri(source.path)) {
              return await PlatformBridge.probeSafTreeReadAccess(source.path) ==
                  true;
            }
            // Recheck access after the file probes, before deleting a page.
            // An empty but readable source is valid; an offline one throws.
            await Directory(
              securityAccess?.path ?? source.path,
            ).list(followLinks: false).take(1).drain<void>();
            return true;
          },
        );
      } finally {
        if (securityAccess != null) {
          await PlatformBridge.stopAccessingIosBookmark(securityAccess);
        }
      }
    }
    if (removed > 0) await _refreshSummaryFromStorage();
    return removed;
  }

  Future<void> clearLibrary() async {
    _sourceVersion++;
    await _db.clearAll();

    try {
      final prefs = await SharedPreferences.getInstance();
      await clearLocalLibraryLastScannedAt(prefs);
      await prefs.remove(_excludedDownloadedCountKey);
    } catch (e) {
      _log.w('Failed to clear lastScannedAt: $e');
    }

    await _refreshSummaryFromStorage();
    state = state.copyWith(clearLastScannedAt: true);
    _log.i('Library cleared');
  }

  Future<void> _pruneLibraryCoverCache() async {
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      final libraryCoverDir = Directory('${appSupportDir.path}/library_covers');
      if (!await libraryCoverDir.exists()) {
        return;
      }

      if (!ref.mounted || _scanCancelRequested) return;
      final libraryDatabase = await _db.database;
      if (!ref.mounted || _scanCancelRequested) return;

      final deletedCount = await pruneUnreferencedLibraryCovers(
        libraryCoverDir,
        const {},
        libraryDatabase: libraryDatabase,
        requestId: _nativeLibraryRequestId,
        canPrune: () => ref.mounted && !_scanCancelRequested,
        // Avoid removing covers being written by a background producer before
        // its Library transaction publishes the reference. The scan guard is
        // still held here; the source sqflite transaction holds the writer
        // barrier while Rust reads its detached, private cover projection.
        minimumAge: const Duration(minutes: 1),
      );

      if (deletedCount > 0) {
        _log.i('Pruned $deletedCount stale library cover cache files');
      }
    } catch (e) {
      _log.w('Failed pruning library cover cache: $e');
    }
  }

  Future<void> removePhysicalFiles(Iterable<String> filePaths) async {
    await removeItems(await _db.getPhysicalFileIds(filePaths));
  }

  Future<void> removeItem(String id) async {
    await removeItems([id]);
  }

  Future<void> removeItems(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    await _db.deleteByIds(ids);
    await _refreshSummaryFromStorage();
  }

  Future<LocalLibraryItem?> getById(String id) async {
    final json = await _db.getById(id);
    return json == null ? null : LocalLibraryItem.fromJson(json);
  }

  Future<LocalLibraryItem?> getByIsrcAsync(String isrc) async {
    final json = await _db.getByIsrc(isrc);
    return json == null ? null : LocalLibraryItem.fromJson(json);
  }

  Future<LocalLibraryItem?> findByTrackAndArtistAsync(
    String trackName,
    String artistName,
  ) async {
    final json = await _db.findFirstByTrackAndArtist(trackName, artistName);
    return json == null ? null : LocalLibraryItem.fromJson(json);
  }

  Future<LocalLibraryItem?> findExistingAsync({
    String? id,
    String? isrc,
    String? trackName,
    String? artistName,
  }) async {
    if (id != null && id.isNotEmpty) {
      final byId = await getById(id);
      if (byId != null) return byId;
    }
    if (isrc != null && isrc.isNotEmpty) {
      final byIsrc = await getByIsrcAsync(isrc);
      if (byIsrc != null) return byIsrc;
    }
    if (trackName != null && artistName != null) {
      return findByTrackAndArtistAsync(trackName, artistName);
    }
    return null;
  }

  Future<Map<String, int>> _backfillLegacyFileModTimes({
    required bool isSaf,
    required Map<String, int> existingFiles,
  }) async {
    final legacyPaths = existingFiles.entries
        // Negative timestamps deliberately force a metadata-version rescan;
        // only a missing timestamp (zero) may be filled from the filesystem.
        .where((entry) => entry.value == 0)
        .map((entry) => entry.key)
        .toList();
    if (legacyPaths.isEmpty) {
      return const {};
    }

    if (isSaf) {
      final uris = legacyPaths
          .where((path) => path.startsWith('content://'))
          .toList();
      if (uris.isEmpty) {
        return const {};
      }
      const chunkSize = 500;
      final backfilled = <String, int>{};
      try {
        for (var i = 0; i < uris.length; i += chunkSize) {
          if (_scanCancelRequested) {
            break;
          }
          final end = (i + chunkSize < uris.length)
              ? i + chunkSize
              : uris.length;
          final chunk = uris.sublist(i, end);
          final chunkResult = await PlatformBridge.getSafFileModTimes(chunk);
          backfilled.addAll(chunkResult);
        }
        return backfilled;
      } catch (e) {
        _log.w('Failed to backfill SAF mod times: $e');
        return const {};
      }
    }

    final paths = legacyPaths
        .where((path) => !path.startsWith('content://'))
        .toList(growable: false);
    const chunkSize = 24;
    final backfilled = <String, int>{};

    for (var i = 0; i < paths.length; i += chunkSize) {
      if (_scanCancelRequested) {
        break;
      }
      final end = (i + chunkSize < paths.length) ? i + chunkSize : paths.length;
      final chunk = paths.sublist(i, end);
      final chunkEntries = await Future.wait<MapEntry<String, int>?>(
        chunk.map((path) async {
          try {
            final stat = await File(path).stat();
            if (stat.type == FileSystemEntityType.file) {
              return MapEntry(path, stat.modified.millisecondsSinceEpoch);
            }
          } catch (_) {}
          return null;
        }),
      );
      for (final entry in chunkEntries) {
        if (entry != null) {
          backfilled[entry.key] = entry.value;
        }
      }
    }
    return backfilled;
  }
}

final localLibraryProvider =
    NotifierProvider<LocalLibraryNotifier, LocalLibraryState>(
      LocalLibraryNotifier.new,
    );

class LocalLibraryCoverRequest {
  final String? isrc;
  final String trackName;
  final String artistName;

  const LocalLibraryCoverRequest({
    this.isrc,
    required this.trackName,
    required this.artistName,
  });

  @override
  bool operator ==(Object other) {
    return other is LocalLibraryCoverRequest &&
        other.isrc == isrc &&
        other.trackName == trackName &&
        other.artistName == artistName;
  }

  @override
  int get hashCode => Object.hash(isrc, trackName, artistName);
}

class LocalLibraryCoverBatchRequest {
  final List<LocalLibraryCoverRequest> tracks;

  const LocalLibraryCoverBatchRequest(this.tracks);

  @override
  bool operator ==(Object other) {
    if (other is! LocalLibraryCoverBatchRequest) return false;
    if (other.tracks.length != tracks.length) return false;
    for (var i = 0; i < tracks.length; i++) {
      if (other.tracks[i] != tracks[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(tracks);
}

String? _nonEmptyCoverPath(Map<String, dynamic>? json) {
  final coverPath = json?['coverPath'] as String?;
  final trimmed = coverPath?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

final localLibraryCoverProvider = FutureProvider.autoDispose
    .family<String?, LocalLibraryCoverRequest>((ref, request) {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      return LibraryDatabase.instance
          .findExisting(
            isrc: request.isrc,
            trackName: request.trackName,
            artistName: request.artistName,
          )
          .then(_nonEmptyCoverPath);
    });

final localLibraryFirstCoverProvider = FutureProvider.autoDispose
    .family<String?, LocalLibraryCoverBatchRequest>((ref, request) async {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      final rows = await LibraryDatabase.instance.findExistingBatch([
        for (final track in request.tracks)
          LocalLibraryBatchLookupRequest(
            isrc: track.isrc,
            trackName: track.trackName,
            artistName: track.artistName,
          ),
      ]);
      for (final row in rows) {
        final cover = _nonEmptyCoverPath(row);
        if (cover != null) return cover;
      }
      return null;
    });
