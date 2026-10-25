import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoColors;
import 'package:mosix/widgets/app_snack_bar.dart';
import 'package:mosix/widgets/app_switch.dart';
import 'package:mosix/widgets/extension_row.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/extension_provider.dart';
import 'package:mosix/providers/explore_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/screens/settings/download_fallback_extensions_page.dart';
import 'package:mosix/screens/settings/extension_detail_page.dart';
import 'package:mosix/screens/settings/metadata_provider_priority_page.dart';
import 'package:mosix/screens/settings/provider_priority_page.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/widgets/app_action_button.dart';
import 'package:mosix/widgets/mornye_chrome.dart';
import 'package:mosix/widgets/settings_group.dart';
import 'package:mosix/widgets/app_sliver_header.dart';

class ExtensionsPage extends ConsumerStatefulWidget {
  const ExtensionsPage({super.key});

  @override
  ConsumerState<ExtensionsPage> createState() => _ExtensionsPageState();
}

class _ExtensionsPageState extends ConsumerState<ExtensionsPage> {
  @override
  void initState() {
    super.initState();
    _initializeExtensions();
  }

  Future<void> _initializeExtensions() async {
    final extState = ref.read(extensionProvider);
    if (!extState.isInitialized) {
      try {
        await ref.read(extensionProvider.notifier).ensureInitialized();
      } catch (_) {
        // The provider exposes preparation failures in the existing error UI.
      }
    } else {
      ref.read(extensionProvider.notifier).refreshEnabledExtensionHealth();
    }
  }

  @override
  Widget build(BuildContext context) {
    final extState = ref.watch(extensionProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final installButton = AppActionButton(
      onPressed: _installExtension,
      icon: const Icon(Icons.add),
      label: Text(context.l10n.extensionsInstallButton),
      outlined: context.isMornye,
      glass: false,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.extensionsTitle),

            if (extState.isLoading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),

            if (extState.error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: colorScheme.error),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            context.friendlyError(extState.error),
                            style: TextStyle(
                              color: colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.extensionsProviderPrioritySection,
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  _DownloadPriorityItem(),
                  _DownloadFallbackItem(),
                  _MetadataPriorityItem(),
                  _SearchProviderSelector(),
                  _HomeFeedProviderSelector(),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.extensionsInstalledSection,
              ),
            ),

            if (extState.extensions.isEmpty && !extState.isLoading)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.extension_outlined,
                          size: 48,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          context.l10n.extensionsNoExtensions,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.l10n.extensionsNoExtensionsSubtitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            if (extState.extensions.isNotEmpty)
              SliverToBoxAdapter(
                child: SettingsGroup(
                  children: extState.extensions.asMap().entries.map((entry) {
                    final index = entry.key;
                    final ext = entry.value;
                    return _ExtensionItem(
                      extension: ext,
                      healthStatus: extState.healthStatuses[ext.id],
                      showDivider: index < extState.extensions.length - 1,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ExtensionDetailPage(extensionId: ext.id),
                        ),
                      ),
                      onToggle: (enabled) => ref
                          .read(extensionProvider.notifier)
                          .setExtensionEnabled(ext.id, enabled),
                    );
                  }).toList(),
                ),
              ),

            SliverToBoxAdapter(
              child: SettingsSearchTarget(
                label: context.l10n.extensionsInstallButton,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: context.isMornye
                      ? MornyeGlassPanel.overlay(
                          radius: 28,
                          child: installButton,
                        )
                      : installButton,
                ),
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsInfoCard(
                glass: true,
                icon: Icons.info_outline,
                tone: SettingsInfoTone.warning,
                message: context.l10n.extensionsInfoTip,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _installExtension() async {
    final selectedFiles = await FilePicker.pickFiles(type: FileType.any);
    if (selectedFiles.isEmpty) return;

    final hasInvalidFile = selectedFiles.any((file) {
      final lowerName = file.name.toLowerCase();
      return !lowerName.endsWith('.spotiflac-ext') &&
          !lowerName.endsWith('.sflx');
    });
    if (hasInvalidFile) {
      if (mounted) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.snackbarSelectExtFile),
        );
      }
      return;
    }

    Directory? materializedDir;
    try {
      final extensionPaths = <String>[];
      for (final selectedFile in selectedFiles) {
        final localPath = selectedFile.path;
        if (localPath != null && localPath.isNotEmpty) {
          extensionPaths.add(localPath);
          continue;
        }

        materializedDir ??= await Directory.systemTemp.createTemp(
          'spotiflac_extension_import_',
        );
        final safeName = p.basename(selectedFile.name);
        final materializedFile = File(
          p.join(materializedDir.path, '${extensionPaths.length}_$safeName'),
        );
        await materializedFile.writeAsBytes(
          await selectedFile.readAsBytes(),
          flush: true,
        );
        extensionPaths.add(materializedFile.path);
      }

      final installResult = await ref
          .read(extensionProvider.notifier)
          .installExtensions(extensionPaths);

      if (mounted) {
        final message = _getInstallResultMessage(installResult);
        ref.read(extensionProvider.notifier).clearError();

        showAppSnackBar(context, content: Text(message));
      }
    } finally {
      try {
        if (materializedDir != null && await materializedDir.exists()) {
          await materializedDir.delete(recursive: true);
        }
      } catch (_) {
        // The extension has already been copied into app storage.
      }
    }
  }

  String _getInstallResultMessage(ExtensionInstallBatchResult result) {
    if (result.attempted == 0) {
      return context.l10n.snackbarSelectExtFile;
    }

    if (!result.hasFailures) {
      if (result.installed == 1) {
        return context.l10n.extensionsInstalledSuccess;
      }
      return context.l10n.extensionsInstalledCount(result.installed);
    }

    if (result.anyInstalled) {
      return context.l10n.extensionsInstallPartialSuccess(
        result.installed,
        result.attempted,
      );
    }

    final firstError = result.failures.values.firstOrNull;
    return _getFriendlyErrorMessage(firstError);
  }

  String _getFriendlyErrorMessage(String? error) {
    return context.friendlyError(
      error,
      fallback: context.l10n.snackbarFailedToInstall,
    );
  }
}

