import 'package:flutter/material.dart';

/// A continuous player track with no thumb in either gesture state.
class MornyePlayerSlider extends StatelessWidget {
  static const horizontalInset = 8.0;

  const MornyePlayerSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.max = 1,
    this.activeColor = Colors.white,
    this.inactiveColor = const Color(0x2EFFFFFF),
    this.onChangeStart,
    this.onChangeEnd,
  });

  final double value;
  final double max;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 6,
        trackGap: 0,
        trackShape: const RoundedRectSliderTrackShape(),
        thumbShape: SliderComponentShape.noThumb,
        overlayShape: SliderComponentShape.noOverlay,
        showValueIndicator: ShowValueIndicator.never,
      ),
      child: Slider(
        padding: const EdgeInsets.symmetric(horizontal: horizontalInset),
        value: value,
        max: max,
        activeColor: activeColor,
        inactiveColor: inactiveColor,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
      ),
    ),
  );
}
