import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/constants/app_info.dart';
import 'package:mosix/screens/upgrade_intro_screen.dart';
import 'package:mosix/services/upgrade_intro_service.dart';
import 'package:mosix/providers/download_queue_provider.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/providers/playback_notification_provider.dart';
import 'package:mosix/providers/repo_provider.dart';
import 'package:mosix/providers/runtime_profile_provider.dart';
import 'package:mosix/providers/track_provider.dart';
import 'package:mosix/providers/preview_player_provider.dart';
import 'package:mosix/screens/home_tab.dart';
import 'package:mosix/screens/repo_tab.dart';
import 'package:mosix/screens/queue_tab.dart';
import 'package:mosix/screens/settings/settings_tab.dart';
import 'package:mosix/services/platform_bridge.dart';
import 'package:mosix/services/shell_navigation_service.dart';
import 'package:mosix/services/share_intent_service.dart';
import 'package:mosix/services/music_playback_deck.dart';
import 'package:mosix/services/listening_statistics.dart';
import 'package:mosix/services/discord_presence_service.dart';
import 'package:mosix/services/notification_service.dart';
import 'package:mosix/services/app_remote_config_service.dart';
import 'package:mosix/services/update_checker.dart';
import 'package:mosix/widgets/app_announcement_dialog.dart';
import 'package:mosix/widgets/app_snack_bar.dart';
import 'package:mosix/widgets/download_queue_feedback.dart';
import 'package:mosix/widgets/update_dialog.dart';
import 'package:mosix/widgets/animation_utils.dart';
import 'package:mosix/widgets/settings_group.dart';
import 'package:mosix/widgets/mini_player.dart';
import 'package:mosix/widgets/lazy_tab_view.dart';
import 'package:mosix/widgets/expressive_navigation_bar.dart';
import 'package:mosix/widgets/mornye_bottom_bar.dart';
import 'package:mosix/widgets/mornye_chrome.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/widgets/selection_bottom_bar.dart';
import 'package:mosix/utils/logger.dart';
import 'package:mosix/utils/adaptive_layout.dart';

