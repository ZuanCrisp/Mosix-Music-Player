import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoColors, CupertinoIcons, CupertinoTextField;
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/theme/mornye_icons.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';
import 'package:mosix/widgets/app_bottom_sheet.dart';
import 'package:mosix/widgets/app_switch.dart';
import 'package:mosix/widgets/app_snack_bar.dart';
import 'package:mosix/widgets/mornye_chrome.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/extension_provider.dart';
import 'package:mosix/providers/repo_provider.dart';
import 'package:mosix/utils/extension_auth_launcher.dart';
import 'package:mosix/utils/extension_action_forms.dart';
import 'package:mosix/widgets/settings_group.dart';
import 'package:mosix/widgets/app_sliver_header.dart';

class ExtensionDetailPage extends ConsumerStatefulWidget {
  final String extensionId;

  const ExtensionDetailPage({super.key, required this.extensionId});

  @override
  ConsumerState<ExtensionDetailPage> createState() =>
      _ExtensionDetailPageState();
}

class _ExtensionDetailPageState extends ConsumerState<ExtensionDetailPage> {
  Map<String, dynamic> _settings = {};
  bool _isLoadingSettings = true;
  bool _isRefreshingHealth = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshHealth();
    });
  }

  Future<void> _loadSettings() async {
    final settings = await ref
        .read(extensionProvider.notifier)
        .getExtensionSettings(widget.extensionId);
    setState(() {
      _settings = settings;
      _isLoadingSettings = false;
    });
  }

  Future<void> _refreshHealth({bool force = false}) async {
    final ext = ref
        .read(extensionProvider)
        .extensions
        .where((extension) => extension.id == widget.extensionId)
        .firstOrNull;
    if (ext == null || !ext.hasServiceHealth) return;

    setState(() => _isRefreshingHealth = true);
    try {
      await ref
          .read(extensionProvider.notifier)
          .checkExtensionHealth(widget.extensionId, force: force);
    } finally {
      if (mounted) {
        setState(() => _isRefreshingHealth = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final extState = ref.watch(extensionProvider);
    final extension = extState.extensions.firstWhere(
      (e) => e.id == widget.extensionId,
      orElse: () => const Extension(
        id: '',
        name: '',
        displayName: 'Unknown',
        version: '0.0.0',
        description: '',
        enabled: false,
        status: 'error',
      ),
    );

    final colorScheme = Theme.of(context).colorScheme;
    final hasError = extension.status == 'error';
    final healthStatus = extState.healthStatuses[extension.id];

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: extension.displayName),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _ExtensionOverviewSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: context.isMornye
                                  ? MornyeTheme.controlFill(context)
                                  : hasError
                                  ? colorScheme.errorContainer
                                  : colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child:
                                extension.iconPath != null &&
                                    extension.iconPath!.isNotEmpty
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: Image.file(
                                      File(extension.iconPath!),
                                      width: 56,
                                      height: 56,
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (context, error, stackTrace) => Icon(
                                            context.isMornye
                                                ? (hasError
                                                      ? CupertinoIcons
                                                            .exclamationmark_circle
                                                      : CupertinoIcons
                                                            .square_grid_2x2)
                                                : hasError
                                                ? Icons.error_outline
                                                : Icons.extension,
                                            size: 28,
                                            color: hasError
                                                ? colorScheme.error
                                                : colorScheme
                                                      .onPrimaryContainer,
                                          ),
                                    ),
                                  )
                                : Icon(
                                    context.isMornye
                                        ? (hasError
                                              ? CupertinoIcons
                                                    .exclamationmark_circle
                                              : CupertinoIcons.square_grid_2x2)
                                        : hasError
                                        ? Icons.error_outline
                                        : Icons.extension,
                                    size: 28,
                                    color: hasError
                                        ? colorScheme.error
                                        : colorScheme.onPrimaryContainer,
                                  ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  extension.displayName,
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  'v${extension.version}',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          AppSwitch(
                            value: extension.enabled,
                            semanticLabel: extension.displayName,
                            onChanged: hasError
                                ? null
                                : (enabled) => ref
                                      .read(extensionProvider.notifier)
                                      .setExtensionEnabled(
                                        widget.extensionId,
                                        enabled,
                                      ),
                          ),
                        ],
                      ),
                      if (extension.description.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          extension.description,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (context.isMornye)
                        Divider(
                          color: MornyeTheme.metadataDividerColor(context),
                        ),
                      _InfoRow(
                        label: context.l10n.extensionId,
                        value: extension.id,
                      ),
                      if (!context.isMornye)
                        _InfoRow(
                          label: context.l10n.extensionsVersion(
                            extension.version,
                          ),
                          value: '',
                        ),
                      if (hasError && extension.errorMessage != null)
                        _InfoRow(
                          label: context.l10n.extensionError,
                          value: context.friendlyError(
                            extension.errorMessage,
                            fallback: context.l10n.extensionsErrorLoading,
                          ),
                          isError: true,
                        ),
                    ],
                  ),
                ),
              ),
            ),

            if (extension.settings.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionSettings,
                ),
              ),
              if (_isLoadingSettings)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                )
              else
                SliverToBoxAdapter(
                  child: SettingsGroup(
                    glass: true,
                    children: extension.settings.asMap().entries.map((entry) {
                      final index = entry.key;
                      final setting = entry.value;
                      return _SettingItem(
                        key: ValueKey(setting.key),
                        setting: setting,
                        value: _settings[setting.key] ?? setting.defaultValue,
                        showDivider: index < extension.settings.length - 1,
                        onChanged: (value) =>
                            _updateSetting(setting.key, value),
                        extensionId: widget.extensionId,
                        onActionPayload: _handleExtensionActionPayload,
                      );
                    }).toList(),
                  ),
                ),
            ],

            if (extension.hasServiceHealth) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionServiceStatus,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  children: [
                    _HealthSummaryItem(
                      status: healthStatus,
                      isRefreshing: _isRefreshingHealth,
                      onRefresh: () => _refreshHealth(force: true),
                    ),
                    if (healthStatus != null)
                      ...healthStatus.checks.asMap().entries.map((entry) {
                        final index = entry.key;
                        final check = entry.value;
                        return _HealthCheckItem(
                          check: check,
                          showDivider: index < healthStatus.checks.length - 1,
                        );
                      }),
                  ],
                ),
              ),
            ],

            if (extension.hasURLHandler &&
                extension.urlHandler!.patterns.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionUrlHandler,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  children: [
                    _URLHandlerInfo(patterns: extension.urlHandler!.patterns),
                  ],
                ),
              ),
            ],

            if (extension.hasDownloadProvider &&
                extension.qualityOptions.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionQualityOptions,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  children: extension.qualityOptions.asMap().entries.map((
                    entry,
                  ) {
                    final index = entry.key;
                    final quality = entry.value;
                    return _QualityOptionItem(
                      quality: quality,
                      showDivider: index < extension.qualityOptions.length - 1,
                    );
                  }).toList(),
                ),
              ),
            ],

            if (extension.hasPostProcessing &&
                extension.postProcessing!.hooks.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionPostProcessingHooks,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  children: extension.postProcessing!.hooks.asMap().entries.map(
                    (entry) {
                      final index = entry.key;
                      final hook = entry.value;
                      return _PostProcessingHookItem(
                        hook: hook,
                        showDivider:
                            index < extension.postProcessing!.hooks.length - 1,
                      );
                    },
                  ).toList(),
                ),
              ),
            ],

            if (extension.permissions.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: SettingsSectionHeader(
                  title: context.l10n.extensionPermissions,
                ),
              ),
              SliverToBoxAdapter(
                child: SettingsGroup(
                  glass: true,
                  children: extension.permissions.asMap().entries.map((entry) {
                    final index = entry.key;
                    final permission = entry.value;
                    return _PermissionItem(
                      permission: permission,
                      showDivider: index < extension.permissions.length - 1,
                    );
                  }).toList(),
                ),
              ),
            ],

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.extensionCapabilities,
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                glass: true,
                children: [
                  _CapabilityItem(
                    icon: Icons.search,
                    title: context.l10n.extensionMetadataProvider,
                    enabled: extension.hasMetadataProvider,
                  ),
                  _CapabilityItem(
                    icon: Icons.download,
                    title: context.l10n.extensionDownloadProvider,
                    enabled: extension.hasDownloadProvider,
                  ),
                  _CapabilityItem(
                    icon: Icons.lyrics,
                    title: context.l10n.extensionLyricsProvider,
                    enabled: extension.hasLyricsProvider,
                  ),
                  _CapabilityItem(
                    icon: Icons.manage_search,
                    title: context.l10n.extensionsSearchProvider,
                    enabled: extension.hasCustomSearch,
                    subtitle: extension.searchBehavior?.placeholder,
                  ),
                  _CapabilityItem(
                    icon: Icons.compare_arrows,
                    title: context.l10n.extensionCustomTrackMatching,
                    enabled: extension.hasCustomMatching,
                    subtitle: extension.trackMatching?.strategy != null
                        ? context.l10n.extensionStrategy(
                            extension.trackMatching!.strategy!,
                          )
                        : null,
                  ),
                  _CapabilityItem(
                    icon: Icons.auto_fix_high,
                    title: context.l10n.extensionPostProcessing,
                    enabled: extension.hasPostProcessing,
                    subtitle: extension.postProcessing?.hooks.isNotEmpty == true
                        ? context.l10n.extensionHooksAvailable(
                            extension.postProcessing!.hooks.length,
                          )
                        : null,
                  ),
                  _CapabilityItem(
                    icon: Icons.link,
                    title: context.l10n.extensionUrlHandler,
                    enabled: extension.hasURLHandler,
                    subtitle: extension.urlHandler?.patterns.isNotEmpty == true
                        ? context.l10n.extensionPatternsCount(
                            extension.urlHandler!.patterns.length,
                          )
                        : null,
                  ),
                  _CapabilityItem(
                    icon: Icons.monitor_heart_outlined,
                    title: context.l10n.extensionServiceHealth,
                    enabled: extension.hasServiceHealth,
                    subtitle: extension.hasServiceHealth
                        ? context.l10n.extensionHealthChecksConfigured(
                            extension.serviceHealth.length,
                          )
                        : null,
                    showDivider: false,
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AppDialogAction(
                  onPressed: () => _confirmRemove(context),
                  isDestructive: true,
                  outlined: true,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.error,
                    side: BorderSide(color: colorScheme.error),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        context.isMornye
                            ? CupertinoIcons.trash
                            : Icons.delete_outline,
                      ),
                      const SizedBox(width: 8),
                      Flexible(child: Text(context.l10n.extensionRemoveButton)),
                    ],
                  ),
                ),
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Future<void> _updateSetting(String key, dynamic value) async {
    setState(() {
      _settings[key] = value;
    });
    await ref
        .read(extensionProvider.notifier)
        .setExtensionSettings(widget.extensionId, _settings);
  }

  /// Extensions may return `setting_updates` from button actions (e.g. OAuth URL field).
  Future<void> _handleExtensionActionPayload(
    Map<String, dynamic> payload,
  ) async {
    final raw = payload['setting_updates'];
    if (raw is! Map) return;
    final partial = <String, dynamic>{};
    for (final entry in raw.entries) {
      partial[entry.key.toString()] = entry.value;
    }
    if (partial.isEmpty) return;
    final merged = Map<String, dynamic>.from(_settings);
    merged.addAll(partial);
    await ref
        .read(extensionProvider.notifier)
        .setExtensionSettings(widget.extensionId, merged);
    if (mounted) {
      setState(() => _settings = merged);
    }
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final colorScheme = Theme.of(context).colorScheme;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.dialogRemoveExtension),
        content: Text(context.l10n.dialogRemoveExtensionMessage),
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
            style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
            child: Text(context.l10n.dialogRemove),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await ref
          .read(extensionProvider.notifier)
          .removeExtension(widget.extensionId);
      if (success && mounted) {
        ref.read(repoProvider.notifier).refresh();
        Navigator.pop(this.context);
      }
    }
  }
}