class _ExtensionItem extends StatelessWidget {
  final Extension extension;
  final ExtensionHealthStatus? healthStatus;
  final bool showDivider;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  const _ExtensionItem({
    required this.extension,
    this.healthStatus,
    required this.showDivider,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasError = extension.status == 'error';
    final serviceHealthStatus = extension.hasServiceHealth
        ? healthStatus?.status
        : null;
    final serviceHealthColor = serviceHealthStatus == null
        ? null
        : _extensionHealthColor(context, serviceHealthStatus);

    return ExtensionRow(
      showDivider: showDivider,
      onTap: onTap,
      avatar: context.isMornye
          ? null
          : ExtensionAvatar(
              filePath: extension.iconPath,
              fallbackIcon: hasError ? Icons.error_outline : Icons.extension,
              background: hasError
                  ? colorScheme.errorContainer
                  : colorScheme.primaryContainer,
              foreground: hasError
                  ? colorScheme.error
                  : colorScheme.onPrimaryContainer,
            ),
      title: Text(extension.displayName),
      subtitle: Text.rich(
        hasError
            ? TextSpan(
                text: context.friendlyError(
                  extension.errorMessage,
                  fallback: context.l10n.extensionsErrorLoading,
                ),
              )
            : TextSpan(
                text: 'v${extension.version}',
                children: [
                  if (serviceHealthStatus != null) ...[
                    const TextSpan(text: ' · '),
                    TextSpan(
                      text: _extensionHealthLabel(context, serviceHealthStatus),
                      style: TextStyle(color: serviceHealthColor),
                    ),
                  ],
                ],
              ),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: hasError ? colorScheme.error : colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: AppSwitch(
        value: extension.enabled,
        semanticLabel: extension.displayName,
        onChanged: hasError ? null : onToggle,
      ),
    );
  }
}

Color _extensionHealthColor(BuildContext context, String status) {
  final colorScheme = Theme.of(context).colorScheme;
  switch (status) {
    case 'online':
      return context.isMornye
          ? CupertinoColors.systemGreen.resolveFrom(context)
          : colorScheme.primary;
    case 'degraded':
      return colorScheme.tertiary;
    case 'offline':
      return colorScheme.error;
    default:
      return colorScheme.onSurfaceVariant;
  }
}

String _extensionHealthLabel(BuildContext context, String status) {
  switch (status) {
    case 'online':
      return context.l10n.extensionHealthOnline;
    case 'degraded':
      return context.l10n.extensionHealthDegraded;
    case 'offline':
      return context.l10n.extensionHealthOffline;
    default:
      return context.l10n.extensionHealthUnknown;
  }
}

class _DownloadPriorityItem extends ConsumerWidget {
  const _DownloadPriorityItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final extState = ref.watch(extensionProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final hasDownloadExtensions = extState.extensions.any(
      (e) => e.enabled && e.hasDownloadProvider,
    );

    if (context.isMornye) {
      return Opacity(
        opacity: hasDownloadExtensions ? 1 : 0.5,
        child: SettingsItem(
          icon: Icons.download,
          title: context.l10n.extensionsDownloadPriority,
          subtitle: hasDownloadExtensions
              ? context.l10n.extensionsDownloadPrioritySubtitle
              : context.l10n.extensionsNoDownloadProvider,
          onTap: hasDownloadExtensions
              ? () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ProviderPriorityPage(),
                  ),
                )
              : null,
        ),
      );
    }

    final content = InkWell(
      onTap: hasDownloadExtensions
          ? () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const ProviderPriorityPage(),
              ),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.download,
              color: hasDownloadExtensions
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.outline,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.extensionsDownloadPriority,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: hasDownloadExtensions ? null : colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasDownloadExtensions
                        ? context.l10n.extensionsDownloadPrioritySubtitle
                        : context.l10n.extensionsNoDownloadProvider,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: hasDownloadExtensions
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.outline,
            ),
          ],
        ),
      ),
    );
    return SettingsSearchTarget(
      label: context.l10n.extensionsDownloadPriority,
      child: content,
    );
  }
}

