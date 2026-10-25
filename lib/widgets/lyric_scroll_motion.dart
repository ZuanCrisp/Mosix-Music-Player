import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// One shared clock adds a small, staggered spring to upcoming visible rows.
/// Only painting moves: lyric timings and list extents stay fixed.
class LyricScrollMotion extends StatelessWidget {
  const LyricScrollMotion({
    super.key,
    required this.progress,
    required this.distance,
    required this.rowsAfterFocus,
    required this.child,
    this.enabled = true,
  });

  final Animation<double> progress;
  final double distance;
  final int rowsAfterFocus;
  final Widget child;
  final bool enabled;

  static const duration = Duration(milliseconds: 700);
  static final _spring = SpringSimulation(
    SpringDescription.withDampingRatio(mass: 1, stiffness: 180, ratio: 0.82),
    0,
    1,
    0,
  );

  @override
  Widget build(BuildContext context) {
    if (!enabled ||
        rowsAfterFocus <= 0 ||
        distance == 0 ||
        MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, child) {
        final t = progress.value * 0.7;
        final delay = rowsAfterFocus.clamp(1, 6) * 0.035;
        final scroll = Curves.easeOutCubic.transform((t / 0.38).clamp(0, 1));
        final following = t <= delay ? 0.0 : _spring.x(t - delay);
        final offset = progress.value >= 1
            ? 0.0
            : distance.clamp(-96, 96) * (scroll - following);
        return Transform.translate(
          offset: Offset(0, offset),
          transformHitTests: true,
          child: child,
        );
      },
    );
  }
}