class _ExtensionOverviewSurface extends StatelessWidget {
  const _ExtensionOverviewSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: const EdgeInsets.all(20), child: child);
    if (context.isMornye) return MornyeGlassPanel(child: content);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(20),
      ),
      child: content,
    );
  }
}

class _ExtensionDivider extends StatelessWidget {
  const _ExtensionDivider({this.indent = 56});

  final double indent;

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    indent: indent,
    endIndent: 16,
    color: context.isMornye
        ? MornyeTheme.metadataDividerColor(context)
        : Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
  );
}

/// Long OAuth URLs: selectable text so users can copy without relying on snackbars.
class _OauthLoginLinkPreview extends StatelessWidget {
  final String? value;
  final ColorScheme colorScheme;

  const _OauthLoginLinkPreview({
    required this.value,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return Text(
        context.l10n.extensionOauthConnectHint,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return SelectionArea(
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.primary,
          fontFamily: 'monospace',
          fontSize: 11,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isError;

  const _InfoRow({
    required this.label,
    required this.value,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isError ? colorScheme.error : colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool enabled;
  final bool showDivider;
  final String? subtitle;

  const _CapabilityItem({
    required this.icon,
    required this.title,
    required this.enabled,
    this.showDivider = true,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                context.adaptiveIcon(icon),
                color: context.isMornye || enabled
                    ? colorScheme.primary
                    : colorScheme.outline,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.bodyLarge),
                    if (subtitle != null && enabled) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                context.isMornye
                    ? (enabled
                          ? CupertinoIcons.check_mark_circled_solid
                          : CupertinoIcons.xmark_circle)
                    : (enabled ? Icons.check_circle : Icons.cancel_outlined),
                color: context.isMornye || enabled
                    ? colorScheme.primary
                    : colorScheme.outline,
              ),
            ],
          ),
        ),
        if (showDivider) const _ExtensionDivider(),
      ],
    );
  }
}

