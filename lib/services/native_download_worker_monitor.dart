enum NativeDownloadWorkerExit { stopped, serviceLost }

class NativeDownloadWorkerStartupTimeout implements Exception {
  @override
  String toString() => 'Native worker did not publish run snapshot';
}

/// Follows one native run without trusting a persisted "running" flag after
/// its service dies. Snapshot reconciliation finishes before the next poll.
class NativeDownloadWorkerMonitor {
  const NativeDownloadWorkerMonitor({
    required this.readSnapshot,
    required this.matchesRun,
    required this.isServiceAlive,
    this.pollInterval = const Duration(seconds: 1),
    this.startupPollInterval = const Duration(milliseconds: 250),
    this.startupTimeout = const Duration(seconds: 30),
  });

  final Future<Map<String, dynamic>> Function({int sinceStateSerial})
  readSnapshot;
  final bool Function(Map<String, dynamic>) matchesRun;
  final Future<bool> Function() isServiceAlive;
  final Duration pollInterval;
  final Duration startupPollInterval;
  final Duration startupTimeout;

  Future<NativeDownloadWorkerExit> run({
    required Future<void> Function(Map<String, dynamic>) onSnapshot,
  }) async {
    final started = Stopwatch()..start();
    var lastStateSerial = 0;
    var deadServicePolls = 0;
    var receivedRun = false;
    while (true) {
      final snapshot = await readSnapshot(sinceStateSerial: lastStateSerial);
      final matches = matchesRun(snapshot);
      receivedRun |= matches;
      if (receivedRun && (!matches || snapshot['is_running'] == true)) {
        deadServicePolls = await isServiceAlive() ? 0 : deadServicePolls + 1;
        if (deadServicePolls >= 3) {
          if (matches) {
            // Preserve completed results, but reclaim in-flight work rather
            // than restoring a dead worker's downloading/finalizing state.
            await onSnapshot({...snapshot, 'is_running': false});
          }
          return NativeDownloadWorkerExit.serviceLost;
        }
      }
      if (!matches) {
        lastStateSerial = 0;
        if (started.elapsed > startupTimeout) {
          throw NativeDownloadWorkerStartupTimeout();
        }
        await Future<void>.delayed(startupPollInterval);
        continue;
      }
      await onSnapshot(snapshot);
      final serial = snapshot['state_serial'];
      if (serial is num && serial > 0) lastStateSerial = serial.toInt();
      if (snapshot['is_running'] != true) {
        return NativeDownloadWorkerExit.stopped;
      }
      await Future<void>.delayed(pollInterval);
    }
  }
}
