import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';
import 'package:mosix/widgets/app_switch.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/providers/download_history_provider.dart';
import 'package:mosix/providers/local_library_provider.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/services/platform_bridge.dart';
import 'package:mosix/utils/adaptive_layout.dart';
import 'package:mosix/widgets/duplicate_review_sheet.dart';
import 'package:mosix/widgets/app_bottom_sheet.dart';
import 'package:mosix/widgets/settings_group.dart';
import 'package:mosix/widgets/app_sliver_header.dart';
import 'package:mosix/widgets/ios_library_folder_sheet.dart';

class LibrarySettingsPage extends ConsumerStatefulWidget {
  const LibrarySettingsPage({super.key});

  @override
  ConsumerState<LibrarySettingsPage> createState() =>
      _LibrarySettingsPageState();
}

class _LibrarySettingsPageState extends ConsumerState<LibrarySettingsPage> {
  int _androidSdkVersion = 0;
  bool _hasStoragePermission = false;
  bool _isCleaningMissingFiles = false;

  String _getDisplayPath(String path) {
    if (!path.startsWith('content://')) return path;
    try {
      final uri = Uri.parse(path);
      final treePath = uri.pathSegments.last;
      final decoded = Uri.decodeComponent(treePath);
      if (decoded.startsWith('primary:')) {
        return '/storage/emulated/0/${decoded.substring('primary:'.length)}';
      }
      return decoded;
    } catch (_) {
      return path;
    }
  }

  @override
  void initState() {
    super.initState();
    _initDeviceInfo();
  }

  Future<void> _initDeviceInfo() async {
    if (Platform.isAndroid) {
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final sdkVersion = androidInfo.version.sdkInt;

      if (mounted) {
        setState(() {
          _androidSdkVersion = sdkVersion;
          _hasStoragePermission = sdkVersion >= 29 ? true : false;
        });
        if (sdkVersion < 29) {
          final hasPermission = await Permission.storage.isGranted;
          if (mounted) {
            setState(() => _hasStoragePermission = hasPermission);
          }
        }
      }
    } else if (Platform.isIOS) {
      setState(() => _hasStoragePermission = true);
    } else {
      setState(() => _hasStoragePermission = true);
    }
  }

  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (_androidSdkVersion >= 29) return true;

    final status = await Permission.storage.request();