Color _healthStatusColor(BuildContext context, String status) {
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

IconData _healthStatusIcon(BuildContext context, String status) {
  if (context.isMornye) {
    return switch (status) {
      'online' => CupertinoIcons.check_mark_circled_solid,
      'degraded' => CupertinoIcons.exclamationmark_triangle,
      'offline' => CupertinoIcons.exclamationmark_circle,
      _ => CupertinoIcons.question_circle,
    };
  }
  switch (status) {
    case 'online':
      return Icons.check_circle;
    case 'degraded':
      return Icons.warning_amber_rounded;
    case 'offline':
      return Icons.error_outline;
    default:
      return Icons.help_outline;
  }
}

String _healthStatusLabel(BuildContext context, String status) {
  switch (status) {
    case 'online':
      return context.l10n.extensionHealthOnline;
    case 'degraded':
      return context.l10n.extensionHealthDegraded;
    case 'offline':
      return context.l10n.extensionHealthOffline;
    case 'unsupported':
      return context.l10n.extensionHealthNotConfigured;
    default:
      return context.l10n.extensionHealthUnknown;
  }
}

class _HealthSummaryItem extends StatelessWidget {
  final ExtensionHealthStatus? status;
  final bool isRefreshing;
  final VoidCallback onRefresh;

  const _HealthSummaryItem({
    required this.status,
    required this.isRefreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusValue = status?.status ?? 'unknown';
    final color = _healthStatusColor(context, statusValue);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(_healthStatusIcon(context, statusValue), color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _healthStatusLabel(context, statusValue),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (status?.checkedAt != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.extensionLastChecked(
                          TimeOfDay.fromDateTime(
                            status!.checkedAt!.toLocal(),
                          ).format(context),
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: context.l10n.extensionRefreshStatus,
                onPressed: isRefreshing ? null : onRefresh,
                icon: isRefreshing
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      )
                    : Icon(
                        context.isMornye
                            ? CupertinoIcons.refresh
                            : Icons.refresh,
                      ),
              ),
            ],
          ),
        ),
        const _ExtensionDivider(),
      ],
    );
  }
}

