import 'package:flutter/material.dart';
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/theme/mornye_theme.dart';

/// Wraps a child in a staggered fade-in + slide-up animation.
///
/// [index] controls the stagger delay (each item delayed by [staggerDelay]).
/// Set [animate] to false to skip the animation (e.g. when scrolling back).
class StaggeredListItem extends StatelessWidget {
  static const int _maxAnimatedItems = 10;

  final int index;
  final Widget child;
  final Duration duration;
  final Duration staggerDelay;
  final bool animate;

  const StaggeredListItem({
    super.key,
    required this.index,
    required this.child,
    this.duration = const Duration(milliseconds: 250),
    this.staggerDelay = const Duration(milliseconds: 40),
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!animate ||
        index >= _maxAnimatedItems ||
        MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    final cappedIndex = index.clamp(0, _maxAnimatedItems - 1);
    final delay = staggerDelay * cappedIndex;
    final totalDuration = duration + delay;

    return TweenAnimationBuilder<double>(
      key: ValueKey('stagger_$index'),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: totalDuration,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final delayFraction = totalDuration.inMilliseconds > 0
            ? delay.inMilliseconds / totalDuration.inMilliseconds
            : 0.0;
        final progress = value <= delayFraction
            ? 0.0
            : ((value - delayFraction) / (1.0 - delayFraction)).clamp(0.0, 1.0);
        return Opacity(
          opacity: progress,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - progress)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Creates a platform-aware material route.
///
/// This intentionally defers route transitions to Flutter's material route and
/// theme so Android predictive back and platform-default animations remain
/// intact.
Route<T> slidePageRoute<T>({required Widget page}) {
  return MaterialPageRoute<T>(builder: (context) => page);
}

/// A shimmer effect widget that can wrap skeleton placeholders.
class ShimmerLoading extends StatefulWidget {
  final Widget child;

  const ShimmerLoading({super.key, required this.child});

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final baseColor = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            colorScheme.surface,
          )
        : Color.alphaBlend(
            Colors.black.withValues(alpha: 0.10),
            colorScheme.surface,
          );
    final highlightColor = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.14),
            colorScheme.surface,
          )
        : Color.alphaBlend(
            Colors.black.withValues(alpha: 0.01),
            colorScheme.surface,
          );

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [baseColor, highlightColor, baseColor],
              stops: [
                (_controller.value - 0.3).clamp(0.0, 1.0),
                _controller.value,
                (_controller.value + 0.3).clamp(0.0, 1.0),
              ],
              tileMode: TileMode.clamp,
            ).createShader(bounds);
          },
          blendMode: BlendMode.srcATop,
          child: child,
        );
      },
      // The mask moves every frame; the skeleton beneath it does not.
      child: RepaintBoundary(child: widget.child),
    );
  }
}