    if (status.isGranted) {
      setState(() => _hasStoragePermission = true);
      return true;
    } else if (status.isPermanentlyDenied) {
      if (mounted) {
        final shouldOpen = await showAppDialog<bool>(
          context: context,
          builder: (context) => AppAlertDialog(
            title: Text(context.l10n.libraryStorageAccessRequired),
            content: Text(context.l10n.libraryStorageAccessMessage),
            actions: [
              AppDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.l10n.dialogCancel),
              ),
              AppDialogAction(
                filled: true,
                isDefault: true,
                onPressed: () => Navigator.pop(context, true),
                child: Text(context.l10n.setupOpenSettings),
              ),
            ],
          ),
        );
        if (shouldOpen == true) {
          await openAppSettings();
        }
      }
    }
    return false;
  }

  Future<void> _pickLibraryFolder() async {
    if (Platform.isAndroid && _androidSdkVersion >= 29) {
      // Use SAF tree picker - no MANAGE_EXTERNAL_STORAGE needed
      final result = await PlatformBridge.pickSafTree();
      if (result != null) {
        final treeUri = result['tree_uri'] as String? ?? '';
        if (treeUri.isNotEmpty) {
          final source = await ref
              .read(localLibraryProvider.notifier)
              .addSource(
                path: treeUri,
                displayName:
                    result['display_name'] as String? ??
                    _getDisplayPath(treeUri),
                volumeId: result['volume_id'] as String?,
                isRemovable: result['is_removable'] == true,
              );
          await ref
              .read(localLibraryProvider.notifier)
              .startSourceScan(source.id);
        }
      }
    } else {
      // Older Android needs storage permission; iOS chooses internal or Files.
      if (!_hasStoragePermission) {
        final granted = await _requestStoragePermission();
        if (!granted) return;
      }
      if (Platform.isIOS) {
        if (!mounted) return;
        IosPickedDirectory? picked;
        try {
          picked = await showIosLibraryFolderSheet(context);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  context.l10n.snackbarFolderPickerFailed(
                    context.friendlyError(e),
                  ),
                ),
              ),
            );
          }
          return;
        }
        if (picked != null && mounted) {
          final library = ref.read(localLibraryProvider.notifier);
          final source = await library.addSource(
            path: picked.path,
            displayName: picked.bookmark.isEmpty
                ? context.l10n.setupAppDocumentsFolder
                : picked.path,
            bookmark: picked.bookmark,
          );
          await library.startSourceScan(source.id);
        }
        return;
      }
      final result = await FilePicker.getDirectoryPath();
      if (result != null) {
        final source = await ref
            .read(localLibraryProvider.notifier)
            .addSource(path: result, displayName: result);
        await ref
            .read(localLibraryProvider.notifier)
            .startSourceScan(source.id);
      }
    }
  }

  Future<void> _startScan({bool forceFullScan = false}) async {
    final sources = ref.read(localLibraryProvider).sources;
    if (sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.libraryScanSelectFolderFirst)),
      );
      return;
    }
    await ref
        .read(localLibraryProvider.notifier)
        .scanAllSources(forceFullScan: forceFullScan);
  }

  Future<void> _cancelScan() async {
    await ref.read(localLibraryProvider.notifier).cancelScan();
  }

  Future<void> _pauseScan() async {
    await ref.read(localLibraryProvider.notifier).pauseScan();
  }

  Future<void> _resumeScan() async {
    await ref.read(localLibraryProvider.notifier).resumeScan();
  }

  Future<void> _clearLibrary() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.libraryClearConfirmTitle),
        content: Text(context.l10n.libraryClearConfirmMessage),
        actions: [
          AppDialogAction(
            isDefault: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            isDestructive: true,
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(context.l10n.dialogClear),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(localLibraryProvider.notifier).clearLibrary();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.libraryCleared)));
      }
    }
  }

  Future<void> _cleanupMissingFiles() async {
    if (_isCleaningMissingFiles || ref.read(localLibraryProvider).isScanning) {
      return;
    }
    final library = ref.read(localLibraryProvider.notifier);
    final downloads = ref.read(downloadHistoryProvider.notifier);
    setState(() => _isCleaningMissingFiles = true);
    try {
      final missingLibraryEntries = await library.cleanupMissingFiles();
      final orphanedDownloads = await downloads.cleanupOrphanedDownloads();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.libraryRemovedMissingFiles(
              missingLibraryEntries + orphanedDownloads,
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.snackbarError(context.friendlyError(error)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isCleaningMissingFiles = false);
    }
  }

  Future<void> _removeSource(LocalLibrarySource source) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.libraryRemoveFolder),
        content: Text(context.l10n.libraryRemoveFolderMessage),
        actions: [
          AppDialogAction(
            isDefault: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            isDestructive: true,
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(context.l10n.dialogRemove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(localLibraryProvider.notifier).removeSource(source.id);
    final settings = ref.read(settingsProvider);
    if (settings.localLibraryPath == source.path) {
      ref
          .read(settingsProvider.notifier)
          .setLocalLibraryPathAndBookmark('', '');
    }
  }

  String _getAutoScanLabel(BuildContext context, String mode) {
    switch (mode) {
      case 'on_open':
        return context.l10n.libraryAutoScanOnOpen;
      case 'daily':
        return context.l10n.libraryAutoScanDaily;
      case 'weekly':
        return context.l10n.libraryAutoScanWeekly;
      default:
        return context.l10n.libraryAutoScanOff;
    }
  }

  void _showAutoScanPicker(BuildContext context, String current) {
    final colorScheme = Theme.of(context).colorScheme;
    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Text(
                context.l10n.libraryAutoScan,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text(
                context.l10n.libraryAutoScanSubtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            _AutoScanOption(
              icon: Icons.block,
              title: context.l10n.libraryAutoScanOff,
              selected: current == 'off',
              colorScheme: colorScheme,
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setLocalLibraryAutoScan('off');
                Navigator.pop(context);
              },
            ),
            _AutoScanOption(
              icon: Icons.open_in_new,
              title: context.l10n.libraryAutoScanOnOpen,
              selected: current == 'on_open',
              colorScheme: colorScheme,
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setLocalLibraryAutoScan('on_open');
                Navigator.pop(context);
              },
            ),
            _AutoScanOption(
              icon: Icons.today,
              title: context.l10n.libraryAutoScanDaily,
              selected: current == 'daily',
              colorScheme: colorScheme,
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setLocalLibraryAutoScan('daily');
                Navigator.pop(context);
              },
            ),
            _AutoScanOption(
              icon: Icons.date_range,
              title: context.l10n.libraryAutoScanWeekly,
              selected: current == 'weekly',
              colorScheme: colorScheme,
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setLocalLibraryAutoScan('weekly');
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  String _getDefaultViewLabel(BuildContext context, String view) {
    switch (view) {
      case 'all':
        return context.l10n.historyFilterAll;
      case 'albums':
        return context.l10n.historyFilterAlbums;
      case 'singles':
        return context.l10n.historyFilterSingles;
      case 'playlists':
        return context.l10n.searchPlaylists;
      default:
        return context.l10n.libraryDefaultViewLastUsed;
    }
  }

  void _showDefaultViewPicker(BuildContext context, String current) {
    final colorScheme = Theme.of(context).colorScheme;
    final options = [
      ('last', Icons.history, context.l10n.libraryDefaultViewLastUsed),
      ('all', Icons.apps, context.l10n.historyFilterAll),
      ('albums', Icons.album, context.l10n.historyFilterAlbums),
      ('singles', Icons.music_note, context.l10n.historyFilterSingles),
      ('playlists', Icons.queue_music, context.l10n.searchPlaylists),
    ];
    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Text(
                context.l10n.libraryDefaultView,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            for (final (value, icon, label) in options)
              _AutoScanOption(
                icon: icon,
                title: label,
                selected: current == value,
                colorScheme: colorScheme,
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setDefaultLibraryView(value);
                  Navigator.pop(context);
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  String _getQualityLabelModeLabel(BuildContext context, String mode) {
    if (mode == AppSettings.libraryQualityLabelFileFormat) {
      return context.l10n.libraryQualityLabelFileFormat;
    }
    if (mode == AppSettings.libraryQualityLabelBitDepthOnly) {
      return context.l10n.audioAnalysisBitDepth;
    }
    if (mode == AppSettings.libraryQualityLabelBitDepth) {
      return '${context.l10n.audioAnalysisBitDepth} & '
          '${context.l10n.audioAnalysisSampleRate}';
    }
    if (mode == AppSettings.libraryQualityLabelBitDepthBitrate) {
      return '${context.l10n.audioAnalysisBitDepth} & '
          '${context.l10n.trackConvertBitrate}';
    }
    return context.l10n.trackConvertBitrate;
  }

  void _showQualityLabelModePicker(BuildContext context, String current) {
    final colorScheme = Theme.of(context).colorScheme;
    final options = [
      (
        AppSettings.libraryQualityLabelBitrate,
        Icons.speed_rounded,
        context.l10n.trackConvertBitrate,
      ),
      (
        AppSettings.libraryQualityLabelBitDepthOnly,
        Icons.tune_rounded,
        context.l10n.audioAnalysisBitDepth,
      ),
      (
        AppSettings.libraryQualityLabelBitDepth,
        Icons.graphic_eq_rounded,
        '${context.l10n.audioAnalysisBitDepth} & '
            '${context.l10n.audioAnalysisSampleRate}',
      ),
      (
        AppSettings.libraryQualityLabelBitDepthBitrate,
        Icons.multiline_chart_rounded,
        '${context.l10n.audioAnalysisBitDepth} & '
            '${context.l10n.trackConvertBitrate}',
      ),
      (
        AppSettings.libraryQualityLabelFileFormat,
        Icons.audio_file_rounded,
        context.l10n.libraryQualityLabelFileFormat,
      ),
    ];
    showAppModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: Text(
                context.l10n.trackAudioQuality,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            for (final (value, icon, label) in options)
              _AutoScanOption(
                icon: icon,
                title: label,
                selected: current == value,
                colorScheme: colorScheme,
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setLibraryQualityLabelMode(value);
                  Navigator.pop(context);
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final librarySources = ref.watch(
      localLibraryProvider.select((state) => state.sources),
    );
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.libraryTitle),

          // Scan snapshots land ~2.5x/s; keep the per-snapshot rebuild scoped
          // to the widgets that actually display scan state instead of the
          // whole settings page.
          SliverToBoxAdapter(
            child: Consumer(
              builder: (context, ref, _) {
                final libraryState = ref.watch(localLibraryProvider);
                return _LibraryHeroCard(
                  itemCount: libraryState.totalCount,
                  excludedDownloadedCount: libraryState.excludedDownloadedCount,
                  isScanning: libraryState.isScanning,
                  scanIsFinalizing: libraryState.scanIsFinalizing,
                  scanIsPaused: libraryState.scanIsPaused,
                  scanProgress: libraryState.scanProgress,
                  scanCurrentFile: libraryState.scanCurrentFile,
                  scanTotalFiles: libraryState.scanTotalFiles,
                  scannedFiles: libraryState.scannedFiles,
                  lastScannedAt: libraryState.lastScannedAt,
                );
              },
            ),
          ),

          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.grid_view_rounded,
                  title: context.l10n.libraryDefaultView,
                  subtitle: _getDefaultViewLabel(
                    context,
                    settings.defaultLibraryView,
                  ),
                  onTap: () => _showDefaultViewPicker(
                    context,
                    settings.defaultLibraryView,
                  ),
                ),
                SettingsItem(
                  icon: Icons.graphic_eq_rounded,
                  title: context.l10n.trackAudioQuality,
                  subtitle: _getQualityLabelModeLabel(
                    context,
                    settings.libraryQualityLabelMode,
                  ),
                  onTap: () => _showQualityLabelModePicker(
                    context,
                    settings.libraryQualityLabelMode,
                  ),
                  showDivider: false,
                ),
              ],
            ),
          ),

          SliverToBoxAdapter(
            child: SettingsSectionHeader(
              title: context.l10n.libraryScanSettings,
            ),
          ),
          SliverToBoxAdapter(
            child: Consumer(
              builder: (context, ref, _) {
                final status = ref.watch(
                  localLibraryProvider.select(
                    (state) =>
                        (loading: state.isLoading, failed: state.loadFailed),
                  ),
                );
                if (!status.loading && !status.failed) {
                  return const SizedBox.shrink();
                }
                return ListTile(
                  leading: status.loading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.error_outline, color: colorScheme.error),
                  title: Text(
                    status.loading
                        ? context.l10n.libraryLoading
                        : context.l10n.libraryLoadFailed,
                  ),
                  trailing: status.loading
                      ? null
                      : TextButton(
                          onPressed: () => ref
                              .read(localLibraryProvider.notifier)
                              .reloadFromStorage(),
                          child: Text(context.l10n.dialogRetry),
                        ),
                );
              },
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsSwitchItem(
                  icon: Icons.library_music_outlined,
                  title: context.l10n.libraryEnableLocalLibrary,
                  subtitle: settings.localLibraryEnabled
                      ? context.l10n.libraryEnableLocalLibrarySubtitle
                      : context.l10n.extensionsDisabled,
                  value: settings.localLibraryEnabled,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setLocalLibraryEnabled(value),
                ),
                for (final source in librarySources)
                  Consumer(
                    builder: (context, ref, _) {
                      final scan = ref.watch(
                        localLibraryProvider.select((state) {
                          final active = state.scanningSourceId == source.id;
                          return (
                            active: active,
                            finalizing: active && state.scanIsFinalizing,
                            paused: active && state.scanIsPaused,
                            scanned: active ? state.scannedFiles : 0,
                            total: active ? state.scanTotalFiles : 0,
                            progress: active ? state.scanProgress : 0.0,
                          );
                        }),
                      );
                      return _LibrarySourceSettingsItem(
                        source: source,
                        isScanning: scan.active,
                        isFinalizing: scan.finalizing,
                        isPaused: scan.paused,
                        scannedFiles: scan.scanned,
                        totalFiles: scan.total,
                        progress: scan.progress,
                        enabled: settings.localLibraryEnabled,
                        onEnabledChanged: (value) => ref
                            .read(localLibraryProvider.notifier)
                            .setSourceEnabled(source.id, value),
                        onScan: () => ref
                            .read(localLibraryProvider.notifier)
                            .startSourceScan(source.id),
                        onFullScan: () => ref
                            .read(localLibraryProvider.notifier)
                            .startSourceScan(source.id, forceFullScan: true),
                        onRemove: () => _removeSource(source),
                      );
                    },
                  ),
                Opacity(
                  opacity: settings.localLibraryEnabled ? 1.0 : 0.5,
                  child: SettingsItem(
                    icon: Icons.create_new_folder_outlined,
                    title: context.l10n.libraryAddFolder,
                    subtitle: librarySources.isEmpty
                        ? context.l10n.libraryFolderHint
                        : context.l10n.libraryAddFolderSubtitle,
                    onTap: settings.localLibraryEnabled
                        ? _pickLibraryFolder
                        : null,
                  ),
                ),
                SettingsSwitchItem(
                  icon: Icons.content_copy_outlined,
                  title: context.l10n.libraryShowDuplicateIndicator,
                  subtitle: settings.localLibraryShowDuplicates
                      ? context.l10n.libraryShowDuplicateIndicatorSubtitle
                      : context.l10n.extensionsDisabled,
                  value: settings.localLibraryShowDuplicates,
                  enabled: settings.localLibraryEnabled,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setLocalLibraryShowDuplicates(value),
                ),
                SettingsItem(
                  icon: Icons.difference_outlined,
                  title: context.l10n.libraryReviewDuplicates,
                  subtitle: context.l10n.libraryReviewDuplicatesSubtitle,
                  onTap: () => DuplicateReviewSheet.show(context),
                ),
                Opacity(
                  opacity: settings.localLibraryEnabled ? 1.0 : 0.5,
                  child: SettingsItem(
                    icon: Icons.autorenew_rounded,
                    title: context.l10n.libraryAutoScan,
                    subtitle: _getAutoScanLabel(
                      context,
                      settings.localLibraryAutoScan,
                    ),
                    onTap: settings.localLibraryEnabled
                        ? () => _showAutoScanPicker(
                            context,
                            settings.localLibraryAutoScan,
                          )
                        : null,
                    showDivider: false,
                  ),
                ),
              ],
            ),
          ),

          if (settings.localLibraryEnabled) ...[
            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: context.l10n.libraryActions),
            ),
            if (ref.watch(
              localLibraryProvider.select((s) => s.scanWasCancelled),
            ))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.tertiaryContainer.withValues(
                        alpha: 0.6,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_outlined,
                          color: colorScheme.onTertiaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.libraryScanCancelled,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: colorScheme.onTertiaryContainer,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                context.l10n.libraryScanCancelledSubtitle,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: colorScheme.onTertiaryContainer
                                          .withValues(alpha: 0.8),
                                    ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: _startScan,
                          child: Text(context.l10n.dialogRetry),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Consumer(
                builder: (context, ref, _) {
                  final libraryState = ref.watch(localLibraryProvider);
                  final hasDownloads = ref.watch(
                    downloadHistoryProvider.select(
                      (state) => state.totalCount > 0,
                    ),
                  );
                  final canCleanup =
                      !_isCleaningMissingFiles &&
                      !libraryState.isScanning &&
                      (libraryState.totalCount > 0 ||
                          hasDownloads ||
                          librarySources.isNotEmpty);
                  return SettingsGroup(
                    children: [
                      if (libraryState.isScanning)
                        _ScanProgressTile(
                          isFinalizing: libraryState.scanIsFinalizing,
                          isPaused: libraryState.scanIsPaused,
                          progress: libraryState.scanProgress,
                          currentFile: libraryState.scanCurrentFile,
                          scannedFiles: libraryState.scannedFiles,
                          totalFiles: libraryState.scanTotalFiles,
                          onPause: _pauseScan,
                          onResume: _resumeScan,
                          onCancel: _cancelScan,
                        )
                      else ...[
                        Opacity(
                          opacity: librarySources.isNotEmpty ? 1.0 : 0.5,
                          child: SettingsItem(
                            icon: Icons.refresh,
                            title: context.l10n.libraryScan,
                            subtitle: librarySources.isEmpty
                                ? context.l10n.libraryScanSelectFolderFirst
                                : context.l10n.libraryScanSubtitle,
                            onTap: librarySources.isNotEmpty
                                ? _startScan
                                : null,
                          ),
                        ),
                        Opacity(
                          opacity: librarySources.isNotEmpty ? 1.0 : 0.5,
                          child: SettingsItem(
                            icon: Icons.sync,
                            title: context.l10n.libraryForceFullScan,
                            subtitle: context.l10n.libraryForceFullScanSubtitle,
                            onTap: librarySources.isNotEmpty
                                ? () => _startScan(forceFullScan: true)
                                : null,
                          ),
                        ),
                      ],
                      Opacity(
                        opacity: canCleanup || _isCleaningMissingFiles
                            ? 1.0
                            : 0.5,
                        child: SettingsItem(
                          icon: Icons.cleaning_services_outlined,
                          title: context.l10n.libraryCleanupMissingFiles,
                          subtitle:
                              context.l10n.libraryCleanupMissingFilesSubtitle,
                          trailing: _isCleaningMissingFiles
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : null,
                          onTap: canCleanup ? _cleanupMissingFiles : null,
                        ),
                      ),
                      Opacity(
                        opacity: libraryState.totalCount > 0 ? 1.0 : 0.5,
                        child: SettingsItem(
                          icon: Icons.delete_outline,
                          title: context.l10n.libraryClear,
                          subtitle: context.l10n.libraryClearSubtitle,
                          onTap: libraryState.totalCount > 0
                              ? _clearLibrary
                              : null,
                          showDivider: false,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],

          SliverToBoxAdapter(
            child: SettingsInfoCard(
              glass: true,
              icon: Icons.info_outline,
              title: context.l10n.libraryAbout,
              message: context.l10n.libraryAboutDescription,
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

class _LibrarySourceSettingsItem extends StatelessWidget {
  final LocalLibrarySource source;
  final bool isScanning;
  final bool isFinalizing;
  final bool isPaused;
  final int scannedFiles;
  final int totalFiles;
  final double progress;
  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final VoidCallback onScan;
  final VoidCallback onFullScan;
  final VoidCallback onRemove;

  const _LibrarySourceSettingsItem({
    required this.source,
    required this.isScanning,
    required this.isFinalizing,
    required this.isPaused,
    required this.scannedFiles,
    required this.totalFiles,
    required this.progress,
    required this.enabled,
    required this.onEnabledChanged,
    required this.onScan,
    required this.onFullScan,
    required this.onRemove,
  });

  String _title() {
    final normalized = source.displayName
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    final name = normalized.split('/').last.trim();
    return name.isEmpty ? source.displayName : name;
  }

  String _lastScanned(BuildContext context) {
    final value = source.lastScannedAt;
    if (value == null) return context.l10n.libraryLastScannedNever;
    final now = DateTime.now();
    final diff = now.difference(value);
    if (diff.inMinutes < 1) return context.l10n.timeJustNow;
    if (diff.inHours < 1) return context.l10n.timeMinutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return context.l10n.timeHoursAgo(diff.inHours);
    if (diff.inDays < 7) return context.l10n.dateDaysAgo(diff.inDays);
    return '${value.day}/${value.month}/${value.year}';
  }

  Future<void> _showActions(BuildContext context) async {
    final canScan =
        enabled && source.enabled && source.available && !isScanning;
    final action = await showAppBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      title: _title(),
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppSheetOption(
            enabled: canScan,
            leading: const Icon(Icons.refresh_rounded),
            title: Text(context.l10n.libraryScan),
            subtitle: Text(context.l10n.libraryScanSubtitle),
            onTap: canScan ? () => Navigator.pop(context, 'scan') : null,
          ),
          AppSheetOption(
            enabled: canScan,
            leading: const Icon(Icons.sync_rounded),
            title: Text(context.l10n.libraryForceFullScan),
            subtitle: Text(context.l10n.libraryForceFullScanSubtitle),
            onTap: canScan ? () => Navigator.pop(context, 'full_scan') : null,
          ),
          AppSheetOption(
            leading: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              context.l10n.libraryRemoveFolder,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => Navigator.pop(context, 'remove'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
    switch (action) {
      case 'scan':
        onScan();
      case 'full_scan':
        onFullScan();
      case 'remove':
        onRemove();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _title();
    final status = !source.enabled
        ? context.l10n.librarySourceDisabled
        : !source.available
        ? context.l10n.librarySourceOffline
        : isScanning
        ? isFinalizing
              ? context.l10n.libraryScanFinalizing
              : isPaused
              ? context.l10n.libraryScanPaused
              : totalFiles > 0
              ? context.l10n.librarySourceScanCount(
                  scannedFiles,
                  totalFiles,
                  progress.toStringAsFixed(0),
                )
              : context.l10n.libraryScanning
        : source.lastScanError?.trim().isNotEmpty == true
        ? context.l10n.notifLibraryScanFailed
        : context.l10n.librarySourceOnline;
    final pathLine = source.displayName == title ? null : source.displayName;
    final details = [
      status,
      context.l10n.libraryTracksUnit(source.trackCount),
      context.l10n.libraryLastScanned(_lastScanned(context)),
    ].join(' · ');

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: SettingsItem(
        icon: source.path.startsWith('network://')
            ? Icons.dns_outlined
            : source.isRemovable
            ? Icons.usb_rounded
            : Icons.folder_outlined,
        title: title,
        titleTrailing: source.isRemovable
            ? Tooltip(
                message: context.l10n.libraryExternalStorage,
                child: const Icon(Icons.sd_storage_outlined, size: 16),
              )
            : null,
        subtitle: pathLine == null ? details : '$pathLine\n$details',
        onTap: () => _showActions(context),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isScanning)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _AnimatedScanCount(
                  count: scannedFiles,
                  progress: progress,
                  determinate: totalFiles > 0 && !isFinalizing,
                ),
              ),
            AppSwitch(
              adaptive: true,
              semanticLabel: title,
              value: source.enabled,
              onChanged: enabled ? onEnabledChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimatedScanCount extends StatelessWidget {
  final int count;
  final double progress;
  final bool determinate;

  const _AnimatedScanCount({
    required this.count,
    required this.progress,
    required this.determinate,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 42,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              value: determinate ? (progress / 100).clamp(0.0, 1.0) : null,
              strokeWidth: 2,
            ),
          ),
          const SizedBox(height: 2),
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: count.toDouble()),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            builder: (context, value, _) => Text(
              value.round().toString(),
              maxLines: 1,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryHeroCard extends StatelessWidget {
  final int itemCount;
  final int excludedDownloadedCount;
  final bool isScanning;
  final bool scanIsFinalizing;
  final bool scanIsPaused;
  final double scanProgress;
  final String? scanCurrentFile;
  final int scanTotalFiles;
  final int scannedFiles;
  final DateTime? lastScannedAt;

  const _LibraryHeroCard({
    required this.itemCount,
    required this.excludedDownloadedCount,
    required this.isScanning,
    required this.scanIsFinalizing,
    required this.scanIsPaused,
    required this.scanProgress,
    this.scanCurrentFile,
    required this.scanTotalFiles,
    required this.scannedFiles,
    this.lastScannedAt,
  });

  String _formatLastScanned(BuildContext context) {
    if (lastScannedAt == null) return context.l10n.libraryLastScannedNever;
    final now = DateTime.now();
    final diff = now.difference(lastScannedAt!);

    if (diff.inMinutes < 1) return context.l10n.timeJustNow;
    if (diff.inHours < 1) return context.l10n.timeMinutesAgo(diff.inMinutes);
    if (diff.inDays < 1) return context.l10n.timeHoursAgo(diff.inHours);
    if (diff.inDays < 7) return context.l10n.dateDaysAgo(diff.inDays);

    return '${lastScannedAt!.day}/${lastScannedAt!.month}/${lastScannedAt!.year}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showIndeterminateProgress =
        isScanning &&
        !scanIsPaused &&
        (scanIsFinalizing ||
            scanTotalFiles <= 0 ||
            (scannedFiles <= 0 && scanProgress <= 0));
    final displayCount = isScanning
        ? scannedFiles
        : itemCount + excludedDownloadedCount;

    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: 16 + wideListInset(context),
        vertical: 8,
      ),
      constraints: const BoxConstraints(minHeight: 220),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: 0.05),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            right: -20,
            top: -20,
            child: Icon(
              Icons.library_music,
              size: 200,
              color: colorScheme.primary.withValues(alpha: 0.05),
            ),
          ),
          Positioned(
            left: -40,
            bottom: -40,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colorScheme.secondaryContainer.withValues(alpha: 0.3),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        isScanning
                            ? scanIsPaused
                                  ? Icons.pause_rounded
                                  : Icons.sync
                            : Icons.music_note,
                        color: colorScheme.onPrimaryContainer,
                        size: 32,
                      ),
                    ),
                    const Spacer(),
                    if (isScanning)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: scanIsPaused
                                  ? Icon(
                                      Icons.pause_rounded,
                                      size: 12,
                                      color: colorScheme.onPrimary,
                                    )
                                  : CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: colorScheme.onPrimary,
                                    ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              scanIsPaused
                                  ? context.l10n.libraryScanPaused
                                  : context.l10n.libraryScanning,
                              style: TextStyle(
                                color: colorScheme.onPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    displayCount.toString(),
                    style: TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                      height: 1.0,
                      letterSpacing: -2,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isScanning
                      ? context.l10n.libraryFilesUnit(scannedFiles)
                      : context.l10n.libraryTracksUnit(displayCount),
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (!isScanning && excludedDownloadedCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    context.l10n.libraryDownloadsHistoryExcluded(
                      excludedDownloadedCount,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
                ],
                if (isScanning) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: showIndeterminateProgress
                        ? null
                        : scanTotalFiles > 0
                        ? scanProgress / 100
                        : 0,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    color: colorScheme.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    scanIsFinalizing
                        ? context.l10n.libraryScanFinalizing
                        : scanTotalFiles > 0
                        ? context.l10n.libraryScanProgress(
                            scanProgress.toStringAsFixed(0),
                            scanTotalFiles,
                          )
                        : scanIsPaused
                        ? context.l10n.libraryScanPaused
                        : context.l10n.libraryScanning,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
                  if (!scanIsFinalizing &&
                      scanCurrentFile != null &&
                      scanCurrentFile!.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      scanCurrentFile!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ],
                ] else ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.history,
                        size: 14,
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.7,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        context.l10n.libraryLastScanned(
                          _formatLastScanned(context),
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.7,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanProgressTile extends StatelessWidget {
  final bool isFinalizing;
  final bool isPaused;
  final double progress;
  final String? currentFile;
  final int scannedFiles;
  final int totalFiles;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onCancel;

  const _ScanProgressTile({
    required this.isFinalizing,
    required this.isPaused,
    required this.progress,
    this.currentFile,
    required this.scannedFiles,
    required this.totalFiles,
    required this.onPause,
    required this.onResume,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // A paused bar stays still at its last position instead of animating.
    final showIndeterminateProgress =
        !isPaused &&
        (isFinalizing ||
            totalFiles <= 0 ||
            (scannedFiles <= 0 && progress <= 0));
    final progressValue = totalFiles > 0 ? progress / 100 : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isPaused ? Icons.pause_circle_outline : Icons.scanner,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isPaused
                          ? context.l10n.libraryScanPaused
                          : context.l10n.libraryScanning,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      isFinalizing
                          ? context.l10n.libraryScanFinalizing
                          : totalFiles > 0
                          ? context.l10n.libraryScanProgress(
                              progress.toStringAsFixed(0),
                              totalFiles,
                            )
                          : context.l10n.libraryScanning,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isFinalizing)
                TextButton(
                  onPressed: isPaused ? onResume : onPause,
                  child: Text(
                    isPaused
                        ? context.l10n.actionResume
                        : context.l10n.actionPause,
                  ),
                ),
              TextButton(
                onPressed: onCancel,
                child: Text(context.l10n.actionCancel),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: showIndeterminateProgress ? null : progressValue,
            backgroundColor: colorScheme.surfaceContainerHighest,
            color: colorScheme.primary,
            borderRadius: BorderRadius.circular(4),
          ),
          if (!isFinalizing &&
              currentFile != null &&
              currentFile!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              currentFile!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _AutoScanOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool selected;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _AutoScanOption({
    required this.icon,
    required this.title,
    required this.selected,
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppSheetOption(
      leading: Icon(icon),
      title: Text(title),
      trailing: selected ? Icon(Icons.check, color: colorScheme.primary) : null,
      onTap: onTap,
    );
  }
}
