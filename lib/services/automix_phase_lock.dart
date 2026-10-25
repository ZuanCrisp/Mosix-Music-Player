import 'dart:math' as math;

/// Small, bounded tempo corrections while two trusted beat grids overlap.
/// Samples are spaced and grouped so a delayed position report cannot cause
/// repeated corrections before buffered audio has caught up.
class AutoMixPhaseLock {
  AutoMixPhaseLock({required this.baseRate, required this.period});

  final double baseRate;
  final double period;
  final _errors = <double>[];
  var _nextSample = const Duration(milliseconds: 300);
  var _pulseEnd = Duration.zero;
  double? _pulseRate;
  var _misses = 0;
  bool trusted = true;

  bool shouldMeasure(Duration elapsed) =>
      trusted && _pulseRate == null && elapsed >= _nextSample;

  double rateAt(Duration elapsed) {
    if (_pulseRate != null && elapsed >= _pulseEnd) {
      _pulseRate = null;
      _nextSample = elapsed + const Duration(milliseconds: 300);
    }
    return _pulseRate ?? baseRate;
  }

  /// Positive error means the incoming deck is ahead, in source seconds.
  void observe(Duration elapsed, double? error) {
    if (!shouldMeasure(elapsed)) return;
    _nextSample = elapsed + const Duration(milliseconds: 200);
    if (error == null ||
        !error.isFinite ||
        period <= 0 ||
        error.abs() > period * 0.3) {
      _errors.clear();
      if (++_misses >= 3) trusted = false;
      return;
    }
    _errors.add(error);
    if (_errors.length < 3) return;
    _errors.sort();
    final median = _errors[1];
    final spread = _errors.last - _errors.first;
    _errors.clear();
    if (spread > 0.04) {
      if (++_misses >= 3) trusted = false;
      return;
    }
    _misses = 0;
    if (median.abs() <= 0.015) return;
    final correction = (-median / 0.6).clamp(-baseRate * 0.02, baseRate * 0.02);
    final adjusted = (baseRate + correction).clamp(0.90, 1.10);
    final delta = adjusted - baseRate;
    if (delta.abs() < 0.0001) return;
    final seconds = math.min(0.6, math.max(0.1, (median / delta).abs()));
    _pulseRate = adjusted;
    _pulseEnd = elapsed + Duration(microseconds: (seconds * 1e6).round());
  }
}
