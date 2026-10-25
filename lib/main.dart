import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/app.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/download_queue_provider.dart';
import 'package:mosix/providers/extension_provider.dart';
import 'package:mosix/providers/local_library_provider.dart';
import 'package:mosix/providers/runtime_profile_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/providers/theme_provider.dart';
import 'package:mosix/services/notification_service.dart';
import 'package:mosix/services/platform_bridge.dart';
import 'package:mosix/services/share_intent_service.dart';
import 'package:mosix/services/cover_cache_manager.dart';
import 'package:mosix/services/app_state_database.dart';
import 'package:mosix/services/app_navigation_service.dart';
import 'package:mosix/services/app_orientation.dart';
import 'package:mosix/services/music_player_service.dart';
import 'package:mosix/services/player_widget_service.dart';
import 'package:mosix/screens/now_playing_screen.dart';
import 'package:mosix/utils/local_library_scan_prefs.dart';
import 'package:mosix/utils/logger.dart';
import 'package:mosix/utils/extension_auth_launcher.dart';

final _log = AppLogger('Main');
_StartupBenchmark? _startupBenchmark;

void main() {
  if (const bool.fromEnvironment('CORE_BACKEND_STARTUP_BENCHMARK')) {
    _startupBenchmark = _StartupBenchmark();
  }
  // Catch uncaught Dart errors so a failing async path is logged, not fatal.
  // Native (Go) crashes still can't be caught here.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await setAppOrientation();
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(const [
          'Inter',
        ], await rootBundle.loadString('assets/fonts/Inter-LICENSE.txt'));
        yield LicenseEntryWithLineBreaks(const [
          'libsmb2',
        ], await rootBundle.loadString('assets/licenses/libsmb2.txt'));
        yield LicenseEntryWithLineBreaks(const [
          'Material Color Utilities (native palette)',
          'Dart SDK (native Random compatibility)',
        ], await rootBundle.loadString('assets/licenses/native_palette.txt'));
        yield LicenseEntryWithLineBreaks(const [
          'rusqlite',
          'roxmltree',
        ], await rootBundle.loadString('assets/licenses/native_data_jobs.txt'));
        if (Platform.isAndroid) {
          yield LicenseEntryWithLineBreaks(const [
            'libusb',
            'libusb1-sys',
          ], await rootBundle.loadString('assets/licenses/usb.txt'));
          yield LicenseEntryWithLineBreaks(const [
            'Oboe',
          ], await rootBundle.loadString('assets/licenses/oboe.txt'));
          yield LicenseEntryWithLineBreaks(const [
            'WavPack',
          ], await rootBundle.loadString('assets/licenses/wavpack.txt'));
        }
      });
      _startupBenchmark?.observeFirstFrame();

      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        previousOnError?.call(details);
        _log.e('Uncaught Flutter error: ${details.exceptionAsString()}');
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        _log.e('Uncaught platform error: $error');
        return true;
      };

      final prefs = await SharedPreferences.getInstance();
      await _prepareAndroidInstallationState(prefs);
      final bootstrapSettings = loadBootstrapSettings(prefs);
      musicPlayerRuntime.configure(bootstrapSettings);
      final bootstrapTheme = loadBootstrapThemeSettings(prefs);
      final initialSafAccessLost = await _detectInitialSafAccessLoss(
        bootstrapSettings,
      );
      final runtimeProfile = await _resolveRuntimeProfile(prefs);
      _configureImageCache(runtimeProfile);

      runApp(
        ProviderScope(
          overrides: [
            lowEndDeviceProvider.overrideWithValue(
              runtimeProfile.disableOverscrollEffects,
            ),
            deviceSupportsBackdropBlurProvider.overrideWithValue(
              runtimeProfile.enableBackdropBlur,
            ),
            // The RAM tiers describe Android hardware. Other platforms keep
            // the existing full material by default.
            deviceSupportsLiquidGlassProvider.overrideWithValue(
              !Platform.isAndroid || runtimeProfile.enableBackdropBlur,
            ),
            initialSettingsProvider.overrideWithValue(bootstrapSettings),
            initialSafAccessLostProvider.overrideWithValue(
              initialSafAccessLost,
            ),
            initialThemeSettingsProvider.overrideWithValue(bootstrapTheme),
          ],
          child: EagerInitialization(
            child: MosixApp(
              disableOverscrollEffects: runtimeProfile.disableOverscrollEffects,
            ),
          ),
        ),
      );
      if (Platform.isAndroid || Platform.isIOS) {
        unawaited(
          PlayerWidgetService.instance.initialize((command) async {
            await restorePersistedPlaybackSession();
            final handler = await initMusicPlayer();
            if (command == 'open') {
              await WidgetsBinding.instance.endOfFrame;
              final navigator =
                  AppNavigationService.rootNavigatorKey.currentState;
              if (navigator != null && handler.mediaItem.value != null) {
                unawaited(
                  navigator.push<void>(
                    NowPlayingRoute(child: const NowPlayingScreen()),
                  ),
                );
              }
            } else {
              await PlayerWidgetService.control(handler, command);
            }
          }),
        );
      }
    },
    (error, stack) {
      _log.e('Uncaught zone error: $error');
    },
  );
}