class _HealthCheckItem extends StatelessWidget {
  final ExtensionHealthCheckStatus check;
  final bool showDivider;

  const _HealthCheckItem({required this.check, this.showDivider = true});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = _healthStatusColor(context, check.status);
    final detailParts = <String>[
      _healthStatusLabel(context, check.status),
      if (check.httpStatus != null) 'HTTP ${check.httpStatus}',
      if (check.serviceKey?.isNotEmpty == true) check.serviceKey!,
      if (check.latencyMs > 0) '${check.latencyMs} ms',
      if (check.required) context.l10n.extensionHealthRequired,
    ];
    final message = check.error?.trim().isNotEmpty == true
        ? context.friendlyError(
            check.error,
            fallback: context.l10n.extensionHealthServiceUnknown,
          )
        : check.message;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_healthStatusIcon(context, check.status), color: color),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      check.displayLabel,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detailParts.join(' · '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (message != null && message.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: check.error != null
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (showDivider) const _ExtensionDivider(),
      ],
    );
  }
}

class _PermissionItem extends StatelessWidget {
  final String permission;
  final bool showDivider;

  const _PermissionItem({required this.permission, this.showDivider = true});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    IconData icon = Icons.security;
    String description = permission;

    if (permission.startsWith('network:')) {
      icon = Icons.language;
      description = 'Network access to: ${permission.substring(8)}';
    } else if (permission.startsWith('storage:')) {
      icon = Icons.folder;
      description = 'Storage access: ${permission.substring(8)}';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                context.adaptiveIcon(icon),
                color: context.isMornye
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  description,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        if (showDivider) const _ExtensionDivider(),
      ],
    );
  }
}

