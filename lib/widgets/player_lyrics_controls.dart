import 'package:flutter/material.dart';

/// Fades controls without changing the lyric viewport or active scroll gesture.
class PlayerLyricsControlsVisibility extends StatelessWidget {
  const PlayerLyricsControlsVisibility({
    super.key,
    required this.hidden,
    required this.child,
  });

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: hidden,
    child: ExcludeSemantics(
      excluding: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: child,
      ),
    ),
  );
}
