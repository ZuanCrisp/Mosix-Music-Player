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

  static const duration = Duration(milliseconds: 800);

  /// The list scroll to a new line. It starts from rest and settles without
  /// overshoot, so a line change never opens with a jump.
  static const scrollDuration = Duration(milliseconds: 550);
  static final Curve scrollCurve = _SpringCurve(
    SpringSimulation(
      SpringDescription.withDampingRatio(mass: 1, stiffness: 196, ratio: 1),
      0,
      1,
      0,
    ),
    scrollDuration,
  );

  // Softer than the scroll, so later rows keep trailing it.
  static final _spring = SpringSimulation(
    SpringDescription.withDampingRatio(mass: 1, stiffness: 121, ratio: 0.85),
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
        final t = progress.value * duration.inMilliseconds / 1000;
        final delay = rowsAfterFocus.clamp(1, 6) * 0.035;
        final scroll = scrollCurve.transform(
          (t * 1000 / scrollDuration.inMilliseconds).clamp(0.0, 1.0),
        );
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

/// A spring sampled over [duration] and scaled to end exactly at 1.
class _SpringCurve extends Curve {
  _SpringCurve(this.simulation, Duration duration)
    : _seconds = duration.inMicroseconds / Duration.microsecondsPerSecond,
      _end = simulation.x(
        duration.inMicroseconds / Duration.microsecondsPerSecond,
      );

  final SpringSimulation simulation;
  final double _seconds;
  final double _end;

  @override
  double transformInternal(double t) => simulation.x(t * _seconds) / _end;
}
