import 'package:mornye/utils/logger.dart';

final _log = AppLogger('SourceDeletionEvents');

/// Confirmed storage deletions. Owners unsubscribe when their lifetime ends;
/// publishers await cleanup without adopting failures from its consumers.
class SourceDeletionEvents {
  static final instance = SourceDeletionEvents();

  final _listeners = <Object, Future<void> Function(String)>{};

  void Function() subscribe(Future<void> Function(String) listener) {
    final token = Object();
    _listeners[token] = listener;
    return () {
      _listeners.remove(token);
    };
  }

  Future<void> publish(String source) async {
    for (final entry in Map.of(_listeners).entries) {
      if (!_listeners.containsKey(entry.key)) continue;
      try {
        await entry.value(source);
      } catch (error) {
        _log.w('Could not clean up a deleted source: $error');
      }
    }
  }
}