class _MetadataPriorityItem extends ConsumerWidget {
  const _MetadataPriorityItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final extState = ref.watch(extensionProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final hasMetadataExtensions = extState.extensions.any(
      (e) => e.enabled && e.hasMetadataProvider,
    );

    if (context.isMornye) {
      return Opacity(
        opacity: hasMetadataExtensions ? 1 : 0.5,
        child: SettingsItem(
          icon: Icons.search,
          title: context.l10n.extensionsMetadataPriority,
          subtitle: hasMetadataExtensions
              ? context.l10n.extensionsMetadataPrioritySubtitle
              : context.l10n.extensionsNoMetadataProvider,
          onTap: hasMetadataExtensions
              ? () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const MetadataProviderPriorityPage(),
                  ),
                )
              : null,
        ),
      );
    }

    final content = InkWell(
      onTap: hasMetadataExtensions
          ? () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const MetadataProviderPriorityPage(),
              ),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.search,
              color: hasMetadataExtensions
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.outline,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.extensionsMetadataPriority,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: hasMetadataExtensions ? null : colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasMetadataExtensions
                        ? context.l10n.extensionsMetadataPrioritySubtitle
                        : context.l10n.extensionsNoMetadataProvider,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: hasMetadataExtensions
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.outline,
            ),
          ],
        ),
      ),
    );
    return SettingsSearchTarget(
      label: context.l10n.extensionsMetadataPriority,
      child: content,
    );
  }
}

