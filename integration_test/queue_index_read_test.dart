import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';

import '../test/support/queue_removal_benchmark.dart';

class _Queue extends DownloadQueueNotifier {
  _Queue(this._initial);
  final DownloadQueueState _initial;
  // Exercise the real sparse progress path without restore, downloads or I/O.
  @override
  DownloadQueueState build() => _initial;
}

Map<String, int> _measure(DownloadQueueState initial) {
  final container = ProviderContainer(
    overrides: [downloadQueueProvider.overrideWith(() => _Queue(initial))],
  );
  var queueChanges = 0;
  var membershipChanges = 0;
  final selected = <String, DownloadItem?>{};
  final subscriptions = <ProviderSubscription<Object?>>[];
  final activeIds = [for (var i = 0; i < 3; i++) initial.items[100 + i].id];
  final visibleIds = [for (var i = 0; i < 40; i++) initial.items[100 + i].id];
  final trackIds = [
    for (var i = 0; i < 50; i++)
      initial.items[(i * 131) % initial.items.length].track.id,
    for (var i = 0; i < 50; i++) 'absent-$i',
  ];
  for (final id in visibleIds) {
    subscriptions.add(
      container.listen<DownloadItem?>(
        downloadQueueLookupProvider.select((lookup) => lookup.byItemId[id]),
        (_, next) {
          queueChanges++;
          selected[id] = next;
        },
      ),
    );
  }
  for (final id in trackIds) {
    subscriptions.add(
      container.listen<bool>(
        downloadQueueLookupProvider.select(
          (lookup) => lookup.byTrackId.containsKey(id),
        ),
        (_, _) => membershipChanges++,
      ),
    );
  }
  try {
    final queue = container.read(downloadQueueProvider.notifier);
    final watch = Stopwatch()..start();
    for (var tick = 0; tick < 500; tick++) {
      queue.updateItemStatus(
        activeIds[tick % 3],
        DownloadStatus.downloading,
        progress: (tick % 101) / 101,
        bytesReceived: tick * 104857,
        bytesTotal: 100000000,
        speedMBps: 1.2,
      );
      // Flush derived provider invalidation each tick as live row reads do.
      container.read(downloadQueueLookupProvider);
    }
    watch.stop();
    expect(queueChanges, 500);
    expect(membershipChanges, 0);
    final finalState = container.read(downloadQueueProvider);
    for (final id in activeIds) {
      expect(selected[id], same(finalState.lookup.byItemId[id]));
    }
    expect(initial.items[100].progress, 0);
    return {
      'microseconds': watch.elapsedMicroseconds,
      'updates': 500,
      'queue_changes': queueChanges,
      'membership_changes': membershipChanges,
      'selectors': 140,
    };
  } finally {
    for (final subscription in subscriptions) {
      subscription.close();
    }
    container.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final cases = <Map<String, dynamic>>[];
  tearDownAll(() {
    binding.reportData ??= {};
    binding.reportData!['queue_index_read'] = {
      'platform': Platform.operatingSystem,
      'completed_cases': cases.length,
      'note':
          'Five alternating pairs of 500 real notifier sparse progress updates with 40 queue item and 100 track-membership Riverpod selectors, matching production row selectors. Compare 63 distributed removals with an equivalent fully rebuilt index. CPU/provider propagation only, no rendering or FPS. iOS debug correctness only.',
      'cases': cases,
    };
  });
  for (final count in [1000, 10000]) {
    testWidgets('selectors and sparse progress after removals from $count', (
      tester,
    ) async {
      var retained = await queueRemovalFixture(count);
      for (var i = 0; i < 63; i++) {
        final index = (i * 137) % retained.items.length;
        retained = retained.withoutItem(retained.items[index].id);
      }
      final rebuilt = retained.copyWith(items: retained.items);
      expect(retained.lookup.byItemId, rebuilt.lookup.byItemId);
      expect(retained.lookup.byTrackId, rebuilt.lookup.byTrackId);
      _measure(rebuilt);
      _measure(retained);
      final samples = <String, List<Map<String, int>>>{
        'rebuilt': [],
        'retained': [],
      };
      for (var pair = 0; pair < 5; pair++) {
        for (final useRetained in pair.isEven ? [false, true] : [true, false]) {
          samples[useRetained ? 'retained' : 'rebuilt']!.add(
            _measure(useRetained ? retained : rebuilt),
          );
        }
      }
      cases.add({'original_count': count, 'samples': samples});
    });
  }
}
