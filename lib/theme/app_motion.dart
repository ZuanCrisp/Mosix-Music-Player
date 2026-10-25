import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';

/// A duration and curve pair for implicit animations.
@immutable
class AppMotionSpec {
  const AppMotionSpec(this.duration, this.curve);

  final Duration duration;
  final Curve curve;
}

/// A [Curve] that follows an [M3ESpring] released from rest at 0 toward 1.
///
/// [duration] is the spring's settling time, so implicit animations driven by
/// this curve end exactly when the physical motion does.
class SpringCurve extends Curve {
  SpringCurve(M3ESpring spring)
    : this._(SpringSimulation(spring.toDescription(), 0, 1, 0));

  SpringCurve._(this._simulation) : duration = _settleTime(_simulation);

  final SpringSimulation _simulation;
  final Duration duration;

  static Duration _settleTime(SpringSimulation simulation) {
    const step = 1 / 1000;
    var settledSince = 0.0;
    for (var t = 0.0; t < 2; t += step) {
      final settled =
          (simulation.x(t) - 1).abs() < 0.002 && simulation.dx(t).abs() < 0.02;
      if (!settled) {
        settledSince = t + step;
      } else if (t - settledSince >= 0.05) {
        break;
      }
    }
    return Duration(microseconds: (settledSince * 1e6).round());
  }

  @override
  double transformInternal(double t) =>
      _simulation.x(t * duration.inMicroseconds / 1e6);
}

/// Material 3 Expressive motion for the Material theme.
///
/// Spatial springs (position, size, scale) overshoot slightly; effects
/// springs (opacity, color) settle without overshoot. Mornye and reduced
/// motion keep each call site's original [AppMotionSpec].
abstract final class AppMotion {
  static final _spatialFast = SpringCurve(M3EMotion.expressiveSpatialFast);
  static final _spatialDefault = SpringCurve(
    M3EMotion.expressiveSpatialDefault,
  );
  static final _spatialSlow = SpringCurve(M3EMotion.expressiveSpatialSlow);
  static final _effectsFast = SpringCurve(M3EMotion.effectsFast);
  static final _effectsDefault = SpringCurve(M3EMotion.effectsDefault);

  static AppMotionSpec _spec(SpringCurve curve) =>
      AppMotionSpec(curve.duration, curve);

  /// Fast spatial spring for small components: chips, checks, buttons.
  static AppMotionSpec spatialFast(
    BuildContext context,
    AppMotionSpec fallback,
  ) => materialExpressiveEnabled(context) ? _spec(_spatialFast) : fallback;

  /// Default spatial spring for list items, panels and content changes.
  static AppMotionSpec spatial(BuildContext context, AppMotionSpec fallback) =>
      materialExpressiveEnabled(context) ? _spec(_spatialDefault) : fallback;

  /// Slow spatial spring for full-screen surfaces such as the player.
  static AppMotionSpec spatialSlow(
    BuildContext context,
    AppMotionSpec fallback,
  ) => materialExpressiveEnabled(context) ? _spec(_spatialSlow) : fallback;

  /// Fast effects spring for opacity and color.
  static AppMotionSpec effectsFast(
    BuildContext context,
    AppMotionSpec fallback,
  ) => materialExpressiveEnabled(context) ? _spec(_effectsFast) : fallback;

  /// Default effects spring for opacity and color.
  static AppMotionSpec effects(BuildContext context, AppMotionSpec fallback) =>
      materialExpressiveEnabled(context) ? _spec(_effectsDefault) : fallback;

  /// Entrance for sheets and menus. The slow spatial spring is critically
  /// damped, so a surface never overshoots its own size and reveals what is
  /// behind it. Null keeps the platform transition.
  static AnimationStyle? surfaceEntrance(BuildContext context) =>
      materialExpressiveEnabled(context)
      ? AnimationStyle(
          duration: _spatialSlow.duration,
          curve: _spatialSlow,
          reverseDuration: const Duration(milliseconds: 200),
        )
      : null;
}