class _SettingItem extends StatefulWidget {
  final ExtensionSetting setting;
  final dynamic value;
  final bool showDivider;
  final ValueChanged<dynamic> onChanged;
  final String extensionId;
  final Future<void> Function(Map<String, dynamic> payload)? onActionPayload;

  const _SettingItem({
    super.key,
    required this.setting,
    required this.value,
    required this.onChanged,
    required this.extensionId,
    this.onActionPayload,
    this.showDivider = true,
  });

  @override
  State<_SettingItem> createState() => _SettingItemState();
}

class _SettingItemState extends State<_SettingItem> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget? trailing;
    Widget? footer;
    VoidCallback? onTap;
    switch (widget.setting.type) {
      case 'boolean':
        trailing = AppSwitch(
          value: widget.value as bool? ?? false,
          semanticLabel: widget.setting.label,
          onChanged: widget.onChanged,
        );
        onTap = () => widget.onChanged(!(widget.value as bool? ?? false));
        break;
      case 'select':
        onTap = widget.setting.options?.isNotEmpty == true
            ? _showOptions
            : null;
        footer = Text(
          widget.value?.toString() ?? context.l10n.extensionSettingNotSet,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
        );
        break;
      case 'button':
        onTap = _isLoading ? null : () => _invokeAction(context);
        if (_isLoading) {
          trailing = const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          );
        }
        break;
      case 'string':
      case 'number':
        onTap = () => _showEditDialog(context);
        footer = widget.setting.key == 'oauth_login_url'
            ? _OauthLoginLinkPreview(
                value: widget.value?.toString(),
                colorScheme: colorScheme,
              )
            : Text(
                widget.value?.toString() ?? context.l10n.extensionSettingNotSet,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
              );
        break;
    }
    return SettingsItem(
      title: widget.setting.label,
      subtitle: widget.setting.description?.isNotEmpty == true
          ? widget.setting.description
          : null,
      footer: footer,
      trailing: trailing,
      onTap: onTap,
      showDivider: widget.showDivider,
    );
  }

  Future<void> _showOptions() async {
    final value = await showAppBottomSheet<String>(
      context: context,
      title: widget.setting.label,
      maxHeightFactor: 0.7,
      builder: (sheetContext) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in widget.setting.options ?? <String>[])
              AppSheetOption(
                title: Text(option),
                trailing: option == widget.value
                    ? const Icon(CupertinoIcons.check_mark)
                    : null,
                onTap: () => Navigator.pop(sheetContext, option),
              ),
          ],
        ),
      ),
    );
    if (mounted && value != null) widget.onChanged(value);
  }

  Future<void> _invokeAction(BuildContext context) async {
    if (widget.setting.action == null) {
      showAppSnackBar(
        context,
        content: Text(context.l10n.snackbarNoActionDefined),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final result = await runExtensionActionWithForms(
        context,
        widget.extensionId,
        widget.setting.action!,
      );
      if (result == null) return;

      if (context.mounted) {
        // Go may return either a flat map or { success, result: { ... } }.
        Map<String, dynamic> payload = result;
        final nested = result['result'];
        if (nested is Map) {
          payload = Map<String, dynamic>.from(nested);
        }

        final success = payload['success'] as bool? ?? false;
        if (!success) {
          final error =
              payload['error'] as String? ??
              result['error'] as String? ??
              context.l10n.extensionActionFailed;
          showAppSnackBar(
            context,
            content: Text(
              context.friendlyError(
                error,
                fallback: context.l10n.extensionActionFailed,
              ),
            ),
          );
        } else {
          if (widget.onActionPayload != null) {
            await widget.onActionPayload!(payload);
          }
          final openAuth = payload['open_auth_url'] as String?;
          if (openAuth != null && openAuth.isNotEmpty) {
            final uri = Uri.parse(openAuth);
            final launched = await launchExtensionAuthUrl(
              uri,
              browserMode: 'external_first',
            );
            if (!launched && context.mounted) {
              showAppSnackBar(
                context,
                content: Text(
                  context.l10n.snackbarError('Could not open browser'),
                ),
              );
            }
          }
          final message = payload['message'] as String?;
          if (message != null && message.isNotEmpty && context.mounted) {
            showAppSnackBar(context, content: Text(message));
          }
        }
      }
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.snackbarError(context.friendlyError(e))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showEditDialog(BuildContext context) {
    final controller = TextEditingController(
      text: widget.value?.toString() ?? '',
    );
    final colorScheme = Theme.of(context).colorScheme;

    showAppDialog<void>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(widget.setting.label),
        content: context.isMornye
            ? Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CupertinoTextField(
                  controller: controller,
                  keyboardType: widget.setting.type == 'number'
                      ? TextInputType.number
                      : TextInputType.text,
                  placeholder:
                      widget.setting.description ??
                      context.l10n.extensionEnterValue,
                  padding: const EdgeInsets.all(12),
                ),
              )
            : TextField(
                controller: controller,
                keyboardType: widget.setting.type == 'number'
                    ? TextInputType.number
                    : TextInputType.text,
                decoration: InputDecoration(
                  hintText:
                      widget.setting.description ??
                      context.l10n.extensionEnterValue,
                  filled: true,
                  fillColor: colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.3,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
        actions: [
          AppDialogAction(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dialogCancel),
          ),
          AppDialogAction(
            filled: true,
            isDefault: true,
            onPressed: () {
              final newValue = widget.setting.type == 'number'
                  ? num.tryParse(controller.text)
                  : controller.text;
              widget.onChanged(newValue);
              Navigator.pop(context);
            },
            child: Text(context.l10n.dialogSave),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }
}

class _PostProcessingHookItem extends StatelessWidget {
  final PostProcessingHook hook;
  final bool showDivider;

  const _PostProcessingHookItem({required this.hook, this.showDivider = true});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: context.isMornye
                      ? Colors.transparent
                      : colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  context.isMornye
                      ? CupertinoIcons.wand_stars
                      : Icons.auto_fix_high,
                  color: context.isMornye
                      ? colorScheme.primary
                      : colorScheme.onTertiaryContainer,
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hook.name,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (hook.description != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        hook.description!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (hook.supportedFormats.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        children: hook.supportedFormats.map((format) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              format.toUpperCase(),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              if (hook.defaultEnabled)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    context.l10n.extensionsHomeFeedAuto,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (showDivider) const _ExtensionDivider(indent: 72),
      ],
    );
  }
}

class _URLHandlerInfo extends StatelessWidget {
  final List<String> patterns;

  const _URLHandlerInfo({required this.patterns});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: context.isMornye
                      ? Colors.transparent
                      : colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  context.isMornye ? CupertinoIcons.link : Icons.link,
                  color: context.isMornye
                      ? colorScheme.primary
                      : colorScheme.onTertiaryContainer,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.extensionCustomUrlHandling,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.extensionCustomUrlHandlingSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: patterns.map((pattern) {
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.language, size: 16, color: colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      pattern,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 20, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    context.l10n.extensionCustomUrlHandlingShareHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QualityOptionItem extends StatelessWidget {
  final QualityOption quality;
  final bool showDivider;

  const _QualityOptionItem({required this.quality, this.showDivider = true});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: context.isMornye
                      ? Colors.transparent
                      : colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  context.isMornye
                      ? CupertinoIcons.waveform
                      : Icons.high_quality,
                  color: context.isMornye
                      ? colorScheme.primary
                      : colorScheme.onSecondaryContainer,
                  size: 20,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      quality.label,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (quality.description != null &&
                        quality.description!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        quality.description!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (!context.isMornye) ...[
                      const SizedBox(height: 4),
                      Text(
                        quality.id,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.primary,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (quality.settings.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    context.l10n.extensionSettingsCount(
                      quality.settings.length,
                    ),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (showDivider) const _ExtensionDivider(indent: 72),
      ],
    );
  }
}
