import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';

/// Pull-to-refresh with the expressive shape-morphing indicator on Material.
/// Mornye and reduced motion keep Flutter's [RefreshIndicator].
///
/// The page on screen also refreshes through [refreshVisible], which the
/// desktop Refresh command (Cmd/Ctrl+R) runs.
class AppRefreshIndicator extends StatefulWidget {
  const AppRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
    this.notificationPredicate = defaultScrollNotificationPredicate,
  });

  final RefreshCallback onRefresh;
  final ScrollNotificationPredicate notificationPredicate;
  final Widget child;

  static final _mounted = <_AppRefreshIndicatorState>[];

  /// Refreshes the most recently opened page that is on screen, showing its
  /// indicator. Returns whether one was found.
  static bool refreshVisible() {
    for (final state in _mounted.reversed) {
      if (state._onScreen) {
        unawaited(state._show());
        return true;
      }
    }
    return false;
  }

  @override
  State<AppRefreshIndicator> createState() => _AppRefreshIndicatorState();
}

class _AppRefreshIndicatorState extends State<AppRefreshIndicator> {
  final _materialKey = GlobalKey<RefreshIndicatorState>();
  final _expressive = M3ERefreshIndicatorController();
  bool _usesExpressive = false;

  /// While a pull is under way: its status and how far it has pulled.
  M3ERefreshStatus? _status;
  double _pull = 0;

  bool get _onScreen =>
      mounted &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  /// A pull being pushed back shrinks the indicator first; the list only
  /// scrolls once the pull is gone.
  bool _holdsPull() =>
      (_status == M3ERefreshStatus.drag || _status == M3ERefreshStatus.armed) &&
      _pull > 0;

  @override
  void initState() {
    super.initState();
    AppRefreshIndicator._mounted.add(this);
  }

  @override
  void dispose() {
    AppRefreshIndicator._mounted.remove(this);
    super.dispose();
  }

  Future<void> _show() => _usesExpressive
      ? _expressive.show()
      : _materialKey.currentState?.show() ?? widget.onRefresh();

  bool _trackPull(OverscrollNotification notification) {
    final delta = notification.dragDetails?.delta.dy;
    if (_holdsPull() || _status == M3ERefreshStatus.drag) {
      if (delta != null) _pull = math.max(0, _pull + delta);
    }
    return false;
  }

  void _statusChanged(M3ERefreshStatus? status) {
    // A new pull starts from nothing; falling back from armed keeps it.
    if (status == M3ERefreshStatus.drag && _status != M3ERefreshStatus.armed) {
      _pull = 0;
    }
    _status = status;
  }

  @override
  Widget build(BuildContext context) {
    _usesExpressive = materialExpressiveEnabled(context);
    if (!_usesExpressive) {
      return RefreshIndicator(
        key: _materialKey,
        onRefresh: widget.onRefresh,
        notificationPredicate: widget.notificationPredicate,
        child: widget.child,
      );
    }
    Widget indicator = M3ERefreshIndicator.contained(
      controller: _expressive,
      onRefresh: widget.onRefresh,
      notificationPredicate: widget.notificationPredicate,
      onStatusChange: _statusChanged,
      child: NotificationListener<OverscrollNotification>(
        onNotification: _trackPull,
        child: widget.child,
      ),
    );
    // macOS lists bounce past their top edge. Under a pinned header that
    // bounce opens a gap below the title, and the indicator ignores a pull
    // that starts while it is still closing, so the top edge stays put.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final behavior = ScrollConfiguration.of(context);
      indicator = ScrollConfiguration(
        behavior: behavior.copyWith(
          physics: _PullEdgeScrollPhysics(
            holdsPull: _holdsPull,
            parent: behavior.getScrollPhysics(context),
          ),
        ),
        child: indicator,
      );
    }
    return MaterialExpressiveScope(child: indicator);
  }
}

/// Stops the leading edge instead of bouncing past it, and keeps the list
/// at that edge while [holdsPull]. A refused move is reported as overscroll,
/// so the indicator still follows the pointer.
class _PullEdgeScrollPhysics extends ScrollPhysics {
  const _PullEdgeScrollPhysics({required this.holdsPull, super.parent});

  final bool Function() holdsPull;

  @override
  _PullEdgeScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _PullEdgeScrollPhysics(
        holdsPull: holdsPull,
        parent: buildParent(ancestor),
      );

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    final min = position.minScrollExtent;
    if (value < position.pixels && position.pixels <= min) {
      return value - position.pixels;
    }
    if (value < min && min < position.pixels) return value - min;
    if (value > position.pixels && position.pixels <= min && holdsPull()) {
      return value - position.pixels;
    }
    return super.applyBoundaryConditions(position, value);
  }
}
