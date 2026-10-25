import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mosix/theme/material_expressive.dart';

/// Expressive actions retain caller colors, disabled states and flexible labels.
class ExpressiveButton extends StatelessWidget {
  const ExpressiveButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.icon,
    this.style,
    this.outlined = false,
    this.tonal = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final Widget? icon;
  final ButtonStyle? style;
  final bool outlined;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[icon!, const SizedBox(width: 8)],
        Flexible(child: child),
      ],
    );
    if (!materialExpressiveEnabled(context)) {
      if (outlined) {
        return OutlinedButton(
          onPressed: onPressed,
          style: style,
          child: content,
        );
      }
      if (tonal) {
        return FilledButton.tonal(
          onPressed: onPressed,
          style: style,
          child: content,
        );
      }
      return FilledButton(onPressed: onPressed, style: style, child: content);
    }
    final states = <WidgetState>{if (onPressed == null) WidgetState.disabled};
    return MaterialExpressiveScope(
      child: M3EButton(
        onPressed: onPressed,
        style: outlined
            ? M3EButtonStyle.outlined
            : tonal
            ? M3EButtonStyle.tonal
            : M3EButtonStyle.filled,
        decoration: M3EButtonDecoration(
          backgroundColor: style?.backgroundColor,
          foregroundColor: style?.foregroundColor,
          overlayColor: style?.overlayColor,
          side: style?.side,
          minimumSize:
              style?.minimumSize?.resolve(states) ?? const Size(48, 48),
          maximumSize: style?.maximumSize?.resolve(states),
          fixedSize: style?.fixedSize?.resolve(states),
          padding: style?.padding?.resolve(states),
          textStyle: style?.textStyle?.resolve(states),
          iconSize: style?.iconSize?.resolve(states),
        ),
        child: content,
      ),
    );
  }
}
