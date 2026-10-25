import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/controllers/player_metadata_controller.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/utils/playback_seek_preview.dart';
import 'package:mosix/utils/string_utils.dart';
import 'package:mosix/widgets/app_loading_indicator.dart';
import 'package:mosix/widgets/automix_status_badge.dart';
import 'package:mosix/widgets/expressive_icon_button.dart';
import 'package:mosix/widgets/mornye_playback_button.dart';
import 'package:mosix/widgets/mornye_playback_time.dart';
import 'package:mosix/widgets/mornye_player_slider.dart';
import 'package:mosix/widgets/playback_seek_slider.dart';

const _mornyeTimelinePadding = 28.0;

class PlayerPlaybackControls extends ConsumerWidget {
  final String mediaId;
  final Duration duration;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final PlayerMetadataController metadata;
  final bool compact;
  final double transportTopPadding;

  const PlayerPlaybackControls({
    super.key,
    required this.mediaId,
    required this.duration,
    required this.seekPreview,
    required this.colorScheme,
    required this.metadata,
    this.compact = false,
    this.transportTopPadding = 16,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(musicPlayerControllerProvider);
    final mornye = context.isMornye;
    final isPlaying = ref.watch(playbackPlayingProvider);
    final isLoading = ref.watch(playbackLoadingProvider);
    final playPauseSize = compact
        ? (isPlaying ? 44.0 : 40.0)
        : (isPlaying ? 60.0 : 54.0);
    final timeStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant);
    return Column(
      children: [
        ValueListenableBuilder<Duration?>(
          valueListenable: seekPreview,
          builder: (context, preview, _) => Consumer(
            builder: (context, ref, quality) {
              final position = ref.watch(playbackPositionProvider);
              final elapsedSeconds = (preview ?? position).inSeconds;
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: mornye ? _mornyeTimelinePadding : 16,
                ),
                child: Column(
                  children: [
                    SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 4,
                        activeTrackColor: mornye
                            ? colorScheme.onSurface
                            : colorScheme.primary,
                        inactiveTrackColor: colorScheme.onSurface.withValues(
                          alpha: 0.18,
                        ),
                        thumbColor: mornye
                            ? colorScheme.onSurface
                            : colorScheme.primary,
                        // A 7dp thumb was hard to grab; 10dp with a 24dp overlay
                        // gives the drag gesture a full-size target.
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 10,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 24,
                        ),
                      ),
                      child: PlaybackSeekSlider(
                        key: ValueKey(mediaId),
                        position: position,
                        duration: duration,
                        onSeek: controller.seek,
                        preview: seekPreview,
                        playing: isPlaying && !isLoading,
                      ),
                    ),
                    if (!mornye) const SizedBox(height: 8),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: mornye
                            ? MornyePlayerSlider.horizontalInset
                            : 12,
                      ),
                      child: Row(
                        children: [
                          if (mornye)
                            MornyePlaybackTime(
                              key: ValueKey('elapsed:$mediaId'),
                              seconds: elapsedSeconds,
                              style: timeStyle,
                            )
                          else
                            Text(formatClock(elapsedSeconds), style: timeStyle),
                          Expanded(child: Center(child: quality)),
                          if (mornye)
                            MornyePlaybackTime(
                              key: ValueKey('remaining:$mediaId'),
                              // Subtract whole seconds so both labels roll together,
                              // even when the track duration includes milliseconds.
                              seconds: (duration.inSeconds - elapsedSeconds)
                                  .clamp(0, duration.inSeconds),
                              remaining: true,
                              style: timeStyle,
                            )
                          else
                            Text(
                              formatClock(duration.inSeconds),
                              style: timeStyle,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _QualityBadge(metadata: metadata, colorScheme: colorScheme),
                const AutoMixStatusBadge(),
              ],
            ),
          ),
        ),
        SizedBox(height: compact ? 8 : transportTopPadding + (mornye ? 0 : 8)),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: mornye ? (compact ? 16 : 32) : 0,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (!mornye)
                PlayerPlaybackModeButton(
                  mode: PlayerPlaybackMode.shuffle,
                  colorScheme: colorScheme,
                ),
              if (mornye)
                MornyePlaybackButton(
                  icon: CupertinoIcons.backward_fill,
                  color: colorScheme.onSurface,
                  tooltip: context.l10n.nowPlayingPreviousTrack,
                  onPressed: controller.previous,
                )
              else
                ExpressiveIconButton(
                  iconSize: 44,
                  foregroundColor: colorScheme.onSurface,
                  tooltip: context.l10n.nowPlayingPreviousTrack,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: controller.previous,
                ),
              if (mornye)
                MornyePlaybackButton(
                  icon: isPlaying
                      ? CupertinoIcons.pause_fill
                      : CupertinoIcons.play_fill,
                  tooltip: isPlaying
                      ? context.l10n.actionPause
                      : context.l10n.tooltipPlay,
                  color: colorScheme.onSurface,
                  iconSize: playPauseSize,
                  // A smaller play glyph keeps the same 68dp touch target and
                  // does not move the timeline, artwork or adjacent buttons.
                  padding: EdgeInsets.all((68 - playPauseSize) / 2),
                  loading: isLoading,
                  onPressed: () => controller.togglePlayPause(isPlaying),
                )
              else
                ExpressiveIconButton(
                  size: 68,
                  iconSize: 44,
                  selected: isPlaying,
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  tooltip: isPlaying
                      ? context.l10n.actionPause
                      : context.l10n.tooltipPlay,
                  icon: isLoading
                      ? AppLoadingIndicator(color: colorScheme.onSurfaceVariant)
                      : Icon(isPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: isLoading
                      ? null
                      : () => controller.togglePlayPause(isPlaying),
                ),
              if (mornye)
                MornyePlaybackButton(
                  icon: CupertinoIcons.forward_fill,
                  color: colorScheme.onSurface,
                  tooltip: context.l10n.nowPlayingNextTrack,
                  onPressed: controller.next,
                )
              else
                ExpressiveIconButton(
                  iconSize: 44,
                  foregroundColor: colorScheme.onSurface,
                  tooltip: context.l10n.nowPlayingNextTrack,
                  icon: const Icon(Icons.skip_next),
                  onPressed: controller.next,
                ),
              if (!mornye)
                PlayerPlaybackModeButton(
                  mode: PlayerPlaybackMode.repeat,
                  colorScheme: colorScheme,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

enum PlayerPlaybackMode { autoplay, repeat, shuffle }

/// Queue and transport buttons share behavior while keeping independent watches.
class PlayerPlaybackModeButton extends ConsumerWidget {
  const PlayerPlaybackModeButton({
    super.key,
    required this.mode,
    required this.colorScheme,
    this.secondary = false,
  });

  final PlayerPlaybackMode mode;
  final ColorScheme colorScheme;
  final bool secondary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(musicPlayerControllerProvider);
    late final bool selected;
    late final IconData icon;
    late final String tooltip;
    late final VoidCallback onPressed;
    switch (mode) {
      case PlayerPlaybackMode.autoplay:
        selected = ref.watch(
          settingsProvider.select((settings) => settings.autoplay),
        );
        icon = Icons.all_inclusive;
        tooltip = selected ? context.l10n.autoplayOn : context.l10n.autoplayOff;
        onPressed = () =>
            ref.read(settingsProvider.notifier).setAutoplay(!selected);
      case PlayerPlaybackMode.shuffle:
        selected = ref.watch(
          playbackStateProvider.select(
            (state) => state.value?.shuffleMode == AudioServiceShuffleMode.all,
          ),
        );
        icon = Icons.shuffle;
        tooltip = selected
            ? context.l10n.nowPlayingShuffleOn
            : context.l10n.nowPlayingPlayInOrder;
        onPressed = () => controller.setShuffle(!selected);
      case PlayerPlaybackMode.repeat:
        final repeatMode = ref.watch(
          playbackStateProvider.select(
            (state) => state.value?.repeatMode ?? AudioServiceRepeatMode.none,
          ),
        );
        selected = repeatMode != AudioServiceRepeatMode.none;
        icon = repeatMode == AudioServiceRepeatMode.one
            ? Icons.repeat_one
            : Icons.repeat;
        tooltip = switch (repeatMode) {
          AudioServiceRepeatMode.one => context.l10n.nowPlayingRepeatOne,
          AudioServiceRepeatMode.none => context.l10n.nowPlayingRepeatOff,
          _ => context.l10n.nowPlayingRepeatAll,
        };
        onPressed = () => controller.setRepeatMode(switch (repeatMode) {
          AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
          AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
          _ => AudioServiceRepeatMode.none,
        });
    }
    return ExpressiveIconButton(
      iconSize: 24,
      selected: selected,
      tooltip: tooltip,
      icon: Icon(icon),
      foregroundColor: selected
          ? (secondary ? colorScheme.onSecondaryContainer : colorScheme.primary)
          : colorScheme.onSurfaceVariant,
      backgroundColor: selected
          ? (secondary
                ? colorScheme.secondaryContainer
                : colorScheme.primaryContainer)
          : null,
      onPressed: onPressed,
    );
  }
}

class _QualityBadge extends StatelessWidget {
  final PlayerMetadataController metadata;
  final ColorScheme colorScheme;

  const _QualityBadge({required this.metadata, required this.colorScheme});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: metadata,
    builder: (context, _) => _buildBadge(context),
  );

  Widget _buildBadge(BuildContext context) {
    final text = metadata.qualityLabel;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    final mornye = context.isMornye;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: mornye ? 8 : 10,
        vertical: mornye ? 2 : 5,
      ),
      decoration: mornye
          ? null
          : BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(20),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.graphic_eq,
            size: mornye ? 11 : 14,
            color: colorScheme.onSurfaceVariant,
          ),
          SizedBox(width: mornye ? 5 : 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: mornye ? 10.5 : 12,
                color: colorScheme.onSurfaceVariant,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
