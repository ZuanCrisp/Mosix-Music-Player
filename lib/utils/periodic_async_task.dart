import 'dart:async';

/// Foreground maintenance that waits between completed runs and can be paused
/// safely even while a run is awaiting I/O.
class PeriodicAsyncTask {
  PeriodicAsyncTask({required this.interval, required this.run, this.onError});
  final Duration interval;
  final Future<void> Function() run;
  final void Function(Object, StackTrace)? onError;
  Timer? _timer;
  bool _enabled = false;
  int _generation = 0;
  Future<void> _pending = Future<void>.value();

  void start({required Duration delay}) {
    if (_enabled) return;
    _enabled = true;
    _schedule(delay, _generation);
  }

  void stop() {
    _enabled = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration delay, int generation) {
    _timer = Timer(delay, () async {
      final operation = _pending.then((_) async {
        if (!_enabled || generation != _generation) return;
        try {
          await run();
        } catch (error, stack) {
          onError?.call(error, stack);
        }
      });
      _pending = operation;
      try {
        await operation;
      } finally {
        if (_enabled && generation == _generation) {
          _schedule(interval, generation);
        }
      }
    });
  }
}
