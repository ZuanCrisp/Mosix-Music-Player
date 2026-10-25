import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  group('download storage recovery', () {
    test('requires reauthorization instead of redirecting SAF downloads', () {
      expect(
        storageWriteRecoveryFor(useSaf: true),
        StorageWriteRecovery.requestSafAccess,
      );
    });

    test('keeps automatic fallback for app-managed folders', () {
      expect(
        storageWriteRecoveryFor(useSaf: false),
        StorageWriteRecovery.useAppFolderFallback,
      );
    });
  });

  group('foreground download start policy', () {
    test('allows service launch only while the app is resumed', () {
      expect(
        canStartForegroundDownloadForLifecycle(AppLifecycleState.resumed),
        isTrue,
      );
      expect(
        canStartForegroundDownloadForLifecycle(AppLifecycleState.inactive),
        isFalse,
      );
      expect(
        canStartForegroundDownloadForLifecycle(AppLifecycleState.paused),
        isFalse,
      );
      expect(canStartForegroundDownloadForLifecycle(null), isFalse);
    });

    test('recognizes the typed platform denial', () {
      expect(
        isForegroundServiceStartNotAllowed(
          PlatformException(code: foregroundServiceStartNotAllowedCode),
        ),
        isTrue,
      );
      expect(
        isForegroundServiceStartNotAllowed(PlatformException(code: 'ERROR')),
        isFalse,
      );
    });
  });

  group('native worker stop recovery', () {
    test('requeues every in-flight snapshot state after the worker stops', () {
      for (final status in const ['preparing', 'downloading', 'finalizing']) {
        expect(
          nativeWorkerStatusAfterSnapshotStop(
            workerRunning: false,
            status: status,
          ),
          'queued',
        );
      }
    });

    test('preserves terminal states and live worker progress', () {
      expect(
        nativeWorkerStatusAfterSnapshotStop(
          workerRunning: false,
          status: 'completed',
        ),
        'completed',
      );
      expect(
        nativeWorkerStatusAfterSnapshotStop(
          workerRunning: false,
          status: 'failed',
        ),
        'failed',
      );
      expect(
        nativeWorkerStatusAfterSnapshotStop(
          workerRunning: true,
          status: 'downloading',
        ),
        'downloading',
      );
    });
  });
}
