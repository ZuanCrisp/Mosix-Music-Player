import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/providers/player_artwork_video_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/widgets/motion_header_banner.dart';
import 'package:mosix/widgets/player_artwork.dart';
import 'package:video_player/video_player.dart';

class MornyePlayerArtwork extends ConsumerStatefulWidget {
  const MornyePlayerArtwork({
    super.key,
    required this.mediaItem,
    this.videoUrl,
    this.onAspectRatioChanged,
    this.onError,
    this.resolvingVideo = false,
  });

  final MediaItem mediaItem;
  final String? videoUrl;
  final ValueChanged<double>? onAspectRatioChanged;
  final VoidCallback? onError;
  final bool resolvingVideo;

  @override
  ConsumerState<MornyePlayerArtwork> createState() =>
      _MornyePlayerArtworkState();
}

class _MornyePlayerArtworkState extends ConsumerState<MornyePlayerArtwork> {
  String? _displayedSource;
  VideoPlayerController? _displayedController;

  @override
  Widget build(BuildContext context) {
    final fallback = Align(
      alignment: Alignment.topCenter,
      child: AspectRatio(
        aspectRatio: 1,
        child: PlayerArtwork(
          artUri: widget.mediaItem.artUri?.toString(),
          colorScheme: Theme.of(context).colorScheme,
          cacheWidth: PlayerArtwork.transitionCacheWidth(context),
        ),
      ),
    );
    if (MediaQuery.disableAnimationsOf(context) ||
        !ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
      _displayedSource = null;
      _displayedController = null;
      return fallback;
    }
    final videoUrl = widget.videoUrl;
    final prepared = videoUrl == null
        ? null
        : ref.watch(playerArtworkVideoProvider(videoUrl));
    if (prepared?.hasError == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onError?.call();
      });
    }
    if (prepared?.value case final controller?) {
      _displayedSource = videoUrl;
      _displayedController = controller;
    } else if (!widget.resolvingVideo &&
        (videoUrl == null || prepared?.hasError == true)) {
      _displayedSource = null;
      _displayedController = null;
    }
    // Retain the outgoing decoder only while it is still displayed. Watching
    // it before accepting the new frame keeps its heap alive until a later
    // unrelated rebuild, even after the old banner has been removed.
    if (_displayedSource != null && _displayedSource != videoUrl) {
      ref.watch(playerArtworkVideoProvider(_displayedSource!));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        fallback,
        if (_displayedController != null)
          MotionHeaderBanner(
            videoUrl: _displayedSource!,
            fallback: const SizedBox.shrink(),
            controller: _displayedController,
            fadeDuration: Duration.zero,
            onAspectRatioChanged: (ratio) {
              if (_displayedSource == widget.videoUrl) {
                widget.onAspectRatioChanged?.call(ratio);
              }
            },
            onError: () {
              if (_displayedSource == widget.videoUrl) widget.onError?.call();
            },
          ),
      ],
    );
  }
}
