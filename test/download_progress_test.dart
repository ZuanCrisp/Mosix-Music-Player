import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_state.dart';
import 'package:mornye/providers/download_progress.dart';

DownloadItem _item({DownloadStatus status = DownloadStatus.downloading}) =>
    DownloadItem(
      id: 'item',
      track: const Track(
        id: 'example:track',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1000,
      ),
      service: 'extension.example',
      status: status,
      createdAt: DateTime.utc(2026),
    );

void main() {
  test(
    'preparation resets transfer values while finalization preserves them',
    () {
      final item = _item().copyWith(
        progress: .42,
        speedMBps: 2.3,
        bytesReceived: 123,
        bytesTotal: 456,
        filePath: 'content://example/file',
      );
      final preparing = DownloadProgressSample.fromNative({
        'status': 'preparing',
        'stage': 'decrypt',
        'bytes_received': 999,
      }).applyTo(item);
      expect(preparing.preparationStage, 'decrypt');
      expect(preparing.progress, 0);
      expect(preparing.bytesReceived, 0);
      expect(preparing.bytesTotal, 0);
      expect(preparing.speedMBps, 0);
      expect(preparing.filePath, item.filePath);
      final finalizing = DownloadProgressSample.fromNative({
        'status': 'finalizing',
      }).applyTo(item.copyWith(preparationStage: 'decrypt'));
      expect(finalizing.status, DownloadStatus.finalizing);
      expect(finalizing.progress, 1);
      expect(finalizing.bytesReceived, item.bytesReceived);
      expect(finalizing.bytesTotal, item.bytesTotal);
      expect(finalizing.speedMBps, item.speedMBps);
      expect(finalizing.preparationStage, '');
    },
  );

  test(
    'quantizes samples, supports unknown totals, and retains equal snapshots',
    () {
      final sample = DownloadProgressSample.fromNative({
        'bytes_received': 210000,
        'bytes_total': 1000000,
        'progress': .9,
        'speed_mbps': 2.24,
      });
      final original = _item();
      final item = sample.applyTo(original);
      expect(item.progress, .21);
      expect(item.bytesReceived, 209714);
      expect(item.speedMBps, 2.2);
      expect(original.progress, 0);
      expect(sample.applyTo(item), same(item));
      final unknownTotal = DownloadProgressSample.fromNative({
        'progress': .0001,
        'is_downloading': true,
      }).applyTo(item);
      expect(unknownTotal.progress, .01);
      expect(unknownTotal.bytesTotal, 0);
      final overshoot = DownloadProgressSample.fromNative({
        'progress': 1.2,
        'speed_mbps': -1,
      }).applyTo(item);
      expect(overshoot.progress, 1);
      expect(overshoot.speedMBps, 0);
    },
  );

  test(
    'ignores empty samples and protects finalizing/cancelled/terminal items',
    () {
      final sample = DownloadProgressSample.fromNative({'progress': .5});
      for (final status in [
        DownloadStatus.finalizing,
        DownloadStatus.skipped,
        DownloadStatus.completed,
        DownloadStatus.failed,
      ]) {
        final item = _item(status: status);
        expect(sample.applyTo(item), same(item));
      }
      final item = _item();
      expect(DownloadProgressSample.fromNative({}).applyTo(item), same(item));
    },
  );

  test('polls active/finalizing transfers and throttles idle queued work', () {
    final tracker = DownloadProgressTracker();
    final queued = const DownloadQueueState().copyWith(
      items: [_item(status: DownloadStatus.queued)],
    );
    expect(List.generate(6, (_) => tracker.shouldPoll(queued)), [
      false,
      false,
      true,
      false,
      false,
      true,
    ]);
    expect(tracker.shouldPoll(queued.copyWith(isPaused: true)), isFalse);
    expect(tracker.shouldPoll(const DownloadQueueState()), isFalse);
    expect(tracker.shouldPoll(queued), isFalse);
    for (final status in [
      DownloadStatus.downloading,
      DownloadStatus.finalizing,
    ]) {
      expect(
        tracker.shouldPoll(queued.copyWith(items: [_item(status: status)])),
        isTrue,
      );
    }
    expect(tracker.shouldPoll(queued), isFalse);
  });

  test(
    'deduplicates notifications and keeps service heartbeats/content changes',
    () {
      final tracker = DownloadProgressTracker();
      final start = DateTime.utc(2026);
      bool service(
        int percent,
        int seconds, {
        String status = 'downloading',
        int count = 2,
      }) => tracker.shouldUpdateService(
        trackName: 'Song',
        artistName: 'Artist',
        progress: percent,
        total: 100,
        queueCount: count,
        status: status,
        now: start.add(Duration(seconds: seconds)),
      );
      expect(service(20, 0), isTrue);
      expect(service(21, 1), isFalse);
      expect(service(22, 2), isTrue);
      expect(service(22, 6), isFalse);
      expect(service(22, 7), isTrue);
      expect(service(22, 7, count: 1), isTrue);
      expect(service(22, 7, status: 'finalizing'), isTrue);
      expect(service(99, 8), isTrue);
      expect(service(100, 8), isTrue);
      bool notify(int progress) => tracker.shouldNotify(
        trackName: 'Song',
        artistName: 'Artist',
        progress: progress,
        total: 1000,
        queueCount: 2,
      );
      expect(notify(200), isTrue);
      expect(notify(201), isFalse);
      expect(notify(210), isTrue);
      expect(tracker.shouldNotifyFinalizing('Song', 'Artist'), isTrue);
      expect(tracker.shouldNotifyFinalizing('Song', 'Artist'), isFalse);
      expect(tracker.shouldNotifyFinalizing(null, ''), isFalse);
      expect(tracker.shouldNotifyFinalizing('Song', 'Artist'), isTrue);
      tracker.reset();
      expect(notify(210), isTrue);
      expect(service(100, 8), isTrue);
    },
  );

  test('logs per-item progress buckets and removes finished items', () {
    final tracker = DownloadProgressTracker();
    expect(tracker.shouldLog('item', 0, preparing: true), isTrue);
    expect(tracker.shouldLog('item', 0, preparing: true), isFalse);
    expect(tracker.shouldLog('item', .1), isTrue);
    expect(tracker.shouldLog('item', .19), isFalse);
    expect(tracker.shouldLog('item', 1), isTrue);
    tracker.pruneLogs(
      DownloadQueueLookup.fromItems([_item(status: DownloadStatus.completed)]),
    );
    expect(tracker.shouldLog('item', .1), isTrue);
  });
}