// Opt-in release measurement. The ordinary startup path owns initialization;
// reporting and validation happen after both measured boundaries are captured.
class _StartupBenchmark {
  final _watch = Stopwatch()..start();
  late final Future<int> _firstFrame;

  void observeFirstFrame() {
    _firstFrame = WidgetsBinding.instance.waitUntilFirstFrameRasterized.then(
      (_) => _watch.elapsedMicroseconds,
    );
  }

  void extensionsReady(ExtensionState state, AppSettings settings) {
    final ready = _watch.elapsedMicroseconds;
    unawaited(_report(state, settings, ready));
  }

  Future<void> _report(
    ExtensionState state,
    AppSettings settings,
    int ready,
  ) async {
    try {
      if (!kReleaseMode) throw StateError('Startup benchmark requires release');
      final firstFrame = await _firstFrame.timeout(const Duration(seconds: 30));
      if (!state.isInitialized || state.error != null) {
        throw StateError('Extensions are not ready: ${state.error}');
      }
      final backends = await PlatformBridge.getBackendImplementations();
      const backend = String.fromEnvironment('EXPECTED_CORE_BACKEND');
      if (!const ['go', 'rust'].contains(backend) ||
          backends.length != 4 ||
          backends.values.any((value) => value != backend)) {
        throw StateError('Unexpected backend ownership: $backends');
      }
      await _write({
        'result': 'CORE_BACKEND_STARTUP_PASS backend=$backend',
        'startup': {
          'schema': 1,
          'backend': backend,
          'mode': 'release',
          'start_boundary': 'Dart main entry before bindings',
          'first_frame_boundary': 'first rasterized frame observed',
          'ready_boundary': 'production ensureInitialized completed',
          'cache': 'fresh process; warm filesystem',
          'first_frame_us': firstFrame,
          'extensions_ready_us': ready,
          'settings_sha256': sha256
              .convert(utf8.encode(jsonEncode(settings.toJson())))
              .toString(),
          'extensions': [
            for (final extension in state.extensions)
              {
                'id': extension.id,
                'enabled': extension.enabled,
                'status': extension.status,
              },
          ],
        },
      });
    } catch (error) {
      await _write({'result': 'CORE_BACKEND_STARTUP_FAIL $error'});
    }
  }

  Future<void> _write(Map<String, Object?> result) async {
    final support = await getApplicationSupportDirectory();
    await File(
      '${support.path}/core-backend-probe-result.json',
    ).writeAsString(jsonEncode({'pid': pid, ...result}), flush: true);
  }
}

const _runtimeProfileTierKey = 'runtime_profile_tier_v1';

