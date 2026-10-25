import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/download_connectivity_policy.dart';

void main() {
  test(
    'reconnect retry waits for connectivity/failures and debounces flapping',
    () {
      final policy = DownloadConnectivityPolicy();
      final start = DateTime.utc(2026);
      bool retry(int seconds, {int count = 2, bool online = true}) =>
          policy.shouldOfferRetry(
            results: [
              online ? ConnectivityResult.wifi : ConnectivityResult.none,
            ],
            failedCount: count,
            now: start.add(Duration(seconds: seconds)),
          );
      expect(retry(0, online: false), isFalse);
      expect(retry(0, count: 0), isFalse);
      expect(retry(0), isTrue);
      expect(retry(59), isFalse);
      expect(retry(60), isTrue);
      expect(retry(120, online: false), isFalse);
      expect(retry(120), isTrue);
    },
  );

  test('connection cleanup compares sets and debounces interface switches', () {
    final policy = DownloadConnectivityPolicy();
    final start = DateTime.utc(2026);
    bool cleanup(List<ConnectivityResult> results, int seconds) =>
        policy.shouldCleanup(results, start.add(Duration(seconds: seconds)));
    expect(cleanup([ConnectivityResult.wifi], 0), isFalse);
    expect(cleanup([ConnectivityResult.mobile], 1), isTrue);
    expect(cleanup([ConnectivityResult.wifi], 2), isFalse);
    expect(cleanup([ConnectivityResult.wifi], 3), isFalse);
    expect(
      cleanup([ConnectivityResult.wifi, ConnectivityResult.mobile], 3),
      isTrue,
    );
    expect(
      cleanup([ConnectivityResult.mobile, ConnectivityResult.wifi], 4),
      isFalse,
    );
    expect(cleanup([ConnectivityResult.none], 5), isTrue);
  });
}
