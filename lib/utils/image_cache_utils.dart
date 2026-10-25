import 'package:flutter/widgets.dart';

int coverCacheWidthForViewport(
  BuildContext context, {
  double widthMultiplier = 1.0,
  int min = 320,
  int max = 2048,
}) {
  final dpr = MediaQuery.devicePixelRatioOf(context);
  final logicalWidth = MediaQuery.sizeOf(context).width * widthMultiplier;
  return (logicalWidth * dpr).round().clamp(min, max);
}