Future<void> _prepareAndroidInstallationState(SharedPreferences prefs) async {
  if (!Platform.isAndroid) return;

  try {
    final hasPersistedSettings = hasPersistedAppSettings(prefs);
    final installState = await PlatformBridge.ensureInstallMarker();
    final shouldReset = shouldResetRestoredInstallation(
      hasPersistedSettings: hasPersistedSettings,
      installState: installState,
    );
    if (!shouldReset) return;

    _log.w(
      'Android restored state into a fresh installation; resetting '
      'installation-bound settings',
    );
    await resetRestoredInstallationSettings(prefs);
    await prefs.remove(_runtimeProfileTierKey);
    await prefs.remove(localLibraryLastScannedAtKey);
    await AppStateDatabase.instance.clearPendingQueueAfterInstallationRestore();
  } catch (e) {
    // Startup SAF validation remains the second line of defense if an OEM or
    // bridge implementation prevents install-marker inspection.
    _log.w('Failed to inspect restored installation state: $e');
  }
}

Future<bool> _detectInitialSafAccessLoss(AppSettings settings) async {
  if (!Platform.isAndroid ||
      settings.isFirstLaunch ||
      settings.storageMode != 'saf' ||
      settings.downloadTreeUri.isEmpty) {
    return false;
  }

  try {
    return !await PlatformBridge.validateSafTreeAccess(
      settings.downloadTreeUri,
    ).timeout(const Duration(seconds: 2));
  } catch (e) {
    // A transient bridge failure must not trap the user at launch. Download
    // preflight validates strictly again before any write starts.
    _log.w('Failed to validate SAF access during startup: $e');
    return false;
  }
}

Future<_RuntimeProfile> _resolveRuntimeProfile(SharedPreferences prefs) async {
  final cachedTier = prefs.getString(_runtimeProfileTierKey);
  if (cachedTier != null) {
    final cached = _RuntimeProfile.fromTier(cachedTier);
    if (cached != null) return cached;
  }

  const defaults = _RuntimeProfile.standard();

  if (!Platform.isAndroid) {
    await prefs.setString(_runtimeProfileTierKey, defaults.tier);
    return defaults;
  }

  try {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final isArm32Only = androidInfo.supported64BitAbis.isEmpty;
    final isLowRamDevice =
        androidInfo.isLowRamDevice || androidInfo.physicalRamSize <= 2500;

    final profile = (isArm32Only || isLowRamDevice)
        ? const _RuntimeProfile.low()
        : androidInfo.physicalRamSize >= 6000
        ? const _RuntimeProfile.high()
        : defaults;
    await prefs.setString(_runtimeProfileTierKey, profile.tier);
    return profile;
  } catch (e) {
    debugPrint('Failed to resolve runtime profile: $e');
    return defaults;
  }
}

void _configureImageCache(_RuntimeProfile runtimeProfile) {
  final imageCache = PaintingBinding.instance.imageCache;
  // Keep memory cache bounded so cover-heavy pages don't retain too many
  // full-resolution images simultaneously.
  imageCache.maximumSize = runtimeProfile.imageCacheMaximumSize;
  imageCache.maximumSizeBytes = runtimeProfile.imageCacheMaximumSizeBytes;
}

class _RuntimeProfile {
  final String tier;
  final int imageCacheMaximumSize;
  final int imageCacheMaximumSizeBytes;
  final bool disableOverscrollEffects;
  final bool enableBackdropBlur;

  const _RuntimeProfile._({
    required this.tier,
    required this.imageCacheMaximumSize,
    required this.imageCacheMaximumSizeBytes,
    required this.disableOverscrollEffects,
    required this.enableBackdropBlur,
  });

  const _RuntimeProfile.low()
    : this._(
        tier: 'low',
        imageCacheMaximumSize: 120,
        imageCacheMaximumSizeBytes: 24 << 20,
        disableOverscrollEffects: true,
        enableBackdropBlur: false,
      );

  const _RuntimeProfile.standard()
    : this._(
        tier: 'standard',
        imageCacheMaximumSize: 240,
        imageCacheMaximumSizeBytes: 60 << 20,
        disableOverscrollEffects: false,
        enableBackdropBlur: false,
      );

  const _RuntimeProfile.high()
    : this._(
        tier: 'high',
        imageCacheMaximumSize: 320,
        imageCacheMaximumSizeBytes: 80 << 20,
        disableOverscrollEffects: false,
        enableBackdropBlur: true,
      );

