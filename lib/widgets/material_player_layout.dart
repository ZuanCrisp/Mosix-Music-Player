import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/controllers/player_metadata_controller.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/routes/now_playing_route.dart';
import 'package:mosix/utils/clickable_metadata.dart';
import 'package:mosix/utils/playback_seek_preview.dart';
import 'package:mosix/widgets/player_artwork.dart';
import 'package:mosix/widgets/player_gesture_regions.dart';
import 'package:mosix/widgets/player_metadata_title.dart';
import 'package:mosix/widgets/player_playback_controls.dart';

class MaterialPlayerLayout extends StatelessWidget {
  const MaterialPlayerLayout({
    super.key,
    required this.mediaItem,
    required this.metadata,
    required this.seekPreview,
    required this.colorScheme,
    required this.showLyrics,
    required this.lyricsBuilder,
    required this.onOpenQueue,
  });

  final MediaItem mediaItem;
  final PlayerMetadataController metadata;
  final PlaybackSeekPreview seekPreview;
  final ColorScheme colorScheme;
  final bool showLyrics;
  final WidgetBuilder lyricsBuilder;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget artworkAt(double artSize) => Center(
          child: PlayerArtworkDragRegion(
            child: Hero(
              tag: kNowPlayingArtworkHeroTag,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  width: artSize,
                  height: artSize,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween(begin: 0.94, end: 1.0).animate(animation),
                        child: child,
                      ),
                    ),
                    child: PlayerArtwork(
                      key: ValueKey(
                        mediaItem.artUri?.toString() ?? mediaItem.id,
                      ),
                      artUri: mediaItem.artUri?.toString(),
                      colorScheme: colorScheme,
                      cacheWidth:
                          (artSize * MediaQuery.devicePixelRatioOf(context))
                              .round(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        Widget visual() => AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 300),
          switchInCurve: Curves.easeInOutCubic,
          switchOutCurve: Curves.easeInOutCubic,
          child: showLyrics
              ? KeyedSubtree(
                  key: const ValueKey('material-player-lyrics'),
                  child: lyricsBuilder(context),
                )
              : LayoutBuilder(
                  key: const ValueKey('material-player-cover'),
                  builder: (context, area) => artworkAt(
                    math.max(
                      0.0,
                      math.min(
                        360.0,
                        math.min(area.maxWidth - 64, area.maxHeight - 24),
                      ),
                    ),
                  ),
                ),
        );

        // Tablet/landscape: artwork pane left, metadata and controls right,
        // instead of one narrow column in a sea of empty space.
        final twoPane =
            constraints.maxWidth >= 720 &&
            constraints.maxWidth > constraints.maxHeight;
        if (twoPane) {
          return Row(
            children: [
              Expanded(child: visual()),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight - 32,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: _metadataAndControls(context, compact: true),
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            children: [
              Expanded(child: visual()),
              const SizedBox(height: 12),
              PlayerQueueSwipeRegion(
                onOpenQueue: onOpenQueue,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _metadataAndControls(context),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Title/artist, seek slider, and transport buttons — shared by the
  /// portrait column and the landscape right pane.
  List<Widget> _metadataAndControls(
    BuildContext context, {
    bool compact = false,
  }) {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, 0.15),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Row(
            key: ValueKey(mediaItem.id),
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    PlayerMetadataTitle(
                      mediaItem: mediaItem,
                      metadata: metadata,
                      style:
                          (compact
                                  ? Theme.of(context).textTheme.titleLarge
                                  : Theme.of(context).textTheme.headlineSmall)
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onSurface,
                              ),
                      textAlign: TextAlign.center,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: compact ? 4 : 6),
                    Consumer(
                      builder: (context, ref, _) {
                        final track = ref
                            .watch(playerCollectionTrackProvider(mediaItem))
                            .value;
                        return ClickableArtistName(
                          artistName: mediaItem.artist ?? '',
                          artistId: track?.artistId,
                          extensionId: track?.source,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      SizedBox(height: compact ? 12 : 24),
      PlayerPlaybackControls(
        key: ValueKey(mediaItem.id),
        mediaId: mediaItem.id,
        duration: mediaItem.duration ?? Duration.zero,
        seekPreview: seekPreview,
        colorScheme: colorScheme,
        metadata: metadata,
        compact: compact,
      ),
    ];
  }
}
