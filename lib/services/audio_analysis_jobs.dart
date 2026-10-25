import 'dart:async';

class AudioAnalysisCancelled implements Exception {
  const AudioAnalysisCancelled();
}

/// Serializes native analysis sessions and cancels only the owned session.
/// A replacement waits for native completion before creating its output files.
class AudioAnalysisJobs<T> {
  final Future<({int id, Future<T> completed})> Function(List<String>) start;
  final Future<void> Function(int) cancel;
  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  int? _activeId;
  bool _disposed = false;

  AudioAnalysisJobs({required this.start, required this.cancel});

  void invalidate() {
    _generation++;
    final id = _activeId;
    if (id != null) unawaited(_cancel(id));
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }

  Future<void> _cancel(int id) async {
    try {
      await cancel(id);
    } catch (_) {
      // Await the native completion even if the cancellation request fails.
    }
  }

  Future<T> run(List<String> arguments) {
    final generation = _generation;
    void checkCurrent() {
      if (_disposed || generation != _generation) {
        throw const AudioAnalysisCancelled();
      }
    }

    final result = _tail.then((_) async {
      checkCurrent();
      final session = await start(arguments);
      _activeId = session.id;
      try {
        if (_disposed || generation != _generation) {
          await _cancel(session.id);
        }
        final value = await session.completed;
        checkCurrent();
        return value;
      } finally {
        _activeId = null;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
