import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/providers/player_motion_artwork_provider.dart';
import 'package:mosix/providers/player_artwork_video_provider.dart';
import 'package:mosix/providers/runtime_profile_provider.dart';
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/screens/now_playing_screen.dart';
import 'package:mosix/utils/string_utils.dart';
import 'package:mosix/widgets/audio_quality_badges.dart';
import 'package:mosix/widgets/overflow_marquee.dart';
import 'package:mosix/widgets/player_artwork.dart';
import 'package:mosix/widgets/settings_group.dart';
import 'package:mosix/widgets/mornye_chrome.dart';

class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key, this.compact = false, this.bottomPadding = 8});

  final bool compact;
  final double bottomPadding;

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  final _surfaceKey = GlobalKey();
  final _artworkKey = GlobalKey();

  Rect? _bounds(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final overlay = Navigator.of(
      context,
      rootNavigator: true,
    ).overlay?.context.findRenderObject();
    return MatrixUtils.transformRect(
      box.getTransformTo(overlay),
      Offset.zero & box.size,
    );
  }

  // Hides the bar in the frames between a swipe-dismiss and the stopped
  // service clearing the media item (a dismissed Dismissible must leave the
  // tree immediately). Playing the same track again shows the bar normally.
  String? _dismissedItemId;

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    if (mediaItem == null) return const SizedBox.shrink();

    final isPlaying = ref.watch(playbackPlayingProvider);
    final isLoading = ref.watch(playbackLoadingProvider);
    if (mediaItem.id == _dismissedItemId && !isPlaying) {
      return const SizedBox.shrink();
    }

    final controller = ref.read(musicPlayerControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final mornye = context.isMornye;
    final compact = mornye && widget.compact;
    // Frosted and flat glass levels run on constrained Android hardware. They
    // skip keeping a paused video decoder for the full player's motion cover,
    // and stop the title marquee after a few passes: every marquee frame
    // re-filters the blurred chrome around it.
    final fullEffects = !mornye || ref.watch(mornyeLiquidGlassProvider);
    final marqueeCycles = fullEffects ? null : 2;
    if (mornye &&
        fullEffects &&
        ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled)) &&
        !MediaQuery.disableAnimationsOf(context)) {
      final artwork = ref
          .watch(
            playerMotionArtworkProvider((
              album: mediaItem.album ?? '',
              artist: mediaItem.artist ?? '',
            )),
          )
          .value;
      if (artwork != null) {
        ref.watch(playerArtworkVideoProvider(artwork.source));
      }
    }

    final player = Dismissible(
      key: ValueKey('mini-player-${mediaItem.id}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) {
        setState(() => _dismissedItemId = mediaItem.id);
        controller.stop();
      },
      child: DecoratedBox(
        key: _surfaceKey,
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: mornye
              ? null
              : Border(
                  top: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
        ),
        child: Material(
          color: mornye
              ? Colors.transparent
              : settingsGroupColor(context).withValues(alpha: 0.72),
          child: InkWell(
            onTap: () {
              Navigator.of(context, rootNavigator: true).push(
                NowPlayingRoute(
                  child: const NowPlayingScreen(),
                  miniPlayerGeometry: mornye
                      ? () {
                          if (!mounted) return null;
                          final surface = _bounds(_surfaceKey);
                          final artwork = _bounds(_artworkKey);
                          if (surface == null || artwork == null) return null;
                          return (surface: surface, artwork: artwork);
                        }
                      : null,
                ),
              );
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!mornye)
                  _MiniPlayerProgress(
                    duration: mediaItem.duration ?? Duration.zero,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  ),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 8 : 12,
                    vertical: mornye ? 0 : 8,
                  ),
                  child: Row(
                    children: [
                      Hero(
                        tag: kNowPlayingArtworkHeroTag,
                        child: ClipRRect(
                          key: _artworkKey,
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: context.tokens.coverMini,
                            height: context.tokens.coverMini,
                            child: PlayerArtwork(
                              artUri: mediaItem.artUri?.toString(),
                              colorScheme: colorScheme,
                              cacheWidth: 132,
                              iconSize: 22,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: compact ? 8 : 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OverflowMarquee(
                              resetKey: (mediaItem.id, mediaItem.title),
                              maxCycles: marqueeCycles,
                              child: ExplicitTrackTitle(
                                title: mediaItem.title,
                                explicit:
                                    parseExplicitFlag(
                                      mediaItem.extras?['explicit'],
                                    ) ==
                                    true,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            OverflowMarquee(
                              resetKey: (mediaItem.id, mediaItem.artist),
                              maxCycles: marqueeCycles,
                              child: Text(
                                mediaItem.artist ?? '',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: mornye
                                          ? Color.lerp(
                                              colorScheme.onSurfaceVariant,
                                              colorScheme.onSurface,
                                              colorScheme.brightness ==
                                                      Brightness.dark
                                                  ? 0.7
                                                  : 0.6,
                                            )
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        color: mornye ? colorScheme.onSurface : null,
                        tooltip: isPlaying
                            ? context.l10n.actionPause
                            : context.l10n.tooltipPlay,
                        icon: isLoading
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              )
                            : Icon(
                                mornye
                                    ? (isPlaying
                                          ? CupertinoIcons.pause_fill
                                          : CupertinoIcons.play_fill)
                                    : (isPlaying
                                          ? Icons.pause
                                          : Icons.play_arrow),
                              ),
                        onPressed: isLoading
                            ? null
                            : () => controller.togglePlayPause(isPlaying),
                      ),
                      if (!compact)
                        IconButton(
                          color: mornye ? colorScheme.onSurface : null,
                          tooltip: context.l10n.nowPlayingNextTrack,
                          icon: Icon(
                            mornye
                                ? CupertinoIcons.forward_fill
                                : Icons.skip_next,
                          ),
                          onPressed: controller.next,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return mornye
        ? Padding(
            padding: EdgeInsets.only(bottom: widget.bottomPadding),
            child: MornyeGlass.navigation(
              strongTint: true,
              tintOpacity: MornyeTheme.chromeOpacity(context),
              blurEnabled: ref.watch(mornyeBlurEnabledProvider),
              child: player,
            ),
          )
        : player;
  }
}

class _MiniPlayerProgress extends ConsumerWidget {
  final Duration duration;
  final Color backgroundColor;

  const _MiniPlayerProgress({
    required this.duration,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final durationMs = duration.inMilliseconds;
    final positionMs = ref.watch(playbackPositionProvider).inMilliseconds;
    final progress = durationMs > 0
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    return LinearProgressIndicator(
      value: progress,
      minHeight: 2,
      backgroundColor: backgroundColor,
    );
  }
}
