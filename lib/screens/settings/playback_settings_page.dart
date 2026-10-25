import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/services/music_playback_deck.dart';
import 'package:mosix/services/music_player_service.dart'
    show resetAutoplayLearning;
import 'package:mosix/screens/listening_statistics_screen.dart';
import 'package:mosix/widgets/animation_utils.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';
import 'package:mosix/widgets/app_sliver_header.dart';
import 'package:mosix/widgets/mornye_volume_control.dart';
import 'package:mosix/widgets/settings_group.dart';
import 'package:mosix/widgets/discord_presence_settings.dart';
import 'package:mosix/widgets/automix_settings.dart';

class PlaybackSettingsPage extends ConsumerStatefulWidget {
  const PlaybackSettingsPage({super.key});

  @override
  ConsumerState<PlaybackSettingsPage> createState() =>
      _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends ConsumerState<PlaybackSettingsPage> {
  Future<bool> _confirmAudioVolume(String message) async {
    return await showAppDialog<bool>(
          context: context,
          builder: (context) => AppAlertDialog(
            title: Text(context.l10n.usbVolumeWarningTitle),
            content: Text(message),
            actions: [
              AppDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.l10n.dialogCancel),
              ),
              AppDialogAction(
                onPressed: () => Navigator.pop(context, true),
                child: Text(context.l10n.usbVolumeAccept),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.libraryPlayback),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(title: context.l10n.sectionPlayer),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.open_in_new,
                  title: context.l10n.libraryExternalPlayer,
                  subtitle: context.l10n.libraryExternalPlayerSubtitle,
                  trailing: settings.playerMode == 'external'
                      ? Icon(Icons.check, color: colorScheme.primary)
                      : null,
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .setPlayerMode('external'),
                ),
                SettingsItem(
                  icon: Icons.play_circle_outline,
                  title: context.l10n.libraryBuiltInPreviewPlayer,
                  subtitle: context.l10n.libraryBuiltInPreviewPlayerSubtitle,
                  trailing: settings.playerMode == 'internal'
                      ? Icon(Icons.check, color: colorScheme.primary)
                      : null,
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .setPlayerMode('internal'),
                  showDivider: false,
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(
              title: context.l10n.sectionVolumeAndTransitions,
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsSwitchItem(
                  icon: Icons.graphic_eq,
                  title: context.l10n.libraryPlaybackNormalization,
                  subtitle: context.l10n.libraryPlaybackNormalizationSubtitle,
                  value: settings.playbackNormalization,
                  enabled: !settings.usbBitPerfect,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setPlaybackNormalization(value),
                ),
                SettingsSwitchItem(
                  icon: Icons.compare_arrows,
                  title: 'AutoMix',
                  subtitle: context.l10n.autoMixDescription,
                  value: settings.autoMix,
                  enabled: !settings.usbBitPerfect,
                  onChanged: (value) =>
                      ref.read(settingsProvider.notifier).setAutoMix(value),
                  showDivider: false,
                ),
              ],
            ),
          ),
          if (settings.autoMix) ...[
            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.autoMixSettingsTitle,
              ),
            ),
            const SliverToBoxAdapter(child: AutoMixSettings()),
          ],
          SliverToBoxAdapter(
            child: SettingsSectionHeader(
              title: context.l10n.autoplayFromLibrary,
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsSwitchItem(
                  icon: Icons.playlist_play_rounded,
                  title: context.l10n.autoplayFromLibrary,
                  subtitle: context.l10n.autoplayDescription,
                  value: settings.autoplay,
                  enabled: settings.playerMode == 'internal',
                  onChanged: (value) =>
                      ref.read(settingsProvider.notifier).setAutoplay(value),
                ),
                SettingsSwitchItem(
                  icon: Icons.auto_awesome_outlined,
                  title: context.l10n.autoplayPersonalization,
                  subtitle: context.l10n.autoplayPersonalizationDescription,
                  value: settings.autoplayPersonalization,
                  enabled: settings.playerMode == 'internal',
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setAutoplayPersonalization(value),
                  showDivider: settings.autoplayPersonalization,
                ),
                if (settings.autoplayPersonalization)
                  SettingsItem(
                    icon: Icons.restart_alt,
                    title: context.l10n.autoplayResetLearning,
                    onTap: resetAutoplayLearning,
                    showDivider: false,
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(
              title: context.l10n.playbackAutomation,
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsSwitchItem(
                  icon: Icons.volume_off_outlined,
                  title: context.l10n.playbackPauseOnMute,
                  subtitle: context.l10n.playbackPauseOnMuteDescription,
                  value: settings.pauseOnMute,
                  enabled:
                      settings.playerMode == 'internal' &&
                      !settings.usbBitPerfect,
                  onChanged: (value) =>
                      ref.read(settingsProvider.notifier).setPauseOnMute(value),
                ),
                SettingsSwitchItem(
                  icon: Icons.headphones_outlined,
                  title: context.l10n.playbackOnHeadphonesConnected,
                  subtitle:
                      context.l10n.playbackOnHeadphonesConnectedDescription,
                  value: settings.playOnHeadphonesConnected,
                  enabled: settings.playerMode == 'internal',
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setPlayOnHeadphonesConnected(value),
                  showDivider: false,
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(title: context.l10n.motionArtwork),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsSwitchItem(
                  icon: Icons.motion_photos_on_outlined,
                  title: context.l10n.motionArtwork,
                  subtitle: context.l10n.motionArtworkDescription,
                  value: settings.motionArtworkEnabled,
                  onChanged: (value) => ref
                      .read(settingsProvider.notifier)
                      .setMotionArtworkEnabled(value),
                  showDivider: false,
                ),
              ],
            ),
          ),
          if (Platform.isAndroid || Platform.isIOS) ...[
            const SliverToBoxAdapter(
              child: SettingsSectionHeader(title: 'Discord'),
            ),
            const SliverToBoxAdapter(child: DiscordPresenceSettings()),
          ],
          if (Platform.isAndroid)
            SliverToBoxAdapter(
              child: SettingsSectionHeader(
                title: context.l10n.sectionAudioOutput,
              ),
            ),
          if (Platform.isAndroid)
            SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  ValueListenableBuilder<UsbAudioStatus>(
                    valueListenable: usbAudioStatus,
                    builder: (context, status, _) => SettingsSwitchItem(
                      icon: Icons.usb,
                      title: context.l10n.usbBitPerfect,
                      titleTrailing: const _PlaybackBetaBadge(),
                      subtitle: [
                        context.l10n.usbBitPerfectDescription,
                        if (settings.usbBitPerfect)
                          switch (status.reason) {
                            'active' =>
                              '${status.device} · ${status.transport == 'pcm'
                                  ? '${status.bitDepth}-bit PCM'
                                  : status.transport == 'dop'
                                  ? 'DSD (DoP)'
                                  : 'DSD (Native)'} · ${(status.sampleRate! / 1000).toStringAsFixed(1)} kHz',
                            'dsd_unsupported' => context.l10n.usbDsdUnsupported,
                            'volume_unavailable' =>
                              context.l10n.usbVolumeUnavailable,
                            'exclusive_unavailable' =>
                              context.l10n.dapExclusiveUnavailable,
                            'permission_denied' =>
                              context.l10n.usbPermissionDenied,
                            'no_usb' => context.l10n.usbBitPerfectNoDevice,
                            'route_changed' =>
                              context.l10n.usbBitPerfectRouteChanged,
                            'android_version' ||
                            'unsupported' ||
                            'format' => context.l10n.usbBitPerfectFallback,
                            _ => context.l10n.usbBitPerfectPending,
                          },
                      ].join('\n\n'),
                      value: settings.usbBitPerfect,
                      onChanged: (value) async {
                        if (value &&
                            !await _confirmAudioVolume(
                              context.l10n.usbVolumeWarning,
                            )) {
                          return;
                        }
                        if (mounted) {
                          ref
                              .read(settingsProvider.notifier)
                              .setUsbBitPerfect(value);
                        }
                      },
                      showDivider: settings.usbBitPerfect,
                    ),
                  ),
                  if (settings.usbBitPerfect) ...[
                    SettingsSwitchItem(
                      icon: Icons.usb,
                      title: context.l10n.usbDirect,
                      subtitle: context.l10n.usbDirectDescription,
                      value: settings.usbDirect,
                      onChanged: (value) async {
                        if (value &&
                            !await _confirmAudioVolume(
                              context.l10n.usbVolumeWarning,
                            )) {
                          return;
                        }
                        if (mounted) {
                          ref
                              .read(settingsProvider.notifier)
                              .setUsbDirect(value);
                        }
                      },
                    ),
                    if (settings.usbDirect) ...[
                      SettingsSwitchItem(
                        icon: Icons.graphic_eq,
                        title: context.l10n.usbDsdOverPcm,
                        subtitle: context.l10n.usbDsdOverPcmDescription,
                        value: settings.usbDsdOverPcm,
                        onChanged: (value) => ref
                            .read(settingsProvider.notifier)
                            .setUsbDsdOverPcm(value),
                      ),
                      SettingsSwitchItem(
                        icon: Icons.volume_up_outlined,
                        title: context.l10n.usbFixedVolume,
                        subtitle: context.l10n.usbFixedVolumeDescription,
                        value: settings.usbAllowFixedVolume,
                        onChanged: (value) async {
                          if (value &&
                              !await _confirmAudioVolume(
                                context.l10n.usbFixedVolumeWarning,
                              )) {
                            return;
                          }
                          if (mounted) {
                            ref
                                .read(settingsProvider.notifier)
                                .setUsbAllowFixedVolume(value);
                          }
                        },
                      ),
                      ValueListenableBuilder<UsbVolumeState?>(
                        valueListenable: usbHardwareVolume,
                        builder: (context, volume, _) => Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.usbHardwareVolume,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              Text(
                                volume == null
                                    ? context.l10n.usbBitPerfectPending
                                    : volume.available
                                    ? '${volume.currentDb.toStringAsFixed(1)} dB'
                                    : context.l10n.usbVolumeUnavailable,
                              ),
                              if (volume?.available == true)
                                MornyeVolumeControl(
                                  foreground: colorScheme.onSurface,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    SettingsSwitchItem(
                      icon: Icons.headphones,
                      title: context.l10n.dapExclusive,
                      titleTrailing: const _PlaybackBetaBadge(),
                      subtitle: context.l10n.dapExclusiveDescription,
                      value: settings.dapExclusive,
                      onChanged: (value) => ref
                          .read(settingsProvider.notifier)
                          .setDapExclusive(value),
                      showDivider: false,
                    ),
                  ],
                ],
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
          SliverToBoxAdapter(
            child: SettingsSectionHeader(title: context.l10n.listeningStats),
          ),
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsItem(
                  icon: Icons.insights_outlined,
                  title: context.l10n.listeningStats,
                  subtitle: context.l10n.listeningStatsDescription,
                  onTap: () => Navigator.of(context).push(
                    slidePageRoute<void>(
                      page: const ListeningStatisticsScreen(),
                    ),
                  ),
                  showDivider: false,
                ),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

class _PlaybackBetaBadge extends StatelessWidget {
  const _PlaybackBetaBadge();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'Beta',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
