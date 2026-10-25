import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/material_expressive.dart';

/// A row of header actions laid out as a Material 3 Expressive button group.
///
/// [flexible] actions share the free width; the others keep a [slotWidth]
/// box. Pressing an action widens it while its neighbours give way. Without
/// expressive motion the row keeps the centred, content-sized layout with
/// [Flexible] actions that it replaces.
class ExpressiveButtonGroup extends StatefulWidget {
  const ExpressiveButtonGroup({
    super.key,
    required this.children,
    this.flexible = const {},
    this.spacing = 12,
    this.slotWidth = 48,
  });

  final List<Widget> children;

  /// Indices of [children] that fill the remaining width.
  final Set<int> flexible;
  final double spacing;
  final double slotWidth;

  @override
  State<ExpressiveButtonGroup> createState() => _ExpressiveButtonGroupState();
}

/// Width an [ExpressiveButtonGroup] gives a fixed action, so an icon button
/// can stretch its container along with the squish.
class ExpressiveButtonGroupSlot extends InheritedWidget {
  const ExpressiveButtonGroupSlot({
    super.key,
    required this.width,
    required super.child,
  });

  final double width;

  static double? widthOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ExpressiveButtonGroupSlot>()
      ?.width;

  @override
  bool updateShouldNotify(ExpressiveButtonGroupSlot oldWidget) =>
      width != oldWidget.width;
}

class _ExpressiveButtonGroupState extends State<ExpressiveButtonGroup> {
  static const _squishRatio = 0.15;
  static final _pressSpring = SpringCurve(M3EMotion.expressiveSpatialPress);

  int? _pressed;

  void _press(int? index) {
    if (_pressed != index) setState(() => _pressed = index);
  }

  @override
  Widget build(BuildContext context) {
    final children = widget.children;
    final expressive = materialExpressiveEnabled(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(width: widget.spacing),
          if (!expressive)
            widget.flexible.contains(i)
                ? Flexible(child: children[i])
                : children[i]
          else
            _slot(i),
        ],
      ],
    );
  }

  Widget _slot(int index) {
    final pressed = _pressed;
    final neighbour = pressed != null && (index - pressed).abs() == 1;
    final child = Listener(
      onPointerDown: (_) => _press(index),
      onPointerUp: (_) => _press(null),
      onPointerCancel: (_) => _press(null),
      child: widget.children[index],
    );
    if (widget.flexible.contains(index)) {
      // A flexible action grows into whatever its fixed neighbours yield; it
      // only trades weight with another flexible action.
      final weight = pressed == index
          ? 1 + _squishRatio
          : neighbour && widget.flexible.contains(pressed)
          ? 1 - _squishRatio
          : 1.0;
      return TweenAnimationBuilder<double>(
        tween: Tween(end: weight),
        duration: _pressSpring.duration,
        curve: _pressSpring,
        builder: (context, weight, child) =>
            Expanded(flex: math.max(1, (weight * 1000).round()), child: child!),
        child: child,
      );
    }
    final width =
        widget.slotWidth *
        (pressed == index
            ? 1 + _squishRatio
            : neighbour
            ? 1 - _squishRatio
            : 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: width),
      duration: _pressSpring.duration,
      curve: _pressSpring,
      builder: (context, width, child) {
        final slot = math.max(0.0, width);
        return SizedBox(
          width: slot,
          child: ExpressiveButtonGroupSlot(width: slot, child: child!),
        );
      },
      child: child,
    );
  }
}
