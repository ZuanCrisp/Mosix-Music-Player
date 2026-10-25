import 'package:flutter/foundation.dart';

/// A player-local display position while a seek gesture is in progress.
/// Session tokens prevent an old seek or removed slider clearing a newer drag.
class PlaybackSeekPreview extends ChangeNotifier
    implements ValueListenable<Duration?> {
  Duration? _value;
  Object? _session;
  bool _disposed = false;

  @override
  Duration? get value => _value;

  Object begin(Duration position) {
    final session = Object();
    _session = session;
    update(session, position);
    return session;
  }

  void update(Object session, Duration position) {
    if (_disposed || !identical(session, _session) || position == _value) {
      return;
    }
    _value = position;
    notifyListeners();
  }

  void end(Object? session) {
    if (identical(session, _session)) reset();
  }

  void reset() {
    if (_disposed) return;
    _session = null;
    if (_value == null) return;
    _value = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
