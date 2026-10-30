import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

/// Uses the same outline as the optical lens, including its continuous corners.
/// The fill, shadow, clip and rim must agree to avoid cutting off the glass edge.
class MosixSquircleBorder extends ShapeBorder {
  const MosixSquircleBorder(this.radius);

  final double radius;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  ShapeBorder scale(double t) => MosixSquircleBorder(radius * t);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      liquidGlassSquirclePath(rect.size, radius, 1).shift(rect.topLeft);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  bool operator ==(Object other) =>
      other is MosixSquircleBorder && other.radius == radius;

  @override
  int get hashCode => radius.hashCode;
}