/// A skeleton placeholder box used inside [ShimmerLoading].
class SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const SkeletonBox({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            colorScheme.surface,
          )
        : Color.alphaBlend(
            Colors.black.withValues(alpha: 0.06),
            colorScheme.surface,
          );
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Track list skeleton – mimics a list of track items while loading.
class TrackListSkeleton extends StatelessWidget {
  final int itemCount;
  final bool showCoverHeader;

  const TrackListSkeleton({
    super.key,
    this.itemCount = 8,
    this.showCoverHeader = false,
  });

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return ShimmerLoading(
        child: SingleChildScrollView(
          child: Column(
            children: [
              if (showCoverHeader)
                const _CollectionHeaderSkeleton(showSubtitle: false),
              for (var index = 0; index < itemCount; index++)
                _MornyeTrackSkeleton(
                  numbered: false,
                  index: index,
                  showPreview: true,
                ),
            ],
          ),
        ),
      );
    }
    return ShimmerLoading(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          children: [
            if (showCoverHeader) const _CollectionHeaderSkeleton(),
            ...List.generate(itemCount, (index) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    const SkeletonBox(width: 48, height: 48, borderRadius: 8),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonBox(
                            width: 150 + (index % 3) * 30,
                            height: 15,
                            borderRadius: 4,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              SkeletonBox(
                                width: 90 + (index % 2) * 20,
                                height: 12,
                                borderRadius: 4,
                              ),
                              const SizedBox(width: 8),
                              const SkeletonBox(
                                width: 38,
                                height: 12,
                                borderRadius: 6,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const SkeletonBox(width: 24, height: 24, borderRadius: 12),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// Album track list skeleton – mimics the album screen track list layout
/// (track number + title + artist + trailing icon, no cover art thumbnail).
class AlbumTrackListSkeleton extends StatelessWidget {
  final int itemCount;
  final bool showCoverHeader;

  const AlbumTrackListSkeleton({
    super.key,
    this.itemCount = 10,
    this.showCoverHeader = false,
  });

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return ShimmerLoading(
        child: SingleChildScrollView(
          child: Column(
            children: [
              if (showCoverHeader) const _CollectionHeaderSkeleton(),
              for (var index = 0; index < itemCount; index++)
                _MornyeTrackSkeleton(
                  numbered: true,
                  index: index,
                  showPreview: true,
                ),
            ],
          ),
        ),
      );
    }
    return ShimmerLoading(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          children: [
            if (showCoverHeader) const _CollectionHeaderSkeleton(),
            ...List.generate(itemCount, (index) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 32,
                      child: Center(
                        child: SkeletonBox(
                          width: 16,
                          height: 14,
                          borderRadius: 4,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonBox(
                            width: 130 + (index % 4) * 35,
                            height: 15,
                            borderRadius: 4,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              SkeletonBox(
                                width: 70 + (index % 3) * 20,
                                height: 12,
                                borderRadius: 4,
                              ),
                              const SizedBox(width: 8),
                              const SkeletonBox(
                                width: 38,
                                height: 12,
                                borderRadius: 6,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const SkeletonBox(width: 24, height: 24, borderRadius: 12),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// Mirrors each theme's collection header, including Mornye's full-width
/// square artwork and compact primary action between two circular controls.
class _CollectionHeaderSkeleton extends StatelessWidget {
  const _CollectionHeaderSkeleton({this.showSubtitle = true});

  final bool showSubtitle;

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final coverSize = constraints.maxWidth.clamp(0.0, 440.0);
          return Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Center(
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (bounds) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0, 0.48, 1],
                      colors: [Colors.white, Colors.white, Colors.transparent],
                    ).createShader(bounds),
                    child: SkeletonBox(
                      width: coverSize,
                      height: coverSize,
                      borderRadius: 0,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  (coverSize - 20).clamp(0.0, double.infinity),
                  20,
                  28,
                ),
                child: Column(
                  children: [
                    const FractionallySizedBox(
                      widthFactor: 0.75,
                      child: SkeletonBox(
                        width: double.infinity,
                        height: 28,
                        borderRadius: 6,
                      ),
                    ),
                    if (showSubtitle) ...[
                      const SizedBox(height: 5),
                      const FractionallySizedBox(
                        widthFactor: 0.5,
                        child: SkeletonBox(
                          width: double.infinity,
                          height: 24,
                          borderRadius: 5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),
                    const SkeletonBox(width: 140, height: 16, borderRadius: 4),
                    const SizedBox(height: 16),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        spacing: 16,
                        children: [
                          SkeletonBox(width: 44, height: 44, borderRadius: 22),
                          Flexible(
                            child: SkeletonBox(
                              width: 172,
                              height: 50,
                              borderRadius: 25,
                            ),
                          ),
                          SkeletonBox(width: 44, height: 44, borderRadius: 22),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    }
    final screenWidth = MediaQuery.sizeOf(context).width;
    final coverSize = (screenWidth * 0.5).clamp(150.0, 210.0).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        children: [
          SkeletonBox(width: coverSize, height: coverSize, borderRadius: 16),
          const SizedBox(height: 20),
          SkeletonBox(width: screenWidth * 0.6, height: 22, borderRadius: 6),
          const SizedBox(height: 10),
          SkeletonBox(width: screenWidth * 0.35, height: 15, borderRadius: 4),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              SkeletonBox(width: 44, height: 14, borderRadius: 6),
              SizedBox(width: 10),
              SkeletonBox(width: 70, height: 14, borderRadius: 6),
              SizedBox(width: 10),
              SkeletonBox(width: 60, height: 14, borderRadius: 6),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SkeletonBox(width: 48, height: 48, borderRadius: 24),
              const SizedBox(width: 16),
              Flexible(
                child: SkeletonBox(
                  width: screenWidth * 0.45,
                  height: 48,
                  borderRadius: 24,
                ),
              ),
              const SizedBox(width: 16),
              const SkeletonBox(width: 48, height: 48, borderRadius: 24),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// Mirrors the larger primary action and two smaller artist header actions.
class ArtistHeaderActionsSkeleton extends StatelessWidget {
  const ArtistHeaderActionsSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisAlignment: MainAxisAlignment.center,
    mainAxisSize: MainAxisSize.min,
    spacing: 24,
    children: [
      SkeletonBox(width: 50, height: 50, borderRadius: 25),
      SkeletonBox(width: 74, height: 74, borderRadius: 37),
      SkeletonBox(width: 50, height: 50, borderRadius: 25),
    ],
  );
}

/// Artist screen skeleton shown below the SliverAppBar header while the
/// discography loads: optional cover placeholder, "Popular" section, and the
/// horizontal album sections.
class ArtistScreenSkeleton extends StatelessWidget {
  static const int _popularCount = 5;

  final int albumCount;
  final bool showCoverHeader;
  final bool showPopularSection;

  const ArtistScreenSkeleton({
    super.key,
    this.albumCount = 5,
    this.showCoverHeader = true,
    this.showPopularSection = true,
  });

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return ShimmerLoading(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showCoverHeader)
                LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                      Positioned.fill(
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (bounds) => const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0, 0.48, 1],
                            colors: [
                              Colors.white,
                              Colors.white,
                              Colors.transparent,
                            ],
                          ).createShader(bounds),
                          child: const SkeletonBox(
                            width: double.infinity,
                            height: double.infinity,
                            borderRadius: 0,
                          ),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          24,
                          (constraints.maxWidth * 0.76).clamp(240.0, 340.0) + 4,
                          24,
                          32,
                        ),
                        child: const Column(
                          children: [
                            Center(child: SkeletonBox(width: 220, height: 36)),
                            SizedBox(height: 16),
                            ArtistHeaderActionsSkeleton(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    spacing: 14,
                    children: [
                      SkeletonBox(width: 76, height: 76, borderRadius: 5),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 6,
                          children: [
                            SkeletonBox(width: 38, height: 12, borderRadius: 4),
                            FractionallySizedBox(
                              widthFactor: 0.9,
                              child: SkeletonBox(
                                width: double.infinity,
                                height: 18,
                                borderRadius: 4,
                              ),
                            ),
                            SkeletonBox(width: 62, height: 12, borderRadius: 4),
                          ],
                        ),
                      ),
                      SkeletonBox(width: 10, height: 14, borderRadius: 4),
                    ],
                  ),
                ),
              ),
              if (showPopularSection) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 24, 20, 12),
                  child: SkeletonBox(width: 110, height: 24, borderRadius: 4),
                ),
                for (var index = 0; index < _popularCount; index++)
                  _MornyeTrackSkeleton(numbered: false, index: index),
              ],
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: SkeletonBox(width: 120, height: 24, borderRadius: 4),
              ),
              SizedBox(
                height: 208,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: albumCount,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (_, index) => const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(width: 156, height: 156, borderRadius: 8),
                      SizedBox(height: 8),
                      SkeletonBox(width: 120, height: 16, borderRadius: 4),
                      SizedBox(height: 4),
                      SkeletonBox(width: 45, height: 12, borderRadius: 4),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      );
    }
    final screenWidth = MediaQuery.sizeOf(context).width;
    return ShimmerLoading(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showCoverHeader)
              SkeletonBox(
                width: screenWidth,
                height: screenWidth * 0.75,
                borderRadius: 0,
              ),
            if (showPopularSection) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
                child: SkeletonBox(width: 110, height: 22, borderRadius: 4),
              ),
              ...List.generate(_popularCount, (index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 24,
                        child: Center(
                          child: SkeletonBox(
                            width: 12,
                            height: 14,
                            borderRadius: 4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const SkeletonBox(width: 48, height: 48, borderRadius: 4),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SkeletonBox(
                              width: 120 + (index % 4) * 30,
                              height: 14,
                              borderRadius: 4,
                            ),
                            const SizedBox(height: 8),

                            const SkeletonBox(
                              width: 64,
                              height: 14,
                              borderRadius: 4,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const SkeletonBox(width: 18, height: 18, borderRadius: 4),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 16),
            ],
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SkeletonBox(width: 120, height: 22, borderRadius: 4),
            ),
            SizedBox(
              height: 190,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: albumCount,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SkeletonBox(width: 140, height: 140),
                        const SizedBox(height: 8),
                        SkeletonBox(
                          width: 80 + (index % 3) * 20,
                          height: 12,
                          borderRadius: 4,
                        ),
                        const SizedBox(height: 4),
                        SkeletonBox(
                          width: 50 + (index % 2) * 15,
                          height: 10,
                          borderRadius: 4,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _MornyeTrackSkeleton extends StatelessWidget {
  const _MornyeTrackSkeleton({
    required this.numbered,
    required this.index,
    this.showPreview = false,
  });

  final bool numbered;
  final int index;
  final bool showPreview;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              if (numbered)
                const SizedBox(
                  width: 32,
                  child: Center(
                    child: SkeletonBox(width: 14, height: 16, borderRadius: 4),
                  ),
                )
              else
                const SkeletonBox(width: 48, height: 48, borderRadius: 4),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FractionallySizedBox(
                      widthFactor: 0.7 + (index % 3) * 0.1,
                      child: const SkeletonBox(
                        width: double.infinity,
                        height: 18,
                        borderRadius: 4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const FractionallySizedBox(
                      widthFactor: 0.5,
                      child: SkeletonBox(
                        width: double.infinity,
                        height: 14,
                        borderRadius: 4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              if (showPreview) ...[
                const SkeletonBox(width: 20, height: 20, borderRadius: 10),
                const SizedBox(width: 24),
              ],
              const SkeletonBox(width: 20, height: 6, borderRadius: 3),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.only(left: numbered ? 64 : 80, right: 20),
          child: const Divider(height: 1, thickness: 0.5),
        ),
      ],
    );
  }
}

/// Home search skeleton – mimics filter chips + sectioned results
/// (Artists section with rounded card items, Albums section, etc.)
class HomeSearchSkeleton extends StatelessWidget {
  const HomeSearchSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(
                children: [
                  SkeletonBox(width: 48, height: 32, borderRadius: 16),
                  const SizedBox(width: 8),
                  SkeletonBox(width: 64, height: 32, borderRadius: 16),
                  const SizedBox(width: 8),
                  SkeletonBox(width: 72, height: 32, borderRadius: 16),
                  const SizedBox(width: 8),
                  SkeletonBox(width: 60, height: 32, borderRadius: 16),
                  const SizedBox(width: 8),
                  SkeletonBox(width: 70, height: 32, borderRadius: 16),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _sectionSkeleton(context, 70, 2),
          const SizedBox(height: 16),
          _sectionSkeleton(context, 65, 4),
        ],
      ),
    );
  }

  static Widget _sectionSkeleton(
    BuildContext context,
    double headerWidth,
    int itemCount,
  ) {
    final mornye = context.isMornye;
    final rows = List.generate(itemCount, (index) {
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: mornye ? 12 : 16,
          vertical: context.tokens.trackRowPaddingV,
        ),
        child: Row(
          children: [
            SkeletonBox(
              width: mornye ? 56 : 48,
              height: mornye ? 56 : 48,
              borderRadius: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(
                    width: 100 + (index % 3) * 40,
                    height: 14,
                    borderRadius: 4,
                  ),
                  const SizedBox(height: 6),
                  SkeletonBox(
                    width: 60 + (index % 2) * 25,
                    height: 12,
                    borderRadius: 4,
                  ),
                ],
              ),
            ),
            if (!mornye)
              const SkeletonBox(width: 20, height: 20, borderRadius: 10),
          ],
        ),
      );
    });
    final decoration = BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(mornye ? 24 : 20),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              SkeletonBox(width: headerWidth, height: 18, borderRadius: 4),
              const Spacer(),
              const SkeletonBox(width: 50, height: 16, borderRadius: 4),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: decoration,
          child: Column(
            children: [
              for (var index = 0; index < rows.length; index++) ...[
                if (mornye && index > 0)
                  const Divider(height: 1, indent: 80, endIndent: 12),
                rows[index],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Crossfades when the child's runtime type changes — used to swap a loading
/// skeleton for the loaded screen without a single-frame hard cut.
class SkeletonCrossfade extends StatelessWidget {
  final Widget child;

  const SkeletonCrossfade({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      // Loading and loaded screens may carry the same Hero tag (both render
      // the header cover); mute the outgoing child's heroes so a pop during
      // the fade doesn't find duplicate tags.
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: AnimatedBuilder(
          animation: animation,
          child: child,
          builder: (context, child) => HeroMode(
            enabled:
                animation.status == AnimationStatus.forward ||
                animation.status == AnimationStatus.completed,
            child: child!,
          ),
        ),
      ),
      child: child,
    );
  }
}

/// An animated selection indicator that scales in/out and crossfades the
/// checked/unchecked state.
class AnimatedSelectionCheckbox extends StatelessWidget {
  final bool visible;
  final bool selected;
  final ColorScheme colorScheme;
  final double size;

  /// Background color when not selected. Defaults to `Colors.transparent`.
  final Color? unselectedColor;

  const AnimatedSelectionCheckbox({
    super.key,
    required this.visible,
    required this.selected,
    required this.colorScheme,
    this.size = 20,
    this.unselectedColor,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary
              : unselectedColor ?? Colors.transparent,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? colorScheme.primary : colorScheme.outline,
            width: 2,
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: selected
              ? Icon(
                  Icons.check,
                  key: const ValueKey('checked'),
                  size: size - 6,
                  color: colorScheme.onPrimary,
                )
              : SizedBox(
                  key: const ValueKey('unchecked'),
                  width: size - 6,
                  height: size - 6,
                ),
        ),
      ),
    );
  }
}

/// A widget that briefly flashes a success color behind its child and shows
/// an animated checkmark when [showSuccess] transitions to true.
class DownloadSuccessOverlay extends StatefulWidget {
  final bool showSuccess;
  final Widget child;

  const DownloadSuccessOverlay({
    super.key,
    required this.showSuccess,
    required this.child,
  });

  @override
  State<DownloadSuccessOverlay> createState() => _DownloadSuccessOverlayState();
}

class _DownloadSuccessOverlayState extends State<DownloadSuccessOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _flashAnimation;
  late bool _wasSuccess;

  @override
  void initState() {
    super.initState();
    _wasSuccess = widget.showSuccess;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _flashAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.15), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 0.15, end: 0.0), weight: 70),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(DownloadSuccessOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showSuccess && !_wasSuccess) {
      _controller.forward(from: 0);
    }
    _wasSuccess = widget.showSuccess;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: _flashAnimation.value),
            borderRadius: BorderRadius.circular(12),
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Wraps a [Badge] child and plays a brief scale-bump whenever [count] changes.
class AnimatedBadge extends StatefulWidget {
  final int count;
  final Widget child;

  const AnimatedBadge({super.key, required this.count, required this.child});

  @override
  State<AnimatedBadge> createState() => _AnimatedBadgeState();
}

class _AnimatedBadgeState extends State<AnimatedBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  int _previousCount = 0;

  @override
  void initState() {
    super.initState();
    _previousCount = widget.count;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.3), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.3, end: 1.0), weight: 60),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(AnimatedBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.count != _previousCount && widget.count > _previousCount) {
      _controller.forward(from: 0);
    }
    _previousCount = widget.count;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scaleAnimation, child: widget.child);
  }
}
