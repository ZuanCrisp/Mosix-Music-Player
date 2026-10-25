import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_state.dart';
import 'package:mornye/utils/chunked_list.dart';

import '../test/support/queue_removal_benchmark.dart';

({DownloadItem? downloading, DownloadItem? finalizing}) _scan(
  DownloadQueueState state,
) {
  DownloadItem? downloading;
  DownloadItem? finalizing;
  final downloadingCount = state.lookup.activeDownloadsCount;
  final hasFinalizing = state.lookup.finalizingCount > 0;
  if (downloadingCount > 0 || hasFinalizing) {
    for (final item in state.items) {
      if (downloading == null && item.status == DownloadStatus.downloading) {
        downloading = item;
      }
      if (finalizing == null && item.status == DownloadStatus.finalizing) {
        finalizing = item;
      }
      if ((downloadingCount == 0 || downloading != null) &&
          (!hasFinalizing || finalizing != null)) {
        break;
      }
    }
  }
  return (downloading: downloading, finalizing: finalizing);
}

int _measure(
  DownloadQueueState initial,
  int activeIndex,
  bool finalizing, {
  required bool indexed,
  required int iterations,
}) {
  var state = initial;
  final expectedDownload = initial.items[activeIndex].id;
  final expectedFinalizing = finalizing
      ? initial.items[activeIndex + 1].id
      : null;
  final watch = Stopwatch()..start();
  for (var tick = 0; tick < iterations; tick++) {
    final previous = state.items;
    final next = ChunkedList<DownloadItem>.from(previous).updated({
      activeIndex: previous[activeIndex].copyWith(
        progress: (tick + 1) / (iterations + 1),
      ),
    });
    state = state.copyWith(
      items: next,
      lookup: state.lookup.updatedForIndices(
        previousItems: previous,
        nextItems: next,
        changedIndices: [activeIndex],
      ),
    );
    final selected = indexed
        ? (
            downloading: state.lookup.firstDownloading,
            finalizing: state.lookup.firstFinalizing,
          )
        : _scan(state);
    if (selected.downloading?.id != expectedDownload ||
        selected.finalizing?.id != expectedFinalizing ||
        !identical(selected.downloading, next[activeIndex])) {
      fail('Notification selected a different track or stale progress');
    }
  }
  watch.stop();
  expect(initial.items[activeIndex].progress, 0);
  return watch.elapsedMicroseconds;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final cases = <Map<String, dynamic>>[];
  // Sub-millisecond front samples were noisy during plugin/driver startup.
  // Let startup settle, and use longer front samples instead of filtering them.
  setUpAll(() => Future<void>.delayed(const Duration(seconds: 2)));
  tearDownAll(() {
    binding.reportData ??= {};
    binding.reportData!['queue_progress_selection'] = {
      'platform': Platform.operatingSystem,
      'completed_cases': cases.length,
      'note':
          'Five alternating pairs after warming both methods: 10000 sparse progress snapshots for front candidates, 500 for tail candidates. Both use the current index update; legacy selection scans items, current selection reads cached first positions. Setup excluded. CPU only, not rendered frames or download speed. iOS debug correctness only.',
      'cases': cases,
    };
  });
  for (final count in [1000, 10000]) {
    for (final atEnd in [false, true]) {
      for (final finalizing in [false, true]) {
        testWidgets(
          'select active items in $count, tail=$atEnd, finalizing=$finalizing',
          (tester) async {
            final fixture = await queueRemovalFixture(count);
            final activeIndex = atEnd ? count - 3 : 0;
            final iterations = atEnd ? 500 : 10000;
            final initial = fixture.copyWith(
              items: [
                for (var i = 0; i < count; i++)
                  fixture.items[i].copyWith(
                    status: i == activeIndex
                        ? DownloadStatus.downloading
                        : finalizing && i == activeIndex + 1
                        ? DownloadStatus.finalizing
                        : DownloadStatus.completed,
                  ),
              ],
            );
            _measure(
              initial,
              activeIndex,
              finalizing,
              indexed: false,
              iterations: iterations,
            );
            _measure(
              initial,
              activeIndex,
              finalizing,
              indexed: true,
              iterations: iterations,
            );
            final samples = <String, List<int>>{'scan': [], 'indexed': []};
            for (var pair = 0; pair < 5; pair++) {
              for (final indexed
                  in pair.isEven ? [false, true] : [true, false]) {
                samples[indexed ? 'indexed' : 'scan']!.add(
                  _measure(
                    initial,
                    activeIndex,
                    finalizing,
                    indexed: indexed,
                    iterations: iterations,
                  ),
                );
              }
            }
            cases.add({
              'queue_size': count,
              'active_at_tail': atEnd,
              'with_finalizing': finalizing,
              'updates_per_sample': iterations,
              'samples_us': samples,
            });
          },
        );
      }
    }
  }
}
