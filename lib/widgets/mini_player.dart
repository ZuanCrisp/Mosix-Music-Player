import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/widgets/app_icon.dart';
import 'package:mosix/widgets/app_icon_button.dart';
import 'package:mosix/widgets/app_loading_indicator.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/providers/player_motion_artwork_provider.dart';
import 'package:mosix/providers/player_artwork_video_provider.dart';
import 'package:mosix/providers/runtime_profile_provider.dart';
import 'package:mosix/theme/app_motion.dart';
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/theme/material_expressive.dart';
import 'package:mosix/theme/mosix_theme.dart';
import 'package:mosix/theme/player_artwork_theme.dart';
import 'package:mosix/screens/now_playing_screen.dart';
import 'package:mosix/utils/desktop_platform.dart';
import 'package:mosix/utils/string_utils.dart';
import 'package:mosix/widgets/audio_quality_badges.dart';
import 'package:mosix/widgets/overflow_marquee.dart';
import 'package:mosix/widgets/player_artwork.dart';
import 'package:mosix/widgets/settings_group.dart';
import 'package:mosix/widgets/mosix_chrome.dart';

class MiniPlayer extends ConsumerStatefulWidget {
  const MiniPlayer({super.key, this.compact = false, this.bottomPadding = 8});

  final bool compact;
  final double bottomPadding;

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  @override
  Widget build(BuildContext context) {
    final body = _MiniPlayerBody(
      compact: widget.compact,
      bottomPadding: widget.bottomPadding,
    );
    if (context.isMosix) return body;
    // Material takes the track's artwork scheme, like the full player.
    final artUri = ref.watch(
      currentMediaItemProvider.select((item) => item.value?.artUri),
    );
    return PlayerArtworkTheme(artUri: artUri?.toString(), child: body);
  }
}

class _MiniPlayerBody extends ConsumerStatefulWidget {
  const _MiniPlayerBody({required this.compact, required this.bottomPadding});

  final bool compact;
  final double bottomPadding;

  @override
  ConsumerState<_MiniPlayerBody> createState() => _MiniPlayerBodyState();
}

class _MiniPlayerBodyState extends ConsumerState<_MiniPlayerBody> {
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

  /// Upward travel of the current vertical drag, in logical pixels.
  double _dragUp = 0;
  double _dragAcross = 0;
  bool _dragCancelled = false;

