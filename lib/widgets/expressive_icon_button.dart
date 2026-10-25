import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/expressive_button_group.dart';

/// Compact expressive transport/header actions with the same accessible target
/// and tooltip as the standard Material fallback.
class ExpressiveIconButton extends StatelessWidget {
  const ExpressiveIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected,
    this.size = 48,
    this.iconSize = 24,
    this.foregroundColor,
    this.backgroundColor,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool? selected;
  final double size;
  final double iconSize;
  final Color? foregroundColor;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final icon = symbolIconWidget(this.icon);
    final scheme = Theme.of(context).colorScheme;
    final foreground = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.disabled)) {
        return scheme.onSurface.withValues(alpha: 0.38);
      }
      return foregroundColor;
    });
    final background = WidgetStateProperty.resolveWith<Color?>((states) {
      if (backgroundColor == null) return Colors.transparent;
      return states.contains(WidgetState.disabled)
          ? scheme.onSurface.withValues(alpha: 0.12)
          : backgroundColor;
    });
    if (!materialExpressiveEnabled(context)) {
      return IconButton(
        icon: icon,
        iconSize: iconSize,
        tooltip: tooltip,
        onPressed: onPressed,
        isSelected: selected,
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size.square(size)),
          foregroundColor: foreground,
          backgroundColor: background,
        ),
      );
    }
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      // One labeled node instead of a label plus an unnamed tap target.
      child: MergeSemantics(
        child: MaterialExpressiveScope(
          child: M3EIconButton(
            icon: IconTheme.merge(
              data: IconThemeData(size: iconSize),
              child: icon,
            ),
            semanticLabel: tooltip,
            onPressed: onPressed,
            isSelected: selected,
            // Widens with an expressive button group's squish.
            visualSize: Size(
              ExpressiveButtonGroupSlot.widthOf(context) ?? size,
              size,
            ),
            variant: backgroundColor == null
                ? M3EIconButtonVariant.standard
                : M3EIconButtonVariant.filled,
            decoration: M3EIconButtonDecoration(
              foregroundColor: foreground,
              backgroundColor: background,
            ),
          ),
        ),
      ),
    );
  }
}
