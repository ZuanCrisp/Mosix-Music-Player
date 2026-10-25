import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';
import 'package:mosix/widgets/app_snack_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:go_router/go_router.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/constants/language_choices.dart';
import 'package:mosix/services/platform_bridge.dart';
import 'package:mosix/utils/adaptive_layout.dart';
import 'package:mosix/utils/file_access.dart';
import 'package:mosix/widgets/scroll_edge_fade.dart';
import 'package:mosix/utils/logger.dart';

final _log = AppLogger('SetupScreen');

// Height of the back-button/progress header row above the PageView
// (16 vertical padding * 2 + 48 button).
const _headerHeight = 80.0;

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen>
    with WidgetsBindingObserver {
  static const _progressKey = 'setup_progress_v1';
  final _prefs = SharedPreferences.getInstance();
  final _platform = defaultTargetPlatform;
  PageController? _pageController;
  final ScrollController _languageScrollController = ScrollController();
  late final Future<void> _initialization;
  StreamSubscription<void>? _folderSelectionSubscription;
  Future<void>? _folderRecovery;
  bool _initializing = true;
  int _currentStep = 0;

  String _selectedLocale = 'system';
  bool _storagePermissionGranted = false;
  bool _notificationPermissionGranted = false;
  bool _notificationPermissionSkipped = false;
  String? _selectedDirectory;
  String? _selectedDirectoryBookmark;
  String? _selectedTreeUri;
  bool _isLoading = false;
  int _androidSdkVersion = 0;

  int get _totalSteps => _androidSdkVersion >= 33 ? 5 : 4;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialization = _initDeviceInfo();
    if (_platform == TargetPlatform.android) {
      _folderSelectionSubscription = PlatformBridge.setupFolderSelectionEvents()
          .listen((_) => unawaited(_refreshAfterResume()));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_folderSelectionSubscription?.cancel());
    _pageController?.dispose();
    _languageScrollController.dispose();
    super.dispose();
  }

  Future<void> _initDeviceInfo() async {
    try {
      await ref.read(settingsProvider.notifier).ensureLoaded();
      if (_platform == TargetPlatform.android) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        _androidSdkVersion = androidInfo.version.sdkInt;
      }
      final prefs = await _prefs;
      if (!mounted) return;
      _selectedLocale = ref.read(settingsProvider).locale;
      final saved = prefs.getString(_progressKey);
      if (saved != null) {
        final draft = jsonDecode(saved) as Map<String, dynamic>;
        _currentStep = ((draft['step'] as int?) ?? 0).clamp(0, _totalSteps - 1);
        _selectedDirectory = draft['directory'] as String?;
        _selectedDirectoryBookmark = draft['bookmark'] as String?;
        _selectedTreeUri = draft['treeUri'] as String?;
        _notificationPermissionSkipped = draft['skipNotifications'] == true;
      }
      await _checkInitialPermissions();
      if (_platform == TargetPlatform.android) await _restoreSelectedFolder();
    } catch (e, stack) {
      _log.e('Failed to restore setup progress', e, stack);
    } finally {
      if (mounted) {
        _pageController = PageController(initialPage: _currentStep);
        setState(() => _initializing = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshAfterResume());
    }
  }

  Future<void> _refreshAfterResume() async {
    await _initialization;
    if (!mounted) return;
    try {
      await _checkInitialPermissions();
      if (_platform == TargetPlatform.android) await _restoreSelectedFolder();
    } catch (e, stack) {
      _log.e('Failed to refresh setup permissions', e, stack);
    }
  }

  Future<void> _saveProgress({int? step}) async {
    final draft = jsonEncode({
      'step': step ?? _currentStep,
      'directory': _selectedDirectory,
      'bookmark': _selectedDirectoryBookmark,
      'treeUri': _selectedTreeUri,
      'skipNotifications': _notificationPermissionSkipped,
    });
    if (!await (await _prefs).setString(_progressKey, draft)) {
      throw StateError('Could not save setup progress');
    }
  }

  Future<void> _restoreSelectedFolder() => _folderRecovery ??=
      _readSelectedFolder().whenComplete(() => _folderRecovery = null);

  Future<void> _readSelectedFolder() async {
    final payload = await PlatformBridge.readSetupFolderSelection();
    if (payload == null || !mounted) return;
    final result = jsonDecode(payload) as Map<String, dynamic>;
    final uri = result['tree_uri'] as String? ?? '';
    if (uri.isNotEmpty) {
      final name = result['display_name'] as String? ?? '';
      setState(() {
        _selectedTreeUri = uri;
        _selectedDirectory = name.isEmpty ? uri : name;
      });
      await _saveProgress();
    }
    // Acknowledge only after the recovered selection is durable in Dart.
    await PlatformBridge.acknowledgeSetupFolderSelection(payload);
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _checkInitialPermissions() async {
    if (_platform == TargetPlatform.iOS) {
      final notificationStatus = await Permission.notification.status;
      if (mounted) {
        setState(() {
          _storagePermissionGranted = true;
          _notificationPermissionGranted =
              notificationStatus.isGranted || notificationStatus.isProvisional;
        });
      }
    } else if (_platform == TargetPlatform.android) {
      bool storageGranted = false;

      if (_androidSdkVersion >= 33) {
        final audioStatus = await Permission.audio.status;
        storageGranted = audioStatus.isGranted;
      } else if (_androidSdkVersion >= 30) {
        final manageStatus = await Permission.manageExternalStorage.status;
        storageGranted = manageStatus.isGranted;
      } else {
        final storageStatus = await Permission.storage.status;
        storageGranted = storageStatus.isGranted;
      }

      PermissionStatus notificationStatus = PermissionStatus.granted;
      if (_androidSdkVersion >= 33) {
        notificationStatus = await Permission.notification.status;
      }

      if (mounted) {
        setState(() {
          _storagePermissionGranted = storageGranted;
          _notificationPermissionGranted = notificationStatus.isGranted;
        });
      }
    } else {
      setState(() {
        _storagePermissionGranted = true;
        _notificationPermissionGranted = true;
      });
    }
  }

  Future<void> _requestStoragePermission() async {
    if (_isLoading) return;
    final permissionAudio = context.l10n.permissionAudio;
    final permissionStorage = context.l10n.permissionStorage;
    setState(() => _isLoading = true);
    try {
      await _saveProgress();
      if (!mounted) return;
      if (_platform == TargetPlatform.iOS) {
        setState(() => _storagePermissionGranted = true);
      } else if (_platform == TargetPlatform.android) {
        bool allGranted = false;

        if (_androidSdkVersion >= 33) {
          var audioStatus = await Permission.audio.status;
          if (!audioStatus.isGranted) {
            audioStatus = await Permission.audio.request();
          }
          allGranted = audioStatus.isGranted;

          if (audioStatus.isPermanentlyDenied) {
            await _showPermissionDeniedDialog(permissionAudio);
            return;
          }
        } else if (_androidSdkVersion >= 30) {
          var manageStatus = await Permission.manageExternalStorage.status;
          if (!manageStatus.isGranted) {
            final shouldOpen = await _showAndroid11StorageDialog();
            if (shouldOpen == true) {
              await Permission.manageExternalStorage.request();
              await Future<void>.delayed(const Duration(milliseconds: 500));
              manageStatus = await Permission.manageExternalStorage.status;
            }
          }
          allGranted = manageStatus.isGranted;
        } else {
          final status = await Permission.storage.request();
          allGranted = status.isGranted;
          if (status.isPermanentlyDenied) {
            await _showPermissionDeniedDialog(permissionStorage);
            return;
          }
        }

        if (!mounted) return;
        setState(() => _storagePermissionGranted = allGranted);
        if (!allGranted && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.setupPermissionDeniedMessage)),
          );
        }
      } else {
        setState(() => _storagePermissionGranted = true);
      }
    } catch (e) {
      debugPrint('Permission error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool?> _showAndroid11StorageDialog() {
    return showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.setupStorageAccessRequired),
        content: Text(
          '${context.l10n.setupStorageAccessMessageAndroid11}\n\n'
          '${context.l10n.setupAllowAccessToManageFiles}',
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.setupOpenSettings),
          ),
        ],
      ),
    );
  }

  Future<void> _requestNotificationPermission() async {
    if (_isLoading) return;
    final permissionNotification = context.l10n.permissionNotification;
    setState(() => _isLoading = true);
    try {
      await _saveProgress();
      if (!mounted) return;
      if (_platform == TargetPlatform.iOS) {
        final status = await Permission.notification.request();
        if (!mounted) return;
        if (status.isGranted || status.isProvisional) {
          setState(() => _notificationPermissionGranted = true);
        } else if (status.isPermanentlyDenied) {
          await _showPermissionDeniedDialog(permissionNotification);
        }
      } else if (_androidSdkVersion >= 33) {
        final status = await Permission.notification.request();
        if (!mounted) return;
        if (status.isGranted) {
          setState(() => _notificationPermissionGranted = true);
        } else if (status.isPermanentlyDenied) {
          await _showPermissionDeniedDialog(permissionNotification);
        }
      } else {
        setState(() => _notificationPermissionGranted = true);
      }
    } catch (e, stack) {
      _log.e('Failed to request notification permission', e, stack);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showPermissionDeniedDialog(String permissionType) async {
    await showAppDialog<void>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.setupPermissionRequired(permissionType)),
        content: Text(
          context.l10n.setupPermissionRequiredMessage(permissionType),
        ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: Text(context.l10n.setupOpenSettings),
          ),
        ],
      ),
    );
  }

  Future<void> _selectDirectory() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      // Persist before leaving Flutter: the OS may destroy this screen while
      // the external picker is visible, including on Android 13 devices.
      await _saveProgress();
      if (!mounted) return;
      if (_platform == TargetPlatform.iOS) {
        await _showIOSDirectoryOptions();
      } else if (_platform == TargetPlatform.android) {
        Map<String, dynamic>? result;
        try {
          result = await PlatformBridge.pickSafTree(forSetup: true);
        } catch (e) {
          _log.w('Failed to open Android SAF picker: $e');
          if (mounted) showCannotOpenFileSnackBar(context, e);
        }
        if (!mounted) return;
        if (result != null) {
          final treeUri = result['tree_uri'] as String? ?? '';
          final displayName = result['display_name'] as String? ?? '';
          if (treeUri.isNotEmpty) {
            setState(() {
              _selectedTreeUri = treeUri;
              _selectedDirectory = displayName.isNotEmpty
                  ? displayName
                  : treeUri;
            });
            await _saveProgress();
          }
        }
        await _restoreSelectedFolder();
        if (!mounted) return;

        // Android fallback if user cancelled SAF picker
        if (_selectedTreeUri == null || _selectedTreeUri!.isEmpty) {
          final defaultDir = await _getDefaultDirectory();
          if (mounted) {
            final useDefault = await showAppDialog<bool>(
              context: context,
              builder: (context) => AppAlertDialog(
                title: Text(context.l10n.setupUseDefaultFolder),
                content: Text(
                  '${context.l10n.setupNoFolderSelected}\n\n$defaultDir',
                ),
                actions: [
                  AppDialogAction(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(context.l10n.dialogCancel),
                  ),
                  AppDialogAction(
                    filled: true,
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(context.l10n.setupUseDefault),
                  ),
                ],
              ),
            );
            if (useDefault == true) {
              if (!mounted) return;
              setState(() {
                _selectedTreeUri = '';
                _selectedDirectory = defaultDir;
              });
              await _saveProgress();
            }
          }
        }
      }
    } catch (e, stack) {
      _log.e('Failed to select setup folder', e, stack);
      if (mounted) showCannotOpenFileSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showIOSDirectoryOptions() async {
    final colorScheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Text(
                context.l10n.setupDownloadLocationTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text(
                context.l10n.setupDownloadLocationIosMessage,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.folder_special, color: colorScheme.primary),
              title: Text(context.l10n.setupAppDocumentsFolder),
              onTap: () async {
                final dir = await _getDefaultDirectory();
                if (!mounted) return;
                setState(() {
                  _selectedDirectory = dir;
                  _selectedDirectoryBookmark = null;
                });
                if (ctx.mounted) Navigator.pop(ctx);
                await _saveProgress();
              },
            ),
            ListTile(
              leading: Icon(Icons.cloud, color: colorScheme.onSurfaceVariant),
              title: Text(context.l10n.setupChooseFromFiles),
              onTap: () async {
                Navigator.pop(ctx);
                await Future<void>.delayed(const Duration(milliseconds: 250));

                IosPickedDirectory? picked;
                try {
                  picked = await PlatformBridge.pickIosDirectory();
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          context.l10n.snackbarFolderPickerFailed(
                            context.friendlyError(e),
                          ),
                        ),
                        backgroundColor: Theme.of(context).colorScheme.error,
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  }
                  return;
                }

                if (picked == null) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(context.l10n.setupNoFolderSelected),
                      ),
                    );
                  }
                  return;
                }

                final validation = validateIosPath(
                  picked.path,
                  bookmark: picked.bookmark,
                );
                if (!validation.isValid) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          validation.errorReason ??
                              context.l10n.errorInvalidFolderSelected,
                        ),
                        backgroundColor: Theme.of(context).colorScheme.error,
                        duration: const Duration(seconds: 4),
                      ),
                    );
                  }
                  return;
                }

                final pickedDir = picked;
                if (!mounted) return;
                setState(() {
                  _selectedDirectory = pickedDir.path;
                  _selectedDirectoryBookmark = pickedDir.bookmark;
                });
                await _saveProgress();
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Future<String> _getDefaultDirectory() async {
    if (_platform == TargetPlatform.android) {
      final downloadDir = Directory('/storage/emulated/0/Download/Mosix');
      try {
        if (!await downloadDir.exists()) {
          await downloadDir.create(recursive: true);
        }
        return downloadDir.path;
      } catch (e) {
        debugPrint('Cannot create Download folder: $e');
      }
    }
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/Mosix';
  }

  Future<void> _completeSetup() async {
    if (_selectedDirectory == null) return;
    setState(() => _isLoading = true);

    try {
      if (_platform != TargetPlatform.android ||
          _selectedTreeUri == null ||
          _selectedTreeUri!.isEmpty) {
        final iosBookmark = _platform == TargetPlatform.iOS
            ? _selectedDirectoryBookmark
            : null;
        if (iosBookmark == null || iosBookmark.isEmpty) {
          final dir = Directory(_selectedDirectory!);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
        }
        ref.read(settingsProvider.notifier).setStorageMode('app');
        ref
            .read(settingsProvider.notifier)
            .setDownloadDirectory(
              _selectedDirectory!,
              iosBookmark: iosBookmark,
            );
        ref.read(settingsProvider.notifier).setDownloadTreeUri('');
      } else {
        ref.read(settingsProvider.notifier).setStorageMode('saf');
        ref
            .read(settingsProvider.notifier)
            .setDownloadTreeUri(
              _selectedTreeUri!,
              displayName: _selectedDirectory,
            );
      }

      await ref.read(settingsProvider.notifier).setFirstLaunchComplete();
      await (await _prefs).remove(_progressKey);

      if (mounted) context.go('/tutorial');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.snackbarError(context.friendlyError(e))),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _nextPage() {
    bool canProceed = false;
    if (_currentStep == 0) {
      canProceed = true;
    } else {
      canProceed = _isStepCompleted(_currentStep);
    }

    if (canProceed) {
      unawaited(_goToStep(_currentStep + 1));
    }
  }

  void _prevPage() {
    unawaited(_goToStep(_currentStep - 1));
  }

  Future<void> _goToStep(int step) async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    try {
      await _saveProgress(step: step);
      if (!mounted) return;
      setState(() => _currentStep = step);
      await _pageController?.animateToPage(
        step,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } catch (e, stack) {
      _log.e('Failed to save setup step', e, stack);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  bool _isStepCompleted(int step) {
    if (step == 0) return true;
    if (step == 1) return true;

    final logicStep = step - 2;

    if (_androidSdkVersion >= 33) {
      switch (logicStep) {
        case 0:
          return _storagePermissionGranted;
        case 1:
          return _notificationPermissionGranted ||
              _notificationPermissionSkipped;
        case 2:
          return _selectedDirectory != null;
      }
    } else {
      switch (logicStep) {
        case 0:
          return _storagePermissionGranted;
        case 1:
          return _selectedDirectory != null;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final progress = (_currentStep + 1) / _totalSteps;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  if (_currentStep > 0)
                    IconButton.filledTonal(
                      onPressed: _prevPage,
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      icon: const Icon(Icons.arrow_back),
                      style: IconButton.styleFrom(
                        backgroundColor: colorScheme.surfaceContainerHighest,
                        foregroundColor: colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    const SizedBox(width: 48),
                  const Spacer(),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 4,
                          backgroundColor: colorScheme.surfaceContainerHighest,
                          color: colorScheme.primary,
                          strokeCap: StrokeCap.round,
                        ),
                        Center(
                          child: Text(
                            '${_currentStep + 1}/$_totalSteps',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildWelcomeStep(colorScheme),
                  _buildLanguageStep(colorScheme),
                  _buildStorageStep(colorScheme),
                  if (_androidSdkVersion >= 33)
                    _buildNotificationStep(colorScheme),
                  _buildDirectoryStep(colorScheme),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: _currentStep < _totalSteps - 1
          ? FloatingActionButton.extended(
              onPressed: !_isLoading && _isStepCompleted(_currentStep)
                  ? _nextPage
                  : null,
              label: Row(
                children: [
                  Text(context.l10n.setupNext),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward),
                ],
              ),
              icon: const SizedBox.shrink(), // Custom layout
            )
          : FloatingActionButton.extended(
              onPressed: _isLoading ? null : _completeSetup,
              label: _isLoading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: colorScheme.onPrimary,
                      ),
                    )
                  : Text(context.l10n.setupGetStarted),
              icon: const Icon(Icons.check),
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
            ),
    );
  }

  Widget _buildWelcomeStep(ColorScheme colorScheme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final textScale = MediaQuery.textScalerOf(
          context,
        ).scale(1.0).clamp(1.0, 1.4);
        final logoSize = (shortestSide * 0.24).clamp(80.0, 104.0);
        final titleGap = (shortestSide * 0.06).clamp(16.0, 32.0);
        final subtitleGap = (shortestSide * 0.04).clamp(8.0, 16.0);
        const totalPadding = 48.0 + _headerHeight;
        final minContentHeight = constraints.maxHeight > totalPadding
            ? constraints.maxHeight - totalPadding
            : 0.0;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24 + _headerHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: minContentHeight,
                maxWidth: 560,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/logo-transparent.png',
                    width: logoSize,
                    height: logoSize,
                    color: colorScheme.primary,
                    fit: BoxFit.contain,
                  ),
                  SizedBox(height: titleGap),
                  Text(
                    context.l10n.appName,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                      fontSize:
                          (Theme.of(context).textTheme.displaySmall?.fontSize ??
                              36) *
                          (1 + ((textScale - 1) * 0.18)),
                    ),
                  ),
                  SizedBox(height: subtitleGap),
                  Text(
                    context.l10n.setupDownloadInFlac,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _onLanguageSelected(String locale) {
    setState(() => _selectedLocale = locale);
    ref.read(settingsProvider.notifier).setLocale(locale);
  }

  Widget _buildLanguageStep(ColorScheme colorScheme) {
    final languages = supportedLanguageChoices;

    return LayoutBuilder(
      builder: (context, constraints) {
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final iconPadding = (shortestSide * 0.06).clamp(16.0, 24.0);
        final iconSize = (shortestSide * 0.12).clamp(32.0, 48.0);
        final titleGap = (shortestSide * 0.06).clamp(16.0, 32.0);
        final descriptionGap = (shortestSide * 0.04).clamp(8.0, 16.0);
        final actionGap = (shortestSide * 0.09).clamp(20.0, 48.0);

        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                24 + wideListInset(context, contentMaxWidth: 560),
                24,
                24 + wideListInset(context, contentMaxWidth: 560),
                0,
              ),
              child: Column(
                children: [
                  Container(
                    padding: EdgeInsets.all(iconPadding),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.translate,
                      size: iconSize,
                      color: colorScheme.primary,
                    ),
                  ),
                  SizedBox(height: titleGap),
                  Text(
                    context.l10n.setupLanguageTitle,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: descriptionGap),
                  Text(
                    context.l10n.setupLanguageDescription,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: actionGap),
                ],
              ),
            ),
            Expanded(
              child: ScrollEdgeFade(
                child: Scrollbar(
                  controller: _languageScrollController,
                  thumbVisibility: true,
                  child: _buildLanguageList(languages, colorScheme),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLanguageList(
    List<(String, String, IconData)> languages,
    ColorScheme colorScheme,
  ) {
    return ListView.builder(
      controller: _languageScrollController,
      padding: EdgeInsets.fromLTRB(
        24 + wideListInset(context, contentMaxWidth: 560),
        0,
        24 + wideListInset(context, contentMaxWidth: 560),
        80,
      ),
      itemCount: languages.length,
      itemBuilder: (context, index) {
        final lang = languages[index];
        final code = lang.$1;
        final name = lang.$2;
        final isSelected = _selectedLocale == code;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Material(
            color: isSelected
                ? colorScheme.primaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _onLanguageSelected(code),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      lang.$3,
                      color: isSelected
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        code == 'system'
                            ? context.l10n.setupLanguageSystemDefault
                            : name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: isSelected
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (isSelected)
                      Icon(
                        Icons.check_circle,
                        color: colorScheme.onPrimaryContainer,
                        size: 22,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStorageStep(ColorScheme colorScheme) {
    return _StepLayout(
      title: context.l10n.setupStorageRequired,
      description: context.l10n.setupStorageDescription,
      icon: Icons.folder,
      child: _storagePermissionGranted
          ? _SuccessCard(
              text: context.l10n.setupStorageGranted,
              colorScheme: colorScheme,
            )
          : FilledButton.tonalIcon(
              onPressed: _requestStoragePermission,
              icon: const Icon(Icons.folder_open),
              label: Text(context.l10n.setupGrantPermission),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
            ),
    );
  }

  Widget _buildNotificationStep(ColorScheme colorScheme) {
    return _StepLayout(
      title: context.l10n.setupNotificationEnable,
      description: context.l10n.setupNotificationBackgroundDescription,
      icon: Icons.notifications,
      child: _notificationPermissionGranted || _notificationPermissionSkipped
          ? _SuccessCard(
              text: context.l10n.setupNotificationGranted,
              colorScheme: colorScheme,
            )
          : Column(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _requestNotificationPermission,
                  icon: const Icon(Icons.notifications_active),
                  label: Text(context.l10n.setupEnableNotifications),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    setState(() => _notificationPermissionSkipped = true);
                    await _saveProgress();
                  },
                  child: Text(context.l10n.setupSkipForNow),
                ),
              ],
            ),
    );
  }

  Widget _buildDirectoryStep(ColorScheme colorScheme) {
    return _StepLayout(
      title: context.l10n.setupFolderChoose,
      description: _platform == TargetPlatform.android
          ? context.l10n.storageDownloadFolderHint
          : context.l10n.setupFolderDescription,
      icon: Icons.create_new_folder,
      child: Column(
        children: [
          if (_selectedDirectory != null)
            Card(
              color: colorScheme.secondaryContainer,
              child: ListTile(
                leading: Icon(
                  Icons.folder,
                  color: colorScheme.onSecondaryContainer,
                ),
                title: Text(
                  _selectedDirectory!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: context.l10n.setupChangeFolderTooltip,
                  icon: const Icon(Icons.edit),
                  onPressed: _selectDirectory,
                ),
              ),
            )
          else
            FilledButton.tonalIcon(
              onPressed: _selectDirectory,
              icon: const Icon(Icons.create_new_folder),
              label: Text(context.l10n.setupSelectFolder),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StepLayout extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final Widget child;

  const _StepLayout({
    required this.title,
    required this.description,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final iconPadding = (shortestSide * 0.06).clamp(16.0, 24.0);
        final iconSize = (shortestSide * 0.12).clamp(32.0, 48.0);
        final titleGap = (shortestSide * 0.06).clamp(16.0, 32.0);
        final descriptionGap = (shortestSide * 0.04).clamp(8.0, 16.0);
        final actionGap = (shortestSide * 0.09).clamp(20.0, 48.0);
        // Extra bottom padding offsets the 80dp header above the PageView so
        // the content sits at the optical center of the full screen.
        const totalPadding = 48.0 + _headerHeight;
        final minContentHeight = constraints.maxHeight > totalPadding
            ? constraints.maxHeight - totalPadding
            : 0.0;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24 + _headerHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: minContentHeight,
                maxWidth: 560,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(iconPadding),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      size: iconSize,
                      color: colorScheme.primary,
                    ),
                  ),
                  SizedBox(height: titleGap),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: descriptionGap),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: actionGap),
                  child,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SuccessCard extends StatelessWidget {
  final String text;
  final ColorScheme colorScheme;

  const _SuccessCard({required this.text, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: colorScheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: colorScheme.onPrimaryContainer,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
