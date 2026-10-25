import 'dart:async';

/// Shared scaffold for consuming a native progress stream (EventChannel-backed)
/// with a bootstrap-timeout fallback to polling, an in-flight guard against
/// re-entrant processing, and an error-count throttle that suppresses log
/// spam after repeated consecutive failures.
///
/// Callers own all logging text (via the `on*Error`/`onStreamTimeout`/
/// `onStreamFailed` callbacks) and platform gating (via [start]'s [useStream]
/// argument), so behavior stays identical to each call site's prior bespoke
/// implementation.
class ProgressStreamPoller<T> {
  ProgressStreamPoller({
    required this.streamProvider,
    required this.pollProvider,
    required this.onProgress,
    required this.pollingInterval,
    required this.bootstrapTimeout,
    required this.onStreamProcessingError,
    required this.onStreamFailed,
    required this.onStreamTimeout,
    required this.onPollError,
    this.shouldPollTick,
  });

  final Stream<T> Function() streamProvider;
  final Future<T> Function() pollProvider;
  final Future<void> Function(T progress) onProgress;
  final Duration pollingInterval;
  final Duration bootstrapTimeout;

  /// Optional gate checked on every periodic poll tick (stream events are
  /// never gated), after the in-flight guard; returning false skips that
  /// tick without fetching or affecting the error counter. Used for
  /// idle-cadence throttling.
  final bool Function()? shouldPollTick;

  /// Called when a stream event's [onProgress] throws, only while the error
  /// count is within the log-spam threshold.
  final void Function(Object error) onStreamProcessingError;

  /// Called when the stream itself errors, before falling back to polling.
  final void Function(Object error) onStreamFailed;

  /// Called when no stream event arrived before [bootstrapTimeout].
  final void Function() onStreamTimeout;

  /// Called when a poll tick's [onProgress] throws, only while the error
  /// count is within the log-spam threshold.
  final void Function(Object error) onPollError;

  static const _errorLogThreshold = 3;

  Timer? _timer;
  Timer? _bootstrapTimer;
  StreamSubscription<T>? _sub;
  bool _hasReceivedStreamEvent = false;
  bool _usingStream = false;
  int? _inFlightGeneration;
  int _errorCount = 0;
  int _generation = 0;

  /// (Re)starts progress consumption. When [useStream] is true, attaches the
  /// stream (falling back to polling on timeout/error); otherwise starts
  /// polling immediately.
  void start({required bool useStream}) {
    _generation++;
    final generation = _generation;
    _timer?.cancel();
    _bootstrapTimer?.cancel();
    _bootstrapTimer = null;
    _sub?.cancel();
    _sub = null;
    _hasReceivedStreamEvent = false;
    _usingStream = false;

    if (useStream) {
      _attachStream(generation);
      return;
    }
    startPollingTimer(generation: generation);
  }

  void _attachStream(int generation) {
    _sub = streamProvider().listen(
      (progress) async {
        if (generation != _generation) return;
        _hasReceivedStreamEvent = true;
        _usingStream = true;
        _bootstrapTimer?.cancel();
        _bootstrapTimer = null;
        await _runGuarded(
          () async => progress,
          onStreamProcessingError,
          generation: generation,
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _generation) return;
        if (_usingStream) {
          onStreamFailed(error);
        }
        _sub?.cancel();
        _sub = null;
        _usingStream = false;
        _bootstrapTimer?.cancel();
        _bootstrapTimer = null;
        startPollingTimer(generation: generation);
      },
      cancelOnError: false,
    );

    _bootstrapTimer = Timer(bootstrapTimeout, () {
      if (generation != _generation) return;
      if (_hasReceivedStreamEvent) return;
      onStreamTimeout();
      _sub?.cancel();
      _sub = null;
      _usingStream = false;
      startPollingTimer(generation: generation);
    });
  }

  /// (Re)starts the fallback polling timer.
  void startPollingTimer({int? generation}) {
    final activeGeneration = generation ?? _generation;
    if (activeGeneration != _generation) return;
    _timer?.cancel();
    _timer = Timer.periodic(pollingInterval, (_) async {
      await _runGuarded(
        pollProvider,
        onPollError,
        gate: shouldPollTick,
        generation: activeGeneration,
      );
    });
  }

  /// One-shot immediate fetch reusing the same in-flight guard and error
  /// counter as the periodic poll, with its own error callback.
  Future<void> pollOnce(void Function(Object error) onError) =>
      _runGuarded(pollProvider, onError, generation: _generation);

  Future<void> _runGuarded(
    Future<T> Function() fetch,
    void Function(Object error) onError, {
    bool Function()? gate,
    required int generation,
  }) async {
    if (generation != _generation || _inFlightGeneration == generation) return;
    _inFlightGeneration = generation;
    try {
      if (gate != null && !gate()) return;
      final progress = await fetch();
      if (generation != _generation) return;
      await onProgress(progress);
      if (generation != _generation) return;
      _errorCount = 0;
    } catch (e) {
      if (generation != _generation) return;
      _errorCount++;
      if (_errorCount <= _errorLogThreshold) {
        onError(e);
      }
    } finally {
      if (_inFlightGeneration == generation) {
        _inFlightGeneration = null;
      }
    }
  }

  /// Cancels timers/subscription and resets guard/counter state, without
  /// releasing the poller for reuse (matches each caller's `_stop*` reset).
  void stop() {
    _generation++;
    _timer?.cancel();
    _bootstrapTimer?.cancel();
    _sub?.cancel();
    _timer = null;
    _bootstrapTimer = null;
    _sub = null;
    _errorCount = 0;
    _inFlightGeneration = null;
    _hasReceivedStreamEvent = false;
    _usingStream = false;
  }
}
