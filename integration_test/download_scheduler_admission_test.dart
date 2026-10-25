import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/services/download_scheduler.dart';

import '../test/support/download_scheduler_baseline.dart';
import '../test/support/queue_removal_benchmark.dart';

Future<Map<String, int>> _measure(
  List<DownloadItem> items,
  int slots, {
  required bool legacy,
}) async {
  var checks = 0;
  final watch = Stopwatch();
  final expected = items
      .where((item) => item.status == DownloadStatus.queued)
      .map((item) => item.id)
      .toList(growable: false);
  for (var wave = 0; wave < 100; wave++) {
    var paused = false;
    final work = <Completer<void>>[];
    final started = <String>[];
    final create = legacy
        ? LegacyDownloadScheduler<DownloadItem>.new
        : DownloadScheduler<DownloadItem>.new;
    final scheduler = create(
      queuedItems: () => items.where((item) {
        checks++;
        return item.status == DownloadStatus.queued;
      }),
      idOf: (item) => item.id,
      isPaused: () => paused,
      concurrency: () => slots,
      start: (item) {
        started.add(item.id);
        final pending = Completer<void>();
        work.add(pending);
        return pending.future;
      },
    );
    watch.start();
    final run = scheduler.run();
    watch.stop();
    expect(started, expected);
    expect(work, hasLength(slots));
    // Drain outside the admission timer without asking the finished fixture
    // queue for another batch. The production scheduler owns actual futures.
    paused = true;
    for (final pending in work) {
      pending.complete();
    }
    await run;
  }
  return {
    'admission_us': watch.elapsedMicroseconds,
    'item_checks': checks,
    'admissions': 100,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final cases = <Map<String, dynamic>>[];
  setUpAll(() => Future<void>.delayed(const Duration(seconds: 2)));
  tearDownAll(() {
    binding.reportData ??= {};
    binding.reportData!['scheduler_admission'] = {
      'platform': Platform.operatingSystem,
      'paired_legacy_current': true,
      'completed_cases': cases.length,
      'note':
          'Original and current DownloadScheduler with a lazy status filter over immutable queue items. Five alternating pairs after warming both: 100 admissions including synchronous start callbacks; queue creation and asynchronous work/drain excluded. Item checks include predicate instrumentation. CPU only, not network speed, persistence or rendered frames. iOS debug correctness only.',
      'cases': cases,
    };
  });
  for (final count in [1000, 10000]) {
    for (final slots in [1, 3]) {
      for (final atEnd in [false, true]) {
        testWidgets('admit $slots from $count, queued at tail=$atEnd', (
          tester,
        ) async {
          final fixture = await queueRemovalFixture(count);
          final items = fixture
              .copyWith(
                items: [
                  for (var index = 0; index < count; index++)
                    fixture.items[index].copyWith(
                      status: (atEnd ? index >= count - slots : index < slots)
                          ? DownloadStatus.queued
                          : DownloadStatus.completed,
                    ),
                ],
              )
              .items;
          await _measure(items, slots, legacy: true);
          await _measure(items, slots, legacy: false);
          final samples = <String, List<Map<String, int>>>{
            'legacy': [],
            'current': [],
          };
          for (var pair = 0; pair < 5; pair++) {
            for (final legacy in pair.isEven ? [true, false] : [false, true]) {
              final sample = await _measure(items, slots, legacy: legacy);
              expect(
                sample['item_checks'],
                100 * (legacy || atEnd ? count : slots),
              );
              samples[legacy ? 'legacy' : 'current']!.add(sample);
            }
          }
          cases.add({
            'queue_size': count,
            'slots': slots,
            'queued_at_tail': atEnd,
            'samples': samples,
          });
        });
      }
    }
  }
}
