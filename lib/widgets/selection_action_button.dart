import 'package:flutter/material.dart';
import 'package:mosix/theme/app_tokens.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/widgets/app_action_button.dart';
import 'package:mosix/widgets/expressive_button.dart';

/// Icon+label pill used in selection-mode bottom bars, with the active theme's
/// disabled tones and room for a two-line label.
class SelectionActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final ColorScheme colorScheme;

  const SelectionActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return AppActionButton(
        outlined: true,
        tonal: true,
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
        fontSize: 15,
      );
    }
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: ExpressiveButton(
        tonal: true,
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.secondaryContainer,
          foregroundColor: colorScheme.onSecondaryContainer,
          minimumSize: Size(48, context.tokens.minTouchTarget),
          padding: const EdgeInsets.all(12),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}