class _DownloadFallbackItem extends ConsumerWidget {
  const _DownloadFallbackItem();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final extState = ref.watch(extensionProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final hasDownloadExtensions = extState.extensions.any(
      (e) => e.enabled && e.hasDownloadProvider,
    );

    if (context.isMornye) {
      return Opacity(
        opacity: hasDownloadExtensions ? 1 : 0.5,
        child: SettingsItem(
          icon: Icons.alt_route,
          title: context.l10n.extensionsFallbackTitle,
          subtitle: hasDownloadExtensions
              ? context.l10n.extensionsFallbackSubtitle
              : context.l10n.extensionsNoDownloadProvider,
          onTap: hasDownloadExtensions
              ? () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const DownloadFallbackExtensionsPage(),
                  ),
                )
              : null,
        ),
      );
    }

    final content = InkWell(
      onTap: hasDownloadExtensions
          ? () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const DownloadFallbackExtensionsPage(),
              ),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              Icons.alt_route,
              color: hasDownloadExtensions
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.outline,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.extensionsFallbackTitle,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: hasDownloadExtensions ? null : colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasDownloadExtensions
                        ? context.l10n.extensionsFallbackSubtitle
                        : context.l10n.extensionsNoDownloadProvider,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: hasDownloadExtensions
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.outline,
            ),
          ],
        ),
      ),
    );
    return SettingsSearchTarget(
      label: context.l10n.extensionsFallbackTitle,
      child: content,
    );
  }
}

