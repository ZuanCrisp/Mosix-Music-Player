import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/widgets/player_artwork.dart';

/// Full-screen cover style for the Material player: the cover fills the top
/// of the page edge to edge, then fades into a blurred copy of itself.
///
/// The blurred layer is tinted with the surface colour so titles, controls
/// and lyrics keep the same contrast as on the plain surface.
class MaterialPlayerBackdrop extends StatelessWidget {
  const MaterialPlayerBackdrop({
    super.key,
    required this.mediaItem,
    required this.colorScheme,
    required this.showArtwork,
  });

  final MediaItem mediaItem;
  final ColorScheme colorScheme;

  /// False behind lyrics, where only the blurred surface remains.
  final bool showArtwork;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final artUri = mediaItem.artUri?.toString();
    final appBarHeight = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: colorScheme.surface),
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 48, sigmaY: 48),
          child: PlayerArtwork(
            artUri: artUri,
            colorScheme: colorScheme,
            cacheWidth: 128,
          ),
        ),
        ColoredBox(color: colorScheme.surface.withValues(alpha: 0.72)),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          // Taller than wide on phones: the sides are cropped so the cover
          // reaches down to the title instead of leaving an empty band.
          height: size.width < size.height * 0.56
              ? size.height * 0.56
              : size.width.clamp(0.0, size.height * 0.62),
          child: AnimatedOpacity(
            opacity: showArtwork ? 1 : 0,
            duration: motion,
            curve: Curves.easeInOutCubic,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.72, 1],
                colors: [Colors.white, Colors.white, Colors.transparent],
              ).createShader(bounds),
              child: Hero(
                tag: kNowPlayingArtworkHeroTag,
                child: PlayerArtwork(
                  artUri: artUri,
                  colorScheme: colorScheme,
                  cacheWidth: PlayerArtwork.transitionCacheWidth(context),
                ),
              ),
            ),
          ),
        ),
        // Keeps the status bar and app bar readable over bright covers.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: appBarHeight + 32,
          child: AnimatedOpacity(
            opacity: showArtwork ? 1 : 0,
            duration: motion,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  // A light shade that eases out across the bar: enough for
                  // white icons without darkening the top of the cover.
                  stops: [0, appBarHeight / (appBarHeight + 32), 1],
                  colors: const [
                    Color(0x40000000),
                    Color(0x14000000),
                    Color(0x00000000),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
