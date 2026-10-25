import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mosix/theme/material_expressive.dart';
import 'package:mosix/theme/mornye_theme.dart';

/// One inline surface, matching the metadata groups and dialog controls.
class AppContentCard extends StatelessWidget {
  const AppContentCard({
    super.key,
    required this.child,
    this.color,
    this.shape,
    this.elevation,
    this.clipBehavior = Clip.none,
    this.preserveColor = false,
  });

  final Widget child;
  final Color? color;
  final ShapeBorder? shape;
  final double? elevation;
  final Clip clipBehavior;
  final bool preserveColor;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye) {
      if (materialExpressiveEnabled(context) &&
          (shape == null || shape is RoundedRectangleBorder)) {
        return Padding(
          padding: CardTheme.of(context).margin ?? const EdgeInsets.all(4),
          child: MaterialExpressiveScope(
            child: M3ECard(
              variant: M3ECardVariant.filled,
              padding: EdgeInsets.zero,
              color: color,
              elevation: elevation ?? 0,
              border: shape is RoundedRectangleBorder
                  ? (shape as RoundedRectangleBorder).side
                  : null,
              borderRadius: shape is RoundedRectangleBorder
                  ? (shape as RoundedRectangleBorder).borderRadius.resolve(
                      Directionality.of(context),
                    )
                  : BorderRadius.circular(20),
              clipBehavior: clipBehavior,
              child: Material(color: Colors.transparent, child: child),
            ),
          ),
        );
      }
      return Card(
        color: color,
        shape: shape,
        elevation: elevation,
        clipBehavior: clipBehavior,
        child: child,
      );
    }
    return Material(
      color: preserveColor ? color : MornyeTheme.controlFill(context),
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: DividerTheme(
        data: DividerTheme.of(
          context,
        ).copyWith(color: MornyeTheme.metadataDividerColor(context)),
        child: child,
      ),
    );
  }
}
