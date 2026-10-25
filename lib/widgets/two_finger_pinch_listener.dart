import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Observes a two-finger pinch without competing in Flutter's gesture arena.
///
/// A regular [GestureDetector.onScaleUpdate] also recognizes one-finger pans.
/// When wrapped around a scrollable, it can therefore win against the
/// scrollable's drag recognizer and make a vertical scroll stop unexpectedly.
/// Raw pointer observation keeps normal one-finger scrolling untouched while
/// still exposing a scale factor once exactly two touch pointers are present.
class TwoFingerPinchListener extends StatefulWidget {
  const TwoFingerPinchListener({
    super.key,
    required this.child,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final Widget child;
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final VoidCallback onEnd;

  @override
  State<TwoFingerPinchListener> createState() => _TwoFingerPinchListenerState();
}

class _TwoFingerPinchListenerState extends State<TwoFingerPinchListener> {
  final Map<int, Offset> _touchPositions = <int, Offset>{};
  double? _initialSpan;
  bool _pinching = false;

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touchPositions[event.pointer] = event.localPosition;

    if (_touchPositions.length == 2) {
      _beginPinch();
    } else if (_touchPositions.length > 2) {
      _endPinch();
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_touchPositions.containsKey(event.pointer)) return;
    _touchPositions[event.pointer] = event.localPosition;

    final initialSpan = _initialSpan;
    if (!_pinching || initialSpan == null || _touchPositions.length != 2) {
      return;
    }

    final span = _currentSpan;
    if (span <= 0) return;
    widget.onUpdate(span / initialSpan);
  }

  void _handlePointerEnd(PointerEvent event) {
    if (_touchPositions.remove(event.pointer) == null) return;
    _endPinch();

    // If a third finger was present, resume with the two remaining pointers
    // using their current distance as a fresh scale baseline.
    if (_touchPositions.length == 2) {
      _beginPinch();
    }
  }

  double get _currentSpan {
    final positions = _touchPositions.values.take(2).toList(growable: false);
    if (positions.length != 2) return 0;
    return (positions[0] - positions[1]).distance;
  }

  void _beginPinch() {
    final span = _currentSpan;
    if (span <= 0) return;
    _initialSpan = span;
    _pinching = true;
    widget.onStart();
  }

  void _endPinch() {
    if (_pinching) widget.onEnd();
    _pinching = false;
    _initialSpan = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerEnd,
      onPointerCancel: _handlePointerEnd,
      child: widget.child,
    );
  }
}
