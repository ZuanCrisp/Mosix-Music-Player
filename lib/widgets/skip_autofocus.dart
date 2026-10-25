import 'dart:async';

import 'package:flutter/widgets.dart';

/// Mounts [child] without letting it take keyboard focus.
///
/// `M3EButtonGroup` autofocuses its first enabled segment. On desktop that
/// moves focus off the app's idle node, so Space presses the segment instead
/// of toggling playback. The descendants stay unfocusable until the
/// autofocus pass of the mounting frame has run; after that, Tab and
/// clicks reach them as usual.
class SkipAutofocus extends StatefulWidget {
  const SkipAutofocus({super.key, required this.child});

  final Widget child;

  @override
  State<SkipAutofocus> createState() => _SkipAutofocusState();
}

class _SkipAutofocusState extends State<SkipAutofocus> {
  var _focusable = false;

  @override
  void initState() {
    super.initState();
    // Autofocus applies in a microtask the mounting frame's build queues. A
    // microtask queued after that frame runs after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduleMicrotask(() {
        if (mounted) setState(() => _focusable = true);
      });
    });
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    descendantsAreFocusable: _focusable,
    child: widget.child,
  );
}
