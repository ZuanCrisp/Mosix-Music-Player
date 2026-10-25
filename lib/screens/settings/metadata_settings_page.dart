import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/screens/settings/metadata_provider_priority_page.dart';
import 'package:mornye/screens/settings/metadata_separator_settings_page.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';

class MetadataSettingsPage extends ConsumerWidget {
  const MetadataSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return PopScope(
      canPop: true,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            AppSliverHeader.page(title: context.l10n.settingsMetadata),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(title: context.l10n.sectionDownload),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsSwitchItem(
                    icon: Icons.sell_outlined,
                    title: context.l10n.optionsEmbedMetadata,
                    subtitle: settings.embedMetadata
                        ? context.l10n.optionsEmbedMetadataSubtitleOn
                        : context.l10n.optionsEmbedMetadataSubtitleOff,
                    value: settings.embedMetadata,
                    onChanged: (v) =>
                        ref.read(settingsProvider.notifier).setEmbedMetadata(v),
                    showDivider: settings.embedMetadata,
                  ),
                  if (settings.embedMetadata) ...[
                    SettingsItem(
                      icon: Icons.people_alt_outlined,
                      title: context.l10n.optionsArtistTagMode,
                      subtitle: _getArtistTagModeLabel(
                        context,
                        settings.artistTagMode,
                      ),
                      onTap: () => _showArtistTagModePicker(
                        context,
                        ref,
                        settings.artistTagMode,
                      ),
                    ),
                    SettingsItem(
                      icon: Icons.format_list_bulleted,
                      title: context.l10n.metadataSeparators,
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => const MetadataSeparatorSettingsPage(),
                        ),
                      ),
                    ),
                    SettingsItem(
                      icon: Icons.photo_size_select_large_outlined,
                      title: context.l10n.optionsEmbeddedCoverSize,
                      subtitle: _getEmbeddedCoverSizeLabel(
                        context,
                        settings.embeddedCoverMaxDimension,
                      ),
                      onTap: () => _showEmbeddedCoverSizePicker(
                        context,
                        ref,
                        settings.embeddedCoverMaxDimension,
                      ),
                    ),
                    SettingsSwitchItem(
                      icon: Icons.graphic_eq,
                      title: context.l10n.optionsReplayGain,
                      subtitle: settings.embedReplayGain
                          ? context.l10n.optionsReplayGainSubtitleOn
                          : context.l10n.optionsReplayGainSubtitleOff,
                      value: settings.embedReplayGain,
                      onChanged: (v) => ref
                          .read(settingsProvider.notifier)
                          .setEmbedReplayGain(v),
                      showDivider: false,
                    ),
                  ],
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.sectionMetadataProviders,
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsItem(
                    icon: Icons.source_outlined,
                    title: context.l10n.metadataProvidersTitle,
                    subtitle: context.l10n.metadataProvidersSubtitle,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const MetadataProviderPriorityPage(),
                      ),
                    ),
                    showDivider: false,
                  ),
                ],
              ),
            ),

            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.sectionDuplicates,
              ),
            ),
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  SettingsSwitchItem(
                    icon: Icons.filter_list_outlined,
                    title: context.l10n.downloadDeduplication,
                    subtitle: settings.deduplicateDownloads
                        ? settings.allowQualityVariants
                              ? context
                                    .l10n
                                    .downloadDeduplicationWithQualityVariants
                              : context.l10n.downloadDeduplicationEnabled
                        : context.l10n.downloadDeduplicationDisabled,
                    value: settings.deduplicateDownloads,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setDeduplicateDownloads(value),
                  ),
                  SettingsSwitchItem(
                    icon: Icons.library_music_outlined,
                    title: context.l10n.downloadQualityVariants,
                    subtitle: context.l10n.downloadQualityVariantsDescription,
                    value: settings.allowQualityVariants,
                    onChanged: (value) => ref
                        .read(settingsProvider.notifier)
                        .setAllowQualityVariants(value),
                    showDivider: false,
                  ),
                ],
              ),
            ),

            const SliverToBoxAdapter(child: SizedBox(height: 32)),
            const NavBarSliverSpacer(),
          ],
        ),
      ),
    );
  }

  String _getArtistTagModeLabel(BuildContext context, String mode) {
    switch (mode) {
      case artistTagModeSplitVorbis:
        return context.l10n.optionsArtistTagModeSplitVorbis;
      case artistTagModePrimary:
        return context.l10n.optionsArtistTagModePrimary;
      default:
        return context.l10n.optionsArtistTagModeJoined;
    }
  }

  String _getEmbeddedCoverSizeLabel(BuildContext context, int maxDimension) {
    if (maxDimension <= 0) {
      return context.l10n.optionsEmbeddedCoverSizeOriginal;
    }
    return '$maxDimension × $maxDimension px';
  }

  void _showEmbeddedCoverSizePicker(
    BuildContext context,
    WidgetRef ref,
    int currentMaxDimension,
  ) {
    const options = [0, 500, 1000, 1500, 2000];
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.optionsEmbeddedCoverSize,
      subtitle: context.l10n.optionsEmbeddedCoverSizeDescription,
      builder: (context, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final maxDimension in options)
              AppSheetOption.choice(
                leading: AppIcon(
                  maxDimension == 0
                      ? Icons.image_outlined
                      : Icons.compress_outlined,
                ),
                title: Text(_getEmbeddedCoverSizeLabel(context, maxDimension)),
                selected: currentMaxDimension == maxDimension,
                onTap: () {
                  ref
                      .read(settingsProvider.notifier)
                      .setEmbeddedCoverMaxDimension(maxDimension);
                  Navigator.pop(context);
                },
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showArtistTagModePicker(
    BuildContext context,
    WidgetRef ref,
    String currentMode,
  ) {
    showAppScrollableBottomSheet<void>(
      context: context,
      title: context.l10n.optionsArtistTagMode,
      subtitle: context.l10n.optionsArtistTagModeDescription,
      builder: (context, controller) => SingleChildScrollView(
        controller: controller,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSheetOption.choice(
              leading: const AppIcon(Icons.segment_outlined),
              title: Text(context.l10n.optionsArtistTagModeJoined),
              subtitle: Text(context.l10n.optionsArtistTagModeJoinedSubtitle),
              selected: currentMode == artistTagModeJoined,
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setArtistTagMode(artistTagModeJoined);
                Navigator.pop(context);
              },
            ),
            AppSheetOption.choice(
              leading: const AppIcon(Icons.library_music_outlined),
              title: Text(context.l10n.optionsArtistTagModeSplitVorbis),
              subtitle: Text(
                context.l10n.optionsArtistTagModeSplitVorbisSubtitle,
              ),
              selected: currentMode == artistTagModeSplitVorbis,
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setArtistTagMode(artistTagModeSplitVorbis);
                Navigator.pop(context);
              },
            ),
            AppSheetOption.choice(
              leading: const AppIcon(Icons.person_outline),
              title: Text(context.l10n.optionsArtistTagModePrimary),
              subtitle: Text(context.l10n.optionsArtistTagModePrimarySubtitle),
              selected: currentMode == artistTagModePrimary,
              onTap: () {
                ref
                    .read(settingsProvider.notifier)
                    .setArtistTagMode(artistTagModePrimary);
                Navigator.pop(context);
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