  void _openNowPlaying() {
    Navigator.of(context, rootNavigator: true).push(
      NowPlayingRoute(
        child: const NowPlayingScreen(),
        miniPlayerGeometry: context.isMosix
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
  }

  // Opens on release rather than under the finger: pushing a route cancels
  // every active pointer, so the drag could not keep steering the page.
  void _onVerticalDragEnd(DragEndDetails details) {
    final travel = _dragUp;
    _dragUp = 0;
    final velocity = -(details.primaryVelocity ?? 0);
    if (!_dragCancelled && (velocity > 300 || (velocity >= 0 && travel > 48))) {
      _openNowPlaying();
    }
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    final travel = _dragAcross;
    _dragAcross = 0;
    final velocity = details.primaryVelocity ?? 0;
    if (_dragCancelled || (travel.abs() < 48 && velocity.abs() < 550)) return;
    final direction = velocity.abs() >= 550 ? velocity : travel;
    final controller = ref.read(musicPlayerControllerProvider);
    if (direction < 0) {
      controller.next();
    } else {
      controller.previous();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    if (mediaItem == null) return const SizedBox.shrink();

    final isPlaying = ref.watch(playbackPlayingProvider);
    final isLoading = ref.watch(playbackLoadingProvider);

    final controller = ref.read(musicPlayerControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final mosix = context.isMosix;
    final expressive = materialExpressiveEnabled(context);
    final compact = mosix && widget.compact;
    // Frosted and flat glass levels run on constrained Android hardware. They
    // skip keeping a paused video decoder for the full player's motion cover,
    // and stop the title marquee after a few passes: every marquee frame
    // re-filters the blurred chrome around it.
    final fullEffects = !mosix || ref.watch(mosixLiquidGlassProvider);
    final marqueeCycles = fullEffects ? null : 2;
    if (mosix &&
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

    final surface = DecoratedBox(
      key: _surfaceKey,
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: mosix
            ? null
            : Border(
                top: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
      ),
      child: Material(
        color: mosix
            ? Colors.transparent
            : settingsGroupColor(context).withValues(alpha: 0.72),
        child: InkWell(
          onTap: _openNowPlaying,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!mosix)
                _MiniPlayerProgress(
                  duration: mediaItem.duration ?? Duration.zero,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  playing: isPlaying,
                ),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 12,
                  vertical: mosix ? 0 : 8,
                ),
                child: Row(
                  children: [
                    Hero(
                      tag: kNowPlayingArtworkHeroTag,
                      child: ClipRRect(
                        key: _artworkKey,
                        borderRadius: BorderRadius.circular(mosix ? 6 : 12),
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
                                    color: mosix
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
                    if (expressive)
                      AppIconButton.filled(
                        tooltip: isPlaying
                            ? context.l10n.actionPause
                            : context.l10n.tooltipPlay,
                        isSelected: isPlaying,
                        style: IconButton.styleFrom(
                          backgroundColor: colorScheme.primary,
                          foregroundColor: colorScheme.onPrimary,
                        ),
                        icon: isLoading
                            ? AppLoadingIndicator(
                                size: 20,
                                color: colorScheme.onPrimary,
                              )
                            : const AppIcon(Icons.play_arrow),
                        selectedIcon: isLoading
                            ? AppLoadingIndicator(
                                size: 20,
                                color: colorScheme.onPrimary,
                              )
                            : const AppIcon(Icons.pause),
                        onPressed: isLoading
                            ? null
                            : () => controller.togglePlayPause(isPlaying),
                      )
                    else
                      AppIconButton(
                        color: mosix ? colorScheme.onSurface : null,
                        tooltip: isPlaying
                            ? context.l10n.actionPause
                            : context.l10n.tooltipPlay,
                        icon: isLoading
                            ? const AppLoadingIndicator(
                                size: 20,
                                strokeWidth: 2.5,
                              )
                            : AppIcon(
                                mosix
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
                      AppIconButton(
                        color: mosix ? colorScheme.onSurface : null,
                        tooltip: context.l10n.nowPlayingNextTrack,
                        icon: AppIcon(
                          mosix
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
    );
    // Swiping up opens the full player; sideways swipes change tracks.
    // Desktop has no touch gestures: a click opens the player instead.
    final swipeable = isDesktopPlatform
        ? surface
        : GestureDetector(
            // Measure from touch-down so the slop counts toward the swipe.
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragStart: (_) => _dragUp = 0,
            onVerticalDragUpdate: (details) =>
                _dragUp -= details.primaryDelta ?? 0,
            onVerticalDragEnd: _onVerticalDragEnd,
            onVerticalDragCancel: () => _dragUp = 0,
            onHorizontalDragStart: (_) => _dragAcross = 0,
            onHorizontalDragUpdate: (details) =>
                _dragAcross += details.primaryDelta ?? 0,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            onHorizontalDragCancel: () => _dragAcross = 0,
            child: Listener(
              // Flutter ends an accepted drag even after a pointer cancel.
              onPointerDown: (_) => _dragCancelled = false,
              onPointerCancel: (_) => _dragCancelled = true,
              child: surface,
            ),
          );
    return mosix
        ? Padding(
            padding: EdgeInsets.only(bottom: widget.bottomPadding),
            child: MosixGlass.navigation(
              strongTint: true,
              tintOpacity: MosixTheme.chromeOpacity(context),
              blurEnabled: ref.watch(mosixBlurEnabledProvider),
              child: swipeable,
            ),
          )
        : swipeable;
  }
}

class _MiniPlayerProgress extends ConsumerWidget {
  final Duration duration;
  final Color backgroundColor;
  final bool playing;

  const _MiniPlayerProgress({
    required this.duration,
    required this.backgroundColor,
    required this.playing,
  });

  // Playback progress fills left to right in right-to-left layouts too.
  @override
  Widget build(BuildContext context, WidgetRef ref) => Directionality(
    textDirection: TextDirection.ltr,
    child: _buildProgress(context, ref),
  );

  Widget _buildProgress(BuildContext context, WidgetRef ref) {
    final durationMs = duration.inMilliseconds;
    final positionMs = ref.watch(playbackPositionProvider).inMilliseconds;
    final progress = durationMs > 0
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    if (!materialExpressiveEnabled(context)) {
      return LinearProgressIndicator(
        value: progress,
        minHeight: 2,
        backgroundColor: backgroundColor,
      );
    }
    final motion = AppMotion.effects(
      context,
      const AppMotionSpec(Duration(milliseconds: 300), Curves.easeOut),
    );
    // The wave settles flat while paused; its ticker stops once flat so an
    // idle mini player does not repaint every frame.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: playing ? 1 : 0),
        duration: motion.duration,
        curve: motion.curve,
        builder: (context, amplitude, _) => TickerMode(
          enabled: amplitude > 0,
          child: MaterialExpressiveScope(
            child: M3EProgressIndicator.linearWavy(
              value: progress,
              linearSize: M3EProgressIndicatorSize.s,
              trackColor: backgroundColor,
              // Taper toward both ends instead of the theme's hard cutoff.
              amplitudeForProgress: (value) =>
                  amplitude *
                  (math.min(value, 1 - value) / 0.05).clamp(0.0, 1.0),
            ),
          ),
        ),
      ),
    );
  }
}
