import 'package:connectivity_plus/connectivity_plus.dart';

/// Debounces independent responses to network changes without UI dependencies.
class DownloadConnectivityPolicy {
  Set<ConnectivityResult>? _previous;
  DateTime? _lastCleanup;
  DateTime? _lastRetry;

  bool shouldCleanup(List<ConnectivityResult> results, DateTime now) {
    final current = results.toSet();
    final previous = _previous;
    _previous = current;
    if (previous == null ||
        (previous.length == current.length && previous.containsAll(current))) {
      return false;
    }
    if (_lastCleanup != null &&
        now.difference(_lastCleanup!) < const Duration(seconds: 2)) {
      return false;
    }
    _lastCleanup = now;
    return true;
  }

  bool shouldOfferRetry({
    required List<ConnectivityResult> results,
    required int failedCount,
    required DateTime now,
  }) {
    if (failedCount == 0 ||
        results.every((result) => result == ConnectivityResult.none) ||
        (_lastRetry != null &&
            now.difference(_lastRetry!) < const Duration(minutes: 1))) {
      return false;
    }
    _lastRetry = now;
    return true;
  }
}