final _log = AppLogger('MainShell');

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _currentIndex = 0;
  final _mornyeChrome = MornyeChromeController();
  // Preserves the tab view element (and its kept-alive tabs) when the body
  // structure swaps between rail and bottom-bar layouts on rotation.
  final GlobalKey _pageViewKey = GlobalKey();
  late final PageController _pageController;
  late final AnimationController _tabJumpTransitionController;
  // Transitions update their layers directly; no shell subtree rebuilds per
  // animation frame.
  late final CurvedAnimation _tabJumpOpacity = CurvedAnimation(
    parent: _tabJumpTransitionController,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _tabJumpScale = Tween<double>(
    begin: 0.985,
    end: 1,
  ).animate(_tabJumpOpacity);
  bool _hasCheckedUpdate = false;
  bool _hasCheckedAppAnnouncement = false;
  bool _initialSafRepairComplete = false;
  bool _safRepairDialogVisible = false;
  bool _usbVolumeWarningShown = false;
  StreamSubscription<String>? _shareSubscription;
  DateTime? _lastBackPress;
  final GlobalKey<NavigatorState> _homeTabNavigatorKey =
      ShellNavigationService.homeTabNavigatorKey;
  final GlobalKey<NavigatorState> _libraryTabNavigatorKey =
      ShellNavigationService.libraryTabNavigatorKey;
  final GlobalKey<NavigatorState> _repoTabNavigatorKey =
      ShellNavigationService.repoTabNavigatorKey;
  final GlobalKey<NavigatorState> _searchTabNavigatorKey =
      ShellNavigationService.searchTabNavigatorKey;

  late final _PreviewStopNavigatorObserver _homePreviewStopObserver;
  late final _PreviewStopNavigatorObserver _libraryPreviewStopObserver;
  late final _PreviewStopNavigatorObserver _repoPreviewStopObserver;
  late final _PreviewStopNavigatorObserver _searchPreviewStopObserver;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final l10n = context.l10n;
    NotificationService().updateStrings(l10n);
    final playback = ref.read(musicPlayerRuntimeProvider);
    playback.updateStrings(
      unknownTitle: l10n.unknownTitle,
      unknownArtist: l10n.unknownArtist,
    );
    final settings = ref.read(settingsProvider);
    playback.configure(settings);
    unawaited(
      DiscordPresenceService.instance.setEnabled(
        settings.discordRichPresenceEnabled,
      ),
    );
    listeningRecorder.setEnabled(settings.listeningStatisticsEnabled);
    // Deezer & co. localize artist/genre names by IP unless told the app's
    // language (issue #480).
    unawaited(
      PlatformBridge.setMetadataLanguage(
        Localizations.localeOf(context).toLanguageTag(),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    usbAudioStatus.addListener(_onUsbAudioStatusChanged);
    _homePreviewStopObserver = _PreviewStopNavigatorObserver(
      () => ref.read(previewPlayerProvider.notifier).stop(),
    );
    _libraryPreviewStopObserver = _PreviewStopNavigatorObserver(
      () => ref.read(previewPlayerProvider.notifier).stop(),
    );
    _repoPreviewStopObserver = _PreviewStopNavigatorObserver(
      () => ref.read(previewPlayerProvider.notifier).stop(),
    );
    _searchPreviewStopObserver = _PreviewStopNavigatorObserver(
      () => ref.read(previewPlayerProvider.notifier).stop(),
    );
    _pageController = PageController(initialPage: _currentIndex);
    _tabJumpTransitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      value: 1,
    );
    ShellNavigationService.registerTabSelectionHandler(
      owner: this,
      handler: _onShellTabRequested,
    );
    ShellNavigationService.syncState(
      currentTabIndex: _currentIndex,
      showRepoTab: false,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _repairSafAccessIfNeeded(
        knownLost: ref.read(initialSafAccessLostProvider),
      );
      _initialSafRepairComplete = true;
      if (!mounted) return;
      unawaited(ref.read(musicPlayerRuntimeProvider).restoreSession());
      await _checkUpgradeIntro();
      if (!mounted) return;
      _setupShareListener();
      await _checkSafMigration();
      final updateDialogShown = await _checkForUpdates();
      if (!updateDialogShown) {
        await _checkAppAnnouncement();
      }
    });
  }

  void _onUsbAudioStatusChanged() {
    if (usbAudioStatus.value.reason == 'active') {
      _usbVolumeWarningShown = false;
    }
    if (usbAudioStatus.value.reason != 'volume_unavailable' ||
        _usbVolumeWarningShown) {
      return;
    }
    _usbVolumeWarningShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || usbAudioStatus.value.reason != 'volume_unavailable') {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.usbVolumeUnavailable),
          duration: const Duration(seconds: 8),
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _initialSafRepairComplete) {
      unawaited(_repairSafAccessIfNeeded());
    } else if (state == AppLifecycleState.paused) {
      unawaited(
        ref.read(musicPlayerRuntimeProvider).handler?.persistCurrentSession(),
      );
    }
  }

  Future<void> _repairSafAccessIfNeeded({bool knownLost = false}) async {
    if (!Platform.isAndroid || _safRepairDialogVisible) return;

    var accessLost = knownLost;
    if (!accessLost) {
      final settings = ref.read(settingsProvider);
      if (settings.storageMode != 'saf' || settings.downloadTreeUri.isEmpty) {
        return;
      }
      accessLost = !await PlatformBridge.isSafTreeAccessible(
        settings.downloadTreeUri,
      );
    }
    if (!accessLost || !mounted) return;

    _safRepairDialogVisible = true;
    try {
      await showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          var isPickingFolder = false;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return PopScope(
                canPop: false,
                child: AppAlertDialog(
                  icon: Icon(
                    Icons.folder_off_outlined,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: Text(context.l10n.downloadFolderAccessLostTitle),
                  content: Text(context.l10n.downloadFolderAccessLostSubtitle),
                  actions: [
                    AppDialogAction(
                      onPressed: isPickingFolder
                          ? null
                          : () {
                              final notifier = ref.read(
                                settingsProvider.notifier,
                              );
                              notifier.setStorageMode('app');
                              notifier.setDownloadTreeUri('');
                              notifier.setDownloadDirectory('');
                              Navigator.of(dialogContext).pop();
                            },
                      child: Text(context.l10n.storageAutomaticFolder),
                    ),
                    AppDialogAction(
                      filled: true,
                      onPressed: isPickingFolder
                          ? null
                          : () async {
                              setDialogState(() => isPickingFolder = true);
                              try {
                                final result =
                                    await PlatformBridge.pickSafTree();
                                if (result == null) return;
                                final treeUri =
                                    result['tree_uri'] as String? ?? '';
                                final displayName =
                                    result['display_name'] as String? ?? '';
                                if (treeUri.isEmpty) return;

                                final notifier = ref.read(
                                  settingsProvider.notifier,
                                );
                                notifier.setStorageMode('saf');
                                notifier.setDownloadTreeUri(
                                  treeUri,
                                  displayName: displayName.isNotEmpty
                                      ? displayName
                                      : treeUri,
                                );
                                if (dialogContext.mounted) {
                                  Navigator.of(dialogContext).pop();
                                }
                              } catch (e) {
                                _log.w(
                                  'Failed to repair SAF access from startup: $e',
                                );
                                if (context.mounted) {
                                  showCannotOpenFileSnackBar(context, e);
                                }
                              } finally {
                                if (dialogContext.mounted) {
                                  setDialogState(() => isPickingFolder = false);
                                }
                              }
                            },
                      child: isPickingFolder
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(context.l10n.downloadFolderReselect),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    } finally {
      _safRepairDialogVisible = false;
    }
  }

  void _setupShareListener() {
    final pendingUrl = ShareIntentService().consumePendingUrl();
    if (pendingUrl != null) {
      _handleSharedUrl(pendingUrl);
    }

    _shareSubscription = ShareIntentService().sharedUrlStream.listen(
      (url) {
        _handleSharedUrl(url);
      },
      onError: (Object error) {
        _log.e('Share stream error: $error');
      },
      cancelOnError: false,
    );
  }

  Future<void> _handleSharedUrl(String url) async {
    if (!mounted) return;

    Navigator.of(context).popUntil((route) => route.isFirst);
    _onShellTabRequested(ShellTab.search);
    final searchNavigator = context.isMornye
        ? _searchTabNavigatorKey
        : _homeTabNavigatorKey;
    searchNavigator.currentState?.popUntil((route) => route.isFirst);
    // Mount the lazy Search page before the metadata listener handles the link.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    ref.read(settingsProvider.notifier).setHasSearchedBefore();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.loadingSharedLink)));
    }
    await ref.read(trackProvider.notifier).fetchFromUrl(url);
    final trackState = ref.read(trackProvider);
    if (trackState.error != null && mounted) {
      final l10n = context.l10n;
      final errorMsg = trackState.error!;
      final isRateLimit =
          errorMsg.contains('429') ||
          errorMsg.toLowerCase().contains('rate limit') ||
          errorMsg.toLowerCase().contains('too many requests');
      final displayMessage = errorMsg == 'url_not_recognized'
          ? l10n.errorUrlNotRecognizedMessage
          : isRateLimit
          ? l10n.errorRateLimitedMessage
          : l10n.errorUrlFetchFailed;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(displayMessage),
          // Retrying an unrecognized URL is deterministic; skip the action.
          action: errorMsg == 'url_not_recognized'
              ? null
              : SnackBarAction(
                  label: l10n.dialogRetry,
                  onPressed: () => _handleSharedUrl(url),
                ),
        ),
      );
    }
  }

  Future<void> _checkUpgradeIntro() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      final existingInstallation = !ref
          .read(initialSettingsProvider)
          .isFirstLaunch;
      if (UpgradeIntroService.shouldShow(
        preferences,
        version: AppInfo.version,
        existingInstallation: existingInstallation,
      )) {
        await Navigator.of(context, rootNavigator: true).push<void>(
          MaterialPageRoute(
            builder: (_) => const UpgradeIntroScreen(),
            fullscreenDialog: true,
          ),
        );
        await UpgradeIntroService.markSeen(preferences);
      } else if (!existingInstallation) {
        // Fresh installs already have their own setup tutorial.
        await UpgradeIntroService.markSeen(preferences);
      }
    } catch (error) {
      _log.w('Could not present upgrade introduction: $error');
    }
  }

  Future<bool> _checkForUpdates() async {
    if (_hasCheckedUpdate) return false;
    _hasCheckedUpdate = true;

    final settings = ref.read(settingsProvider);

    // Update checks and prompts are entirely controlled by this setting.
    if (!settings.checkForUpdates) return false;

    final updateInfo = await UpdateChecker().checkForUpdate(
      channel: settings.updateChannel,
    );
    if (updateInfo == null || !mounted) return false;

    showUpdateDialog(
      context,
      updateInfo: updateInfo,
      onDisableUpdates: () {
        ref.read(settingsProvider.notifier).setCheckForUpdates(false);
      },
    );
    return true;
  }

  Future<void> _checkAppAnnouncement() async {
    if (_hasCheckedAppAnnouncement) return;
    _hasCheckedAppAnnouncement = true;

    final locale = Localizations.localeOf(context).toLanguageTag();
    final remoteConfigService = AppRemoteConfigService();
    final announcement = await remoteConfigService.fetchActiveAnnouncement(
      locale: locale,
    );
    if (announcement == null || !mounted) return;

    showAppAnnouncementDialog(
      context,
      announcement: announcement,
      onDismiss: () {
        remoteConfigService.markAnnouncementDismissed(announcement.id);
      },
    );
  }

  static const _safMigrationShownKey = 'saf_migration_prompt_shown';

  Future<void> _checkSafMigration() async {
    if (!Platform.isAndroid) return;

    final settings = ref.read(settingsProvider);
    if (settings.storageMode == 'saf') return;
    if (settings.downloadDirectory.isEmpty) return;

    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    if (androidInfo.version.sdkInt < 29) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_safMigrationShownKey) == true) return;
    await prefs.setBool(_safMigrationShownKey, true);

    if (!mounted) return;

    final colorScheme = Theme.of(context).colorScheme;

    showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AppAlertDialog(
        icon: Icon(
          Icons.folder_special_outlined,
          size: 32,
          color: colorScheme.primary,
        ),
        title: Text(context.l10n.safMigrationTitle),
        content: ConstrainedBox(
          // Keeps the text column readable on tablets/landscape.
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.l10n.safMigrationMessage1),
              const SizedBox(height: 12),
              Text(context.l10n.safMigrationMessage2),
            ],
          ),
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.l10n.updateLater),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () async {
              Navigator.pop(ctx);
              final result = await PlatformBridge.pickSafTree();
              if (result != null) {
                final treeUri = result['tree_uri'] as String? ?? '';
                final displayName = result['display_name'] as String? ?? '';
                if (treeUri.isNotEmpty) {
                  ref
                      .read(settingsProvider.notifier)
                      .setDownloadTreeUri(
                        treeUri,
                        displayName: displayName.isNotEmpty
                            ? displayName
                            : treeUri,
                      );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(context.l10n.safMigrationSuccess)),
                    );
                  }
                }
              }
            },
            child: Text(context.l10n.setupSelectFolder),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    usbAudioStatus.removeListener(_onUsbAudioStatusChanged);
    ShellNavigationService.unregisterTabSelectionHandler(this);
    _shareSubscription?.cancel();
    _pageController.dispose();
    _tabJumpOpacity.dispose();
    _tabJumpTransitionController.dispose();
    _mornyeChrome.dispose();
    super.dispose();
  }

  void _resetHomeToMain() {
    ref.read(previewPlayerProvider.notifier).stop();
    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final homeNavigator = _navigatorForTab(0, showStore);
    homeNavigator?.popUntil((route) => route.isFirst);
    // Unfocus BEFORE clear so _onTrackStateChanged can properly
    // clear _urlController (it checks !_searchFocusNode.hasFocus)
    FocusManager.instance.primaryFocus?.unfocus();
    if (!context.isMornye) ref.read(trackProvider.notifier).clear();
  }

  void _onShellTabRequested(ShellTab tab) {
    if (tab == ShellTab.settings && context.isMornye) {
      unawaited(_openProfileSettings());
      return;
    }
    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final index = switch (tab) {
      ShellTab.home => 0,
      ShellTab.search => context.isMornye ? (showStore ? 3 : 2) : 0,
      ShellTab.library => 1,
      ShellTab.repository => showStore ? 2 : null,
      ShellTab.settings => showStore ? 3 : 2,
    };
    if (index != null) _onNavTap(index, resetHome: tab != ShellTab.search);
  }

  bool _settingsPageOpen = false;

  Future<void> _openProfileSettings() async {
    if (_settingsPageOpen) return;
    _settingsPageOpen = true;
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(previewPlayerProvider.notifier).stop();
    try {
      await Navigator.of(context).push(
        slidePageRoute<void>(
          page: const Scaffold(body: SettingsTab(asPage: true)),
        ),
      );
    } finally {
      _settingsPageOpen = false;
    }
  }

  void _onNavTap(int index, {bool resetHome = true}) {
    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    _mornyeChrome.expand();
    if (index == 0 && resetHome && (context.isMornye || _currentIndex == 0)) {
      _resetHomeToMain();
    }
    if (index == 0 && _currentIndex == 0) {
      return;
    }

    if (_currentIndex != index) {
      final previousIndex = _currentIndex;
      final isNonAdjacentJump = (previousIndex - index).abs() > 1;
      HapticFeedback.selectionClick();
      // Stop any preview snippet when leaving the current tab. (_onPageChanged
      // cannot do this because _currentIndex is already updated below.)
      ref.read(previewPlayerProvider.notifier).stop();
      setState(() => _currentIndex = index);
      ShellNavigationService.syncState(
        currentTabIndex: _currentIndex,
        showRepoTab: showStore,
        showSearchTab: context.isMornye,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      // Jump directly when skipping intermediate tabs to avoid
      // sliding through them. For those jumps, keep a short fade-in
      // so the transition still feels intentional.
      if (context.isMornye) {
        // The glass pill owns the tab transition. Sliding/fading the whole
        // page at the same time continuously invalidates its live backdrop.
        _tabJumpTransitionController.value = 1;
      } else if (isNonAdjacentJump) {
        _pageController.jumpToPage(index);
        _tabJumpTransitionController.forward(from: 0);
      } else {
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  void _onPageChanged(int index) {
    _mornyeChrome.expand();
    if (_currentIndex != index) {
      ref.read(previewPlayerProvider.notifier).stop();
      setState(() => _currentIndex = index);
      final showStore = ref.read(
        settingsProvider.select((s) => s.showExtensionStore),
      );
      ShellNavigationService.syncState(
        currentTabIndex: _currentIndex,
        showRepoTab: showStore,
        showSearchTab: context.isMornye,
      );
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  Future<void> _handleBackPress() async {
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final handledByRootNavigator = await rootNavigator.maybePop();
    if (handledByRootNavigator) {
      _lastBackPress = null;
      return;
    }

    final showStore = ref.read(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final currentNavigator = _navigatorForTab(_currentIndex, showStore);
    final handledByCurrentNavigator =
        await currentNavigator?.maybePop() ?? false;
    if (handledByCurrentNavigator) {
      _lastBackPress = null;
      return;
    }

    if (!mounted) return;

    final trackState = ref.read(trackProvider);
    final isSearchTab =
        _currentIndex == (context.isMornye ? (showStore ? 3 : 2) : 0);

    final isKeyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;

    if (isSearchTab &&
        trackState.isShowingRecentAccess &&
        !trackState.isLoading &&
        (trackState.hasSearchText || trackState.hasContent)) {
      FocusManager.instance.primaryFocus?.unfocus();
      ref.read(previewPlayerProvider.notifier).stop();
      ref.read(trackProvider.notifier).clear();
      _lastBackPress = null;
      return;
    }

    if (isSearchTab && trackState.isShowingRecentAccess) {
      ref.read(trackProvider.notifier).setShowingRecentAccess(false);
      FocusManager.instance.primaryFocus?.unfocus();
      _lastBackPress = null;
      return;
    }

    if (isSearchTab &&
        !trackState.isLoading &&
        (trackState.hasSearchText || trackState.hasContent)) {
      // Unfocus BEFORE clear so _onTrackStateChanged can properly
      // clear _urlController (it checks !_searchFocusNode.hasFocus)
      FocusManager.instance.primaryFocus?.unfocus();
      ref.read(previewPlayerProvider.notifier).stop();
      ref.read(trackProvider.notifier).clear();
      _lastBackPress = null;
      return;
    }

    if (isSearchTab && isKeyboardVisible) {
      FocusManager.instance.primaryFocus?.unfocus();
      _lastBackPress = null;
      return;
    }

    if (_currentIndex != 0) {
      _onNavTap(0);
      _lastBackPress = null;
      return;
    }

    if (isSearchTab && trackState.isLoading) {
      return;
    }

    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
      unawaited(PlatformBridge.exitApp());
    } else {
      _lastBackPress = now;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.pressBackAgainToExit),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  NavigatorState? _navigatorForTab(int index, bool showStore) {
    if (index == 0) return _homeTabNavigatorKey.currentState;
    if (index == 1) return _libraryTabNavigatorKey.currentState;
    if (showStore && index == 2) return _repoTabNavigatorKey.currentState;
    if (context.isMornye && index == (showStore ? 3 : 2)) {
      return _searchTabNavigatorKey.currentState;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(
      playbackNotificationProvider((
        favorite: context.l10n.trackOptionAddToLoved,
        unfavorite: context.l10n.trackOptionRemoveFromLoved,
        shuffleOn: context.l10n.nowPlayingShuffleOn,
        shuffleOff: context.l10n.nowPlayingPlayInOrder,
      )),
    );
    ref.listen(settingsProvider, (_, settings) {
      ref.read(musicPlayerRuntimeProvider).configure(settings);
    });
    ref.listen(settingsProvider.select((s) => s.discordRichPresenceEnabled), (
      _,
      enabled,
    ) {
      unawaited(DiscordPresenceService.instance.setEnabled(enabled));
    });
    ref.listen(
      settingsProvider.select((s) => s.listeningStatisticsEnabled),
      (_, enabled) => listeningRecorder.setEnabled(enabled),
    );
    final queueState = ref.watch(
      downloadQueueProvider.select((s) => s.queuedCount),
    );
    final showStore = ref.watch(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    final heroAnimationsEnabled = ref.watch(
      settingsProvider.select((s) => s.heroAnimationsEnabled),
    );
    ShellNavigationService.syncState(
      currentTabIndex: _currentIndex,
      showRepoTab: showStore,
      showSearchTab: context.isMornye,
    );
    final repoUpdatesCount = ref.watch(
      repoProvider.select((s) => s.updatesAvailableCount),
    );

    final tabs = <Widget>[
      _TabNavigator(
        key: const ValueKey('tab-home'),
        navigatorKey: _homeTabNavigatorKey,
        observers: [_homePreviewStopObserver],
        heroAnimationsEnabled: heroAnimationsEnabled,
        child: Builder(
          builder: (context) => HomeTab(
            mode: context.isMornye ? HomeTabMode.browse : HomeTabMode.combined,
          ),
        ),
      ),
      _TabNavigator(
        key: const ValueKey('tab-library'),
        navigatorKey: _libraryTabNavigatorKey,
        observers: [_libraryPreviewStopObserver],
        heroAnimationsEnabled: heroAnimationsEnabled,
        child: _LibraryTabRoot(
          parentPageController: _pageController,
          isTabActive: _currentIndex == 1,
        ),
      ),
      if (showStore)
        _TabNavigator(
          key: const ValueKey('tab-repo'),
          navigatorKey: _repoTabNavigatorKey,
          observers: [_repoPreviewStopObserver],
          heroAnimationsEnabled: heroAnimationsEnabled,
          child: const RepoTab(),
        ),
      if (!context.isMornye) const SettingsTab(),
      if (context.isMornye)
        _TabNavigator(
          key: const ValueKey('tab-search'),
          navigatorKey: _searchTabNavigatorKey,
          observers: [_searchPreviewStopObserver],
          heroAnimationsEnabled: heroAnimationsEnabled,
          child: const HomeTab(mode: HomeTabMode.search),
        ),
    ];

    final l10n = context.l10n;
    final destinations = <NavigationDestination>[
      NavigationDestination(
        icon: Icon(
          context.isMornye ? CupertinoIcons.house_fill : Icons.home_outlined,
        ),
        selectedIcon: BouncingIcon(child: const Icon(Icons.home)),
        label: l10n.navHome,
      ),
      NavigationDestination(
        icon: context.isMornye
            ? MornyeNavigationIcon(
                icon: CupertinoIcons.square_stack_fill,
                badgeCount: queueState,
              )
            : AnimatedBadge(
                count: queueState,
                child: Badge(
                  isLabelVisible: queueState > 0,
                  label: Text('$queueState'),
                  child: const Icon(Icons.library_music_outlined),
                ),
              ),
        selectedIcon: SlidingIcon(
          child: AnimatedBadge(
            count: queueState,
            child: Badge(
              isLabelVisible: queueState > 0,
              label: Text('$queueState'),
              child: const Icon(Icons.library_music),
            ),
          ),
        ),
        label: l10n.navLibrary,
      ),
      if (showStore)
        NavigationDestination(
          icon: context.isMornye
              ? MornyeNavigationIcon(
                  icon: CupertinoIcons.square_grid_2x2,
                  badgeCount: repoUpdatesCount,
                )
              : AnimatedBadge(
                  count: repoUpdatesCount,
                  child: Badge(
                    isLabelVisible: repoUpdatesCount > 0,
                    label: Text('$repoUpdatesCount'),
                    child: const Icon(Icons.extension_outlined),
                  ),
                ),
          selectedIcon: BouncingIcon(
            child: AnimatedBadge(
              count: repoUpdatesCount,
              child: Badge(
                isLabelVisible: repoUpdatesCount > 0,
                label: Text('$repoUpdatesCount'),
                child: const Icon(Icons.extension),
              ),
            ),
          ),
          label: l10n.navStore,
        ),
      if (!context.isMornye)
        NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: SpinIcon(child: const Icon(Icons.settings)),
          label: l10n.navSettings,
        ),
      if (context.isMornye)
        NavigationDestination(
          icon: const Icon(CupertinoIcons.search),
          label: l10n.mornyeSearch,
        ),
    ];

    final maxIndex = tabs.length - 1;
    final selectedDestination = _currentIndex.clamp(0, maxIndex);
    if (_currentIndex > maxIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _currentIndex = maxIndex);
          if (_pageController.hasClients) {
            _pageController.jumpToPage(maxIndex);
          }
        }
      });
    }

    final screenSize = MediaQuery.sizeOf(context);
    final isTablet = screenSize.shortestSide >= 600;
    // Tablets remain touch-first in both orientations. Reserving the rail for
    // desktop-width windows keeps all primary destinations at the reachable
    // bottom edge on iPad and large Android tablets.
    final useNavigationRail = useNavigationRailForWidth(screenSize.width);
    final canMinimizeChrome =
        context.isMornye &&
        !useNavigationRail &&
        MediaQuery.viewInsetsOf(context).bottom == 0 &&
        MediaQuery.textScalerOf(context).scale(15) <= 20;

    Widget observeScroll(Widget child, int index) =>
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (canMinimizeChrome && index == _currentIndex) {
              return _mornyeChrome.handleScroll(notification);
            }
            return false;
          },
          child: child,
        );

    final pageView = KeyedSubtree(
      key: _pageViewKey,
      child: context.isMornye
          ? LazyTabView(
              index: selectedDestination,
              preloadKeys: {const ValueKey('tab-search')},
              children: [
                for (var index = 0; index < tabs.length; index++)
                  KeyedSubtree(
                    key: tabs[index].key,
                    child: observeScroll(tabs[index], index),
                  ),
              ],
            )
          : FadeTransition(
              opacity: _tabJumpOpacity,
              child: ScaleTransition(
                scale: _tabJumpScale,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: tabs.length,
                  onPageChanged: _onPageChanged,
                  physics: const NeverScrollableScrollPhysics(),
                  // TickerMode mutes animations and lets visibility-aware widgets
                  // (e.g. MotionHeaderBanner) pause when their tab is hidden —
                  // kept-alive pages otherwise keep running offscreen.
                  itemBuilder: (context, index) => _KeepAliveTabPage(
                    key: ValueKey('page-$index'),
                    child: TickerMode(
                      enabled: index == _currentIndex,
                      child: observeScroll(tabs[index], index),
                    ),
                  ),
                ),
              ),
            ),
    );

    final shell = SelectionOverlayHost(
      child: BackButtonListener(
        onBackButtonPressed: () async {
          await _handleBackPress();
          return true;
        },
        child: Scaffold(
          extendBody: true,
          // The tab view keeps one element across the rail<->bar structure
          // swap via _pageViewKey so rotation doesn't remount tab navigators.
          body: useNavigationRail
              ? Row(
                  children: [
                    SafeArea(
                      right: false,
                      bottom: false,
                      // The rail needs ~300dp of height for four labeled
                      // destinations; on short viewports (landscape phone with
                      // the mini player showing) it must scroll, not overflow.
                      child: LayoutBuilder(
                        builder: (context, constraints) =>
                            SingleChildScrollView(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: constraints.maxHeight,
                                ),
                                child: IntrinsicHeight(
                                  child: NavigationRail(
                                    selectedIndex: selectedDestination,
                                    onDestinationSelected: _onNavTap,
                                    labelType: NavigationRailLabelType.all,
                                    backgroundColor: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainer,
                                    destinations: [
                                      for (final destination in destinations)
                                        NavigationRailDestination(
                                          icon: destination.icon,
                                          selectedIcon:
                                              destination.selectedIcon,
                                          label: Text(destination.label),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: pageView),
                  ],
                )
              : pageView,
          bottomNavigationBar: Builder(
            builder: (context) {
              if (context.isMornye) {
                return ListenableBuilder(
                  listenable: Listenable.merge([
                    ShellNavigationService.chromeBrightness,
                    ShellNavigationService.chromeSurface,
                  ]),
                  builder: (context, child) => Theme(
                    data: ShellNavigationService.chromeBrightness.value == null
                        ? Theme.of(context)
                        : MornyeTheme.fromContext(
                            context,
                            brightness:
                                ShellNavigationService.chromeBrightness.value!,
                            chromeSurface:
                                ShellNavigationService.chromeSurface.value,
                          ),
                    child: child!,
                  ),
                  child: SafeArea(
                    top: false,
                    minimum: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: useNavigationRail
                        ? const MiniPlayer()
                        : ValueListenableBuilder<bool>(
                            valueListenable: _mornyeChrome,
                            builder: (context, collapsed, _) => MornyeBottomBar(
                              collapsed: canMinimizeChrome && collapsed,
                              destinations: destinations,
                              selectedIndex: selectedDestination,
                              onSelected: _onNavTap,
                              onHome: () => _onNavTap(0),
                              onSearch: ShellNavigationService.requestSearch,
                              blurEnabled: ref.watch(mornyeBlurEnabledProvider),
                            ),
                          ),
                  ),
                );
              }
              final bottomBar = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MiniPlayer(),
                  if (!useNavigationRail)
                    DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: Theme.of(
                              context,
                            ).colorScheme.outlineVariant.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                      child: ExpressiveNavigationBar(
                        selectedIndex: _currentIndex.clamp(0, maxIndex),
                        onDestinationSelected: _onNavTap,
                        isTablet: isTablet,
                        backgroundColor: settingsGroupColor(
                          context,
                        ).withValues(alpha: 0.72),
                        destinations: destinations,
                      ),
                    ),
                ],
              );
              // The backdrop blur re-filters everything scrolling underneath on
              // every frame; low-end devices get an opaque base instead unless
              // the user forces blur on in appearance settings.
              if (!ref.watch(backdropBlurEnabledProvider)) {
                return ColoredBox(
                  color: settingsGroupColor(context),
                  child: bottomBar,
                );
              }
              return ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  blendMode: BlendMode.src,
                  child: bottomBar,
                ),
              );
            },
          ),
        ),
      ),
    );
    return DownloadQueueFeedback(child: shell);
  }
}

