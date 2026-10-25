import 'package:flutter/widgets.dart';

/// The painted text and its reserved height follow the same progress. Cropping
/// full-size text while only shrinking its container makes toggles look jerky.
class LyricSupplementTransition extends StatelessWidget {
  const LyricSupplementTransition({
    super.key,
    required this.visibility,
    required this.child,
    this.alignment = Alignment.topLeft,
  });

  final double visibility;
  final Widget child;
  final Alignment alignment;

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
