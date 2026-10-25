import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_3_expressive/components/sliders/components/m3e_slider_track_painter.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

/// Expressive track motion around the native slider's seeking and accessibility.
class ExpressiveSeekTrack extends StatefulWidget {
  const ExpressiveSeekTrack({
    super.key,
    required this.playing,
    required this.child,
  });

  final bool playing;
  final Widget child;

  @override
  State<ExpressiveSeekTrack> createState() => _ExpressiveSeekTrackState();
}

class _ExpressiveSeekTrackState extends State<ExpressiveSeekTrack>
    with TickerProviderStateMixin {
  late final _phase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  late final _amplitude =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed) _phase.stop();
      });
  late final _animation = Listenable.merge([_phase, _amplitude]);
  bool _motionEnabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionEnabled =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ExpressiveSeekTrack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) _syncAnimation();
  }

  void _syncAnimation() {
    if (!_motionEnabled) {
      _phase.stop();
      _amplitude.value = 0;
    } else if (widget.playing) {
      if (!_phase.isAnimating) _phase.repeat();
      _amplitude.forward();
    } else {
      _amplitude.reverse();
      if (_amplitude.isDismissed) _phase.stop();
    }
  }

  @override
  void dispose() {
    _amplitude.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _animation,
      child: widget.child,
      builder: (context, child) => SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 4,
          trackShape: ExpressiveSeekTrackShape(
            phase: _phase.value * 2 * math.pi,
            amplitude: Curves.easeInOutCubic.transform(_amplitude.value),
          ),
          thumbShape: const HandleThumbShape(),
          thumbSize: const WidgetStatePropertyAll(Size(4, 24)),
        ),
        child: child!,
      ),
    ),
  );
}

/// Uses the package's wave renderer without changing the slider gesture cycle.
class ExpressiveSeekTrackShape extends RoundedRectSliderTrackShape {
  const ExpressiveSeekTrackShape({
    required this.phase,
    required this.amplitude,
  });

  final double phase;
  final double amplitude;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (track.isEmpty) return;
    final rtl = textDirection == TextDirection.rtl;
    final fraction =
        ((rtl ? track.right - thumbCenter.dx : thumbCenter.dx - track.left) /
                track.width)
            .clamp(0.0, 1.0);
    final active = Color.lerp(
      sliderTheme.disabledActiveTrackColor,
      sliderTheme.activeTrackColor,
      enableAnimation.value,
    )!;
    final inactive = Color.lerp(
      sliderTheme.disabledInactiveTrackColor,
      sliderTheme.inactiveTrackColor,
      enableAnimation.value,
    )!;
    final painter = M3ESliderTrackPainter(
      mode: M3ESliderPaintMode.single,
      trackKind: M3ESliderTrackKind.standard,
      activeStartFraction: 0,
      activeEndFraction: fraction,
      tickFractions: const [],
      colors: M3ESliderColors(
        thumb: active,
        activeTrack: active,
        inactiveTrack: inactive,
        activeTick: inactive,
        inactiveTick: active,
        stopIndicator: active,
        valueIndicator: active,
        valueIndicatorLabel: inactive,
      ),
      trackHeight: track.height,
      handleGap: 6,
      handleThickness: 4,
      insideCornerSize: 2,
      cornerRadius: 2,
      stopIndicatorSize: 4,
      tickSize: 0,
      edgeInset: 2,
      axis: Axis.horizontal,
      // Mirror the complete logical track, including waves and the end marker.
      textDirection: TextDirection.ltr,
      isWavy: amplitude > 0,
      waveAmplitude: 3,
      wavelength: 40,
      phase: phase,
      amplitudeFactor: amplitude,
    );
    final canvas = context.canvas;
    canvas.save();
    canvas.translate(rtl ? track.right : track.left, track.top);
    if (rtl) canvas.scale(-1, 1);
    painter.paint(canvas, track.size);
    canvas.restore();
  }
}
