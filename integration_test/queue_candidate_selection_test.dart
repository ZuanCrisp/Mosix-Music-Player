import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_state.dart';
import 'package:mornye/services/download_scheduler.dart';
import 'package:mornye/utils/chunked_list.dart';

import '../test/support/queue_removal_benchmark.dart';

Future<int> _measure(
  DownloadQueueState initial, {
  required bool indexed,
}) async {
  final expected = initial.items
      .where((item) => item.status == DownloadStatus.queued)
      .map((item) => item.id)
      .toList();
  final watch = Stopwatch();
  for (var wave = 0; wave < 100; wave++) {
    var state = initial;
    var paused = false;
    final work = <Completer<void>>[];
    final started = <String>[];
    final scheduler = DownloadScheduler<DownloadItem>(
      queuedItems: () => indexed
          ? state.queuedItems
          : state.items.where((item) => item.status == DownloadStatus.queued),
      idOf: (item) => item.id,
      isPaused: () => paused,
      concurrency: () => 3,
      start: (item) {
        started.add(item.id);
        final previous = state.items;
        final index = state.lookup.indexByItemId[item.id]!;
        final next = ChunkedList<DownloadItem>.from(
          previous,
        ).updated({index: item.copyWith(status: DownloadStatus.downloading)});
        state = state.copyWith(
          items: next,
          lookup: state.lookup.updatedForIndices(
            previousItems: previous,
            nextItems: next,
            changedIndices: [index],
          ),
        );
        final pending = Completer<void>();
        work.add(pending);
        return pending.future;
      },
    );
    watch.start();
    final run = scheduler.run();
    watch.stop();
    expect(started, expected);
    expect(work, hasLength(3));
    expect(state.activeDownloadsCount, 3);
    expect(state.queuedItems, isEmpty);
    paused = true;
    for (final pending in work) {
      pending.complete();
    }
    await run;
  }
  return watch.elapsedMicroseconds;
}

Map<String, int> _indexCosts(DownloadQueueState initial) {
  final build = Stopwatch()..start();
  var state = initial;
  for (var i = 0; i < 20; i++) {
    state = state.copyWith(items: state.items);
  }
  build.stop();
  final activeIndices = [
    for (var i = 0; i < state.items.length; i++)
      if (state.items[i].status == DownloadStatus.queued) i,
  ];
  final active = ChunkedList<DownloadItem>.from(state.items).updated({
    for (final index in activeIndices)
      index: state.items[index].copyWith(status: DownloadStatus.downloading),
  });
  state = state.copyWith(
    items: active,
    lookup: state.lookup.updatedForIndices(
      previousItems: state.items,
      nextItems: active,
      changedIndices: activeIndices,
    ),
  );
  final progress = Stopwatch()..start();
  for (var tick = 0; tick < 5000; tick++) {
    final index = activeIndices[tick % activeIndices.length];
    final next = ChunkedList<DownloadItem>.from(
      state.items,
    ).updated({index: state.items[index].copyWith(progress: tick / 5000)});
    state = state.copyWith(
      items: next,
      lookup: state.lookup.updatedForIndices(
        previousItems: state.items,
        nextItems: next,
        changedIndices: [index],
      ),
    );
  }
  progress.stop();
  expect(state.items.length, initial.items.length);
  return {
    'build_20_us': build.elapsedMicroseconds,
    'progress_5000_us': progress.elapsedMicroseconds,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final cases = <Map<String, dynamic>>[];
  setUpAll(() => Future<void>.delayed(const Duration(seconds: 2)));
  tearDownAll(() {
    binding.reportData ??= {};
    binding.reportData!['queue_candidate_selection'] = {
      'platform': Platform.operatingSystem,
      'completed_cases': cases.length,
      'note':
          'Five alternating scan/indexed pairs after warmup: 100 actual scheduler admissions of three items including immutable status/index updates. Both variants maintain current indexes. Setup, async work/drain and rendering excluded. Separate full-index-build and progress-only costs compared to retained pre-index baseline. iOS debug correctness only.',
      'cases': cases,
    };
  });
  for (final count in [1000, 10000]) {
    for (final pattern in ['front', 'tail', 'spread']) {
      testWidgets('queued candidates $count/$pattern', (tester) async {
        final fixture = await queueRemovalFixture(count);
        final queued = switch (pattern) {
          'front' => {0, 1, 2},
          'tail' => {count - 3, count - 2, count - 1},
          _ => {0, count ~/ 2, count - 1},
        };
        final initial = fixture.copyWith(
          items: [
            for (var i = 0; i < count; i++)
              fixture.items[i].copyWith(
                status: queued.contains(i)
                    ? DownloadStatus.queued
                    : DownloadStatus.completed,
              ),
          ],
        );
        await _measure(initial, indexed: false);
        await _measure(initial, indexed: true);
        _indexCosts(initial);
        final samples = <String, List<int>>{'scan': [], 'indexed': []};
        final indexCosts = <Map<String, int>>[];
        for (var i = 0; i < 5; i++) {
          for (final indexed in i.isEven ? [false, true] : [true, false]) {
            samples[indexed ? 'indexed' : 'scan']!.add(
              await _measure(initial, indexed: indexed),
            );
          }
          indexCosts.add(_indexCosts(initial));
        }
        cases.add({
          'queue_size': count,
          'pattern': pattern,
          'admission_100_us': samples,
          'index_costs': indexCosts,
        });
      });
    }
  }
}
