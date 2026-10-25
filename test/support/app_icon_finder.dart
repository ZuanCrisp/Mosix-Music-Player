import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/app_icon.dart';

/// Finds [icon] whether it is drawn by a plain [Icon] or by an [AppIcon],
/// which may render a Material Symbol in its place.
Finder findAppIcon(IconData icon) => find.byElementPredicate((element) {
  final widget = element.widget;
  if (widget is AppIcon) return widget.icon == icon;
  if (widget is! Icon || widget.icon != icon) return false;
  // An AppIcon that already matched owns this glyph; a mapped one does not.
  var ownerMatched = false;
  element.visitAncestorElements((ancestor) {
    final owner = ancestor.widget;
    ownerMatched = owner is AppIcon && owner.icon == icon;
    return false;
  });
  return !ownerMatched;
}, description: 'icon $icon');