  static _RuntimeProfile? fromTier(String tier) => switch (tier) {
    'low' => const _RuntimeProfile.low(),
    'standard' => const _RuntimeProfile.standard(),
    'high' => const _RuntimeProfile.high(),
    _ => null,
  };
}

class EagerInitialization extends ConsumerStatefulWidget {
  const EagerInitialization({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<EagerInitialization> createState() =>
      _EagerInitializationState();
}

class _EagerInitializationState extends ConsumerState<EagerInitialization>
    with WidgetsBindingObserver {
  ProviderSubscription<bool>? _localLibraryEnabledSub;
  Timer? _downloadHistoryWarmupTimer;
  Timer? _localLibraryWarmupTimer;
  bool _localLibraryWarmupScheduled = false;
  bool _autoScanTriggeredOnLaunch = false;
  StreamSubscription<void>? _verificationNotificationSubscription;
  StreamSubscription<void>? _extensionAuthCallbackSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _verificationNotificationSubscription =
          PlatformBridge.verificationNotificationEvents().listen(
            (_) => unawaited(_consumeVerificationNotification()),
          );
      _extensionAuthCallbackSubscription =
          PlatformBridge.extensionAuthCallbackEvents().listen(
            (_) => unawaited(_completeExtensionCallback()),
          );
      _initializeAppServices();
      _initializeExtensions();
      _initializeDeferredProviders();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CoverCacheManager.stopMaintenance();
    _localLibraryEnabledSub?.close();
    _downloadHistoryWarmupTimer?.cancel();
    _localLibraryWarmupTimer?.cancel();
    _verificationNotificationSubscription?.cancel();
    _extensionAuthCallbackSubscription?.cancel();
    NotificationService().verificationNotifications.setHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_consumeVerificationNotification());
      CoverCacheManager.scheduleMaintenance();
      // Native downloads can finish while Flutter is suspended. Refresh the
      // persisted history even when no queued item remains to reconcile.
      if (ref.exists(downloadHistoryProvider)) {
        unawaited(
          ref.read(downloadHistoryProvider.notifier).reloadFromStorage(),
        );
      }
      _maybeAutoScanLocalLibrary();
      if (ref.exists(localLibraryProvider)) {
        unawaited(
          ref
              .read(localLibraryProvider.notifier)
              .refreshSourceAvailability(scanReconnected: true),
        );
      }
      if (ref.exists(downloadQueueProvider)) {
        ref
            .read(downloadQueueProvider.notifier)
            .resumePendingDownloadsOnForeground();
      }
    } else if (state == AppLifecycleState.paused) {
      CoverCacheManager.stopMaintenance();
      // Last reliable moment before the OS may kill the process: make sure
      // any debounced download-queue persistence reaches disk.
      if (ref.exists(downloadQueueProvider)) {
        unawaited(
          ref
              .read(downloadQueueProvider.notifier)
              .flushQueuePersistence()
              .catchError((Object error) {
                _log.e('Failed to flush background download queue: $error');
              }),
        );
      }
      // Backgrounded: release idle native runtimes and connections.
      unawaited(PlatformBridge.releaseNativeMemory());
    }
  }

  @override
  void didHaveMemoryPressure() {
    // OS memory pressure: drop decoded bitmaps (disk caches stay intact) and
    // ask the native backend to release disposable runtimes and caches.
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
    if (CoverCacheManager.isInitialized) {
      CoverCacheManager.instance.store.emptyMemoryCache();
    }
    unawaited(PlatformBridge.releaseNativeMemory(underPressure: true));
  }

  void _initializeDeferredProviders() {
    _downloadHistoryWarmupTimer = _scheduleProviderWarmup(
      const Duration(milliseconds: 400),
      () => ref.read(downloadHistoryProvider),
    );
    _maybeScheduleLocalLibraryWarmup(
      ref.read(
        settingsProvider.select((settings) => settings.localLibraryEnabled),
      ),
    );

    _localLibraryEnabledSub = ref.listenManual<bool>(
      settingsProvider.select((settings) => settings.localLibraryEnabled),
      (previous, next) {
        if (next == true) {
          _maybeScheduleLocalLibraryWarmup(true);
        }
      },
    );
  }

  Timer _scheduleProviderWarmup(Duration delay, VoidCallback action) {
    return Timer(delay, () {
      if (!mounted) return;
      action();
    });
  }

  void _maybeScheduleLocalLibraryWarmup(bool enabled) {
    if (!enabled || _localLibraryWarmupScheduled) return;
    _localLibraryWarmupScheduled = true;
    _localLibraryWarmupTimer = _scheduleProviderWarmup(
      const Duration(milliseconds: 1600),
      () {
        if (!ref.read(settingsProvider).localLibraryEnabled) {
          _localLibraryWarmupScheduled = false;
          return;
        }
        ref.read(localLibraryProvider);
        if (!_autoScanTriggeredOnLaunch) {
          _autoScanTriggeredOnLaunch = true;
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _maybeAutoScanLocalLibrary();
          });
        }
      },
    );
  }

  Future<void> _maybeAutoScanLocalLibrary() async {
    if (!mounted) return;

    final settings = ref.read(settingsProvider);
    if (!settings.localLibraryEnabled) return;
    if (settings.localLibraryAutoScan == 'off') return;

    final libraryState = ref.read(localLibraryProvider);
    if (libraryState.isScanning) return;

    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final pendingSourceId = prefs.getString(localLibraryActiveScanSourceKey);
    if (pendingSourceId != null && pendingSourceId.trim().isNotEmpty) {
      await ref
          .read(localLibraryProvider.notifier)
          .startSourceScan(pendingSourceId.trim());
      return;
    }
    final lastScanned = readLocalLibraryLastScannedAt(prefs);

    if (lastScanned != null) {
      final elapsed = now.difference(lastScanned);

      switch (settings.localLibraryAutoScan) {
        case 'on_open':
          if (elapsed.inMinutes < 10) return;
          break;
        case 'daily':
          if (elapsed.inHours < 24) return;
          break;
        case 'weekly':
          if (elapsed.inDays < 7) return;
          break;
        default:
          return;
      }
    }

    await ref.read(localLibraryProvider.notifier).scanAllSources();
  }

  Future<void> _initializeAppServices() async {
    try {
      await CoverCacheManager.initialize();
      CoverCacheManager.scheduleMaintenance();
      await Future.wait([
        NotificationService().initialize(),
        ShareIntentService().initialize(),
      ]);
    } catch (e) {
      debugPrint('Failed to initialize app services: $e');
    }
  }

  Future<void> _initializeExtensions() async {
    try {
      await ref.read(extensionProvider.notifier).ensureInitialized();
      _startupBenchmark?.extensionsReady(
        ref.read(extensionProvider),
        ref.read(settingsProvider),
      );
      if (!mounted) return;
      NotificationService().verificationNotifications.setHandler((
        target,
      ) async {
        if (!mounted) return;
        try {
          await ref
              .read(downloadQueueProvider.notifier)
              .handleVerificationNotificationTap(target);
        } catch (error) {
          _log.w('Could not open verification notification: $error');
          if (mounted) showExtensionVerificationUnavailable(target.extensionId);
        }
      });
      await _consumeVerificationNotification();
    } catch (e) {
      debugPrint('Failed to initialize extensions: $e');
    }
  }

  Future<void> _consumeVerificationNotification() async {
    if (!mounted || !Platform.isAndroid) return;
    try {
      final payload = await PlatformBridge.consumeVerificationNotification();
      if (mounted) {
        NotificationService().verificationNotifications.receive(payload);
      }
    } catch (error) {
      _log.w('Could not read pending verification notification: $error');
    }
  }

  Future<void> _completeExtensionCallback() async {
    try {
      await ref.read(extensionProvider.notifier).ensureInitialized();
      await PlatformBridge.processPendingExtensionCallbacks();
    } catch (error) {
      _log.w('Could not complete extension verification: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
