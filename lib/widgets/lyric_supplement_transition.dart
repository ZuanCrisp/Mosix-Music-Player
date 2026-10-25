import 'package:flutter/widgets.dart';

/// The painted text and its reserved height follow the same progress. Cropping
/// full-size text while only shrinking its container makes toggles look jerky.
class LyricSupplementTransition extends StatelessWidget {
  const LyricSupplementTransition({
    super.key,
    required this.visibility,
    required this.child,
    this.alignment = AlignmentDirectional.topStart,
  });

  final double visibility;
  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => Align(
    alignment: alignment,
    heightFactor: visibility,
    child: Opacity(
      opacity: visibility,
      child: Transform.scale(
        scale: visibility,
        alignment: alignment,
        child: child,
      ),
    ),
  );
}

/// Backing vocals drop out from under their lead line: the row opens while
/// the full-size text slides down into it, instead of growing in place.
class LyricBackingTransition extends StatelessWidget {
  const LyricBackingTransition({
    super.key,
    required this.visibility,
    required this.child,
    this.alignment = AlignmentDirectional.topStart,
  });

  final double visibility;
  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    // Text emerges from the lead's lower edge, so clip to the opening row.
    // A shown row keeps the same tree unclipped, leaving blur halos intact.
    return ClipRect(
      clipBehavior: visibility >= 1 ? Clip.none : Clip.hardEdge,
      child: Align(
        alignment: alignment,
        heightFactor: visibility,
        child: Opacity(
          opacity: Curves.easeOut.transform(visibility.clamp(0.0, 1.0)),
          child: FractionalTranslation(
            translation: Offset(0, visibility - 1),
            child: child,
          ),
        ),
      ),
    );
  }
}