class _TabNavigator extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  final List<NavigatorObserver> observers;
  final bool heroAnimationsEnabled;

  const _TabNavigator({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.observers = const [],
    required this.heroAnimationsEnabled,
  });

  @override
  State<_TabNavigator> createState() => _TabNavigatorState();
}

class _TabNavigatorState extends State<_TabNavigator> {
  late final ShellChromeObserver _chromeObserver = ShellChromeObserver(
    widget.navigatorKey,
  );
  // Nested navigators get no HeroController from MaterialApp; without one,
  // Hero widgets on routes pushed inside a tab never fly.
  final HeroController _heroController =
      MaterialApp.createMaterialHeroController();

  @override
  void dispose() {
    _chromeObserver.detach();
    _heroController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: widget.navigatorKey,
      observers: [
        _chromeObserver,
        if (widget.heroAnimationsEnabled) _heroController,
        ...widget.observers,
      ],
      onGenerateInitialRoutes: (_, _) => [
        MaterialPageRoute<void>(builder: (_) => widget.child),
      ],
    );
  }
}

class _PreviewStopNavigatorObserver extends NavigatorObserver {
  _PreviewStopNavigatorObserver(this._onNavigate);

  final VoidCallback _onNavigate;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (previousRoute != null) {
      _onNavigate();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _onNavigate();
  }
}