class _SearchProviderSelector extends ConsumerWidget {
  const _SearchProviderSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final extState = ref.watch(extensionProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final searchProviders = extState.extensions
        .where((e) => e.enabled && e.hasCustomSearch)
        .toList();

    final hasAnyProvider = searchProviders.isNotEmpty;

    final resolvedProviderId =
        (settings.searchProvider != null && settings.searchProvider!.isNotEmpty)
        ? settings.searchProvider!
        : searchProviders.firstOrNull?.id;
    String currentProviderName = context.l10n.optionsPrimaryProviderSubtitle;
    if (resolvedProviderId != null && resolvedProviderId.isNotEmpty) {
      final ext = searchProviders
          .where((e) => e.id == resolvedProviderId)
          .firstOrNull;
      currentProviderName = ext?.displayName ?? resolvedProviderId;
    }

    if (context.isMornye) {
      return Opacity(
        opacity: hasAnyProvider ? 1 : 0.5,
        child: SettingsItem(
          icon: Icons.manage_search,
          title: context.l10n.extensionsSearchProvider,
          subtitle: hasAnyProvider
              ? currentProviderName
              : context.l10n.extensionsNoCustomSearch,
          onTap: hasAnyProvider
              ? () => _showSearchProviderPicker(
                  context,
                  ref,
                  settings,
                  searchProviders,
                )
              : null,
        ),
      );
    }

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: !hasAnyProvider
              ? null
              : () => _showSearchProviderPicker(
                  context,
                  ref,
                  settings,
                  searchProviders,
                ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.manage_search,
                  color: !hasAnyProvider
                      ? colorScheme.outline
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.extensionsSearchProvider,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: !hasAnyProvider ? colorScheme.outline : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        !hasAnyProvider
                            ? context.l10n.extensionsNoCustomSearch
                            : currentProviderName,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  color: !hasAnyProvider
                      ? colorScheme.outline
                      : colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ],
    );
    return SettingsSearchTarget(
      label: context.l10n.extensionsSearchProvider,
      child: content,
    );
  }

  void _showSearchProviderPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    List<Extension> searchProviders,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                child: Text(
                  ctx.l10n.extensionsSearchProvider,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(
                  ctx.l10n.extensionsSearchProviderDescription,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ...searchProviders.map(
                (ext) => ListTile(
                  leading: Icon(Icons.extension, color: colorScheme.secondary),
                  title: Text(ext.displayName),
                  subtitle: Text(
                    ext.searchBehavior?.placeholder ??
                        ctx.l10n.extensionsCustomSearch,
                  ),
                  trailing: settings.searchProvider == ext.id
                      ? Icon(Icons.check_circle, color: colorScheme.primary)
                      : Icon(Icons.circle_outlined, color: colorScheme.outline),
                  onTap: () {
                    ref
                        .read(settingsProvider.notifier)
                        .setSearchProvider(ext.id);
                    Navigator.pop(ctx);
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeFeedProviderSelector extends ConsumerWidget {
  const _HomeFeedProviderSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final extState = ref.watch(extensionProvider);
    final colorScheme = Theme.of(context).colorScheme;

    final homeFeedProviders = extState.extensions
        .where((e) => e.enabled && e.hasHomeFeed)
        .toList();

    final hasAnyProvider = homeFeedProviders.isNotEmpty;
    final homeFeedDisabled =
        settings.homeFeedProvider == AppSettings.homeFeedProviderOff;

    String currentProviderName = context.l10n.extensionsHomeFeedAuto;
    if (homeFeedDisabled) {
      currentProviderName = context.l10n.extensionsHomeFeedOff;
    } else if (settings.homeFeedProvider != null &&
        settings.homeFeedProvider!.isNotEmpty) {
      final ext = homeFeedProviders
          .where((e) => e.id == settings.homeFeedProvider)
          .firstOrNull;
      currentProviderName = ext?.displayName ?? settings.homeFeedProvider!;
    }

    if (context.isMornye) {
      return SettingsItem(
        icon: Icons.explore_outlined,
        title: context.l10n.extensionsHomeFeedProvider,
        subtitle: !hasAnyProvider && !homeFeedDisabled
            ? context.l10n.extensionsNoHomeFeedExtensions
            : currentProviderName,
        showDivider: false,
        onTap: () => _showHomeFeedProviderPicker(
          context,
          ref,
          settings,
          homeFeedProviders,
        ),
      );
    }

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => _showHomeFeedProviderPicker(
            context,
            ref,
            settings,
            homeFeedProviders,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.explore_outlined,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.extensionsHomeFeedProvider,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        !hasAnyProvider && !homeFeedDisabled
                            ? context.l10n.extensionsNoHomeFeedExtensions
                            : currentProviderName,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ],
    );
    return SettingsSearchTarget(
      label: context.l10n.extensionsHomeFeedProvider,
      child: content,
    );
  }

  void _showHomeFeedProviderPicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
    List<Extension> homeFeedProviders,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: colorScheme.surfaceContainerHigh,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                child: Text(
                  ctx.l10n.extensionsHomeFeedProvider,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Text(
                  ctx.l10n.extensionsHomeFeedDescription,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(Icons.auto_awesome, color: colorScheme.primary),
                title: Text(ctx.l10n.extensionsHomeFeedAuto),
                subtitle: Text(ctx.l10n.extensionsHomeFeedAutoSubtitle),
                trailing:
                    (settings.homeFeedProvider == null ||
                        settings.homeFeedProvider!.isEmpty)
                    ? Icon(Icons.check_circle, color: colorScheme.primary)
                    : Icon(Icons.circle_outlined, color: colorScheme.outline),
                onTap: () {
                  ref.read(settingsProvider.notifier).setHomeFeedProvider(null);
                  ref.read(exploreProvider.notifier).refresh();
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(Icons.block, color: colorScheme.error),
                title: Text(ctx.l10n.extensionsHomeFeedOff),
                subtitle: Text(ctx.l10n.extensionsHomeFeedOffSubtitle),
                trailing:
                    settings.homeFeedProvider == AppSettings.homeFeedProviderOff
                    ? Icon(Icons.check_circle, color: colorScheme.primary)
                    : Icon(Icons.circle_outlined, color: colorScheme.outline),
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setHomeFeedProvider(AppSettings.homeFeedProviderOff);
                  ref.read(exploreProvider.notifier).clear();
                  Navigator.pop(ctx);
                },
              ),
              if (homeFeedProviders.isEmpty)
                ListTile(
                  enabled: false,
                  leading: Icon(
                    Icons.extension_off,
                    color: colorScheme.outline,
                  ),
                  title: Text(ctx.l10n.extensionsNoHomeFeedExtensions),
                ),
              ...homeFeedProviders.map(
                (ext) => ListTile(
                  leading: Icon(Icons.extension, color: colorScheme.secondary),
                  title: Text(ext.displayName),
                  subtitle: Text(
                    ctx.l10n.extensionsHomeFeedUse(ext.displayName),
                  ),
                  trailing: settings.homeFeedProvider == ext.id
                      ? Icon(Icons.check_circle, color: colorScheme.primary)
                      : Icon(Icons.circle_outlined, color: colorScheme.outline),
                  onTap: () {
                    ref
                        .read(settingsProvider.notifier)
                        .setHomeFeedProvider(ext.id);
                    ref.read(exploreProvider.notifier).refresh();
                    Navigator.pop(ctx);
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
