import 'dart:async';

import 'package:flutter/widgets.dart';

/// Completes once an Activity is attached to the Flutter engine.
///
/// A media service (for example media resumption after boot) can start the
/// engine without an Activity. The backend channel is registered only when
/// MainActivity attaches, so startup work that calls it must wait. The engine
/// reports no lifecycle state until an Activity attaches.
Future<void> waitForActivityAttachment(WidgetsBinding binding) {
  bool attached(AppLifecycleState? state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
  if (attached(binding.lifecycleState)) return Future<void>.value();
  final observer = _AttachmentObserver(attached);
  binding.addObserver(observer);
  return observer.done.future.whenComplete(
    () => binding.removeObserver(observer),
  );
}

class _AttachmentObserver with WidgetsBindingObserver {
  _AttachmentObserver(this._attached);

  final bool Function(AppLifecycleState? state) _attached;
  final done = Completer<void>();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_attached(state) && !done.isCompleted) done.complete();
  }
}