class _LibraryTabRoot extends ConsumerWidget {
  final PageController parentPageController;
  final bool isTabActive;

  const _LibraryTabRoot({
    required this.parentPageController,
    required this.isTabActive,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showStore = ref.watch(
      settingsProvider.select((s) => s.showExtensionStore),
    );
    return QueueTab(
      isTabActive: isTabActive,
      parentPageController: parentPageController,
      parentPageIndex: 1,
      nextPageIndex: showStore ? 2 : 3,
    );
  }
}

class _KeepAliveTabPage extends StatefulWidget {
  final Widget child;

  const _KeepAliveTabPage({super.key, required this.child});

  @override
  State<_KeepAliveTabPage> createState() => _KeepAliveTabPageState();
}

class _KeepAliveTabPageState extends State<_KeepAliveTabPage>
    with AutomaticKeepAliveClientMixin<_KeepAliveTabPage> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class BouncingIcon extends StatefulWidget {
  final Widget child;
  const BouncingIcon({super.key, required this.child});

  @override
  State<BouncingIcon> createState() => _BouncingIconState();
}

class _BouncingIconState extends State<BouncingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 0.1,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.elasticOut));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scaleAnimation, child: widget.child);
  }
}

class SlidingIcon extends StatefulWidget {
  final Widget child;
  const SlidingIcon({super.key, required this.child});

  @override
  State<SlidingIcon> createState() => _SlidingIconState();
}

class _SlidingIconState extends State<SlidingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _offsetAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    _offsetAnimation = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(position: _offsetAnimation, child: widget.child),
    );
  }
}

class SpinIcon extends StatefulWidget {
  final Widget child;
  const SpinIcon({super.key, required this.child});

  @override
  State<SpinIcon> createState() => _SpinIconState();
}

class _SpinIconState extends State<SpinIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _rotationAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _rotationAnimation = Tween<double>(
      begin: 0.0,
      end: 0.5,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(turns: _rotationAnimation, child: widget.child);
  }
}
