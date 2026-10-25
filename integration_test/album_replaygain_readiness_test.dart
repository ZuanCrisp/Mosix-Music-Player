import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/album_replaygain_readiness.dart';

import '../test/support/album_replaygain_benchmark.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'Five alternating old/new pairs of the queue-readiness decision used by album ReplayGain retriggering. Fixtures have ten tracks per album and mixed blocked/ready/absent albums. Excludes audio scanning and tag I/O; not whole-download speed or FPS. iOS debug is correctness only.',
  };
  var completed = 0;
  tearDownAll(() {
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['album_replaygain'] = report;
  });
  for (final count in [1000, 10000]) {
    testWidgets('album readiness for $count queue items', (tester) async {
      final fixture = await albumReplayGainFixture(count);
      final expected = [
        for (var album = 0; album < count ~/ 10; album++)
          if (album % 3 == 2)
            legacyAlbumReplayGainKey(fixture.items[album * 10].track),
        'id:absent-multiple',
      ];
      final samples = <String, List<int>>{'per_album': [], 'one_scan': []};
      for (var sample = 0; sample < 5; sample++) {
        for (final bulk in sample.isEven ? [false, true] : [true, false]) {
          final watch = Stopwatch()..start();
          final ready = bulk
              ? readyReplayGainAlbums(fixture.items, fixture.entries)
              : legacyReadyReplayGainAlbums(fixture.items, fixture.entries);
          watch.stop();
          samples[bulk ? 'one_scan' : 'per_album']!.add(
            watch.elapsedMicroseconds,
          );
          expect(ready, expected);
        }
      }
      report['items_$count'] = samples;
      completed++;
    });
  }
  testWidgets('single-album checks preserve early, late and absent decisions', (
    tester,
  ) async {
    final fixture = await albumReplayGainFixture(10000);
    for (final (label, key, expected) in [
      ('first', legacyAlbumReplayGainKey(fixture.items.first.track), true),
      ('last', legacyAlbumReplayGainKey(fixture.items.last.track), true),
      ('absent', 'id:absent', false),
    ]) {
      final samples = <String, List<int>>{'full_list': [], 'short_circuit': []};
      for (var sample = 0; sample < 5; sample++) {
        for (final optimized in sample.isEven ? [false, true] : [true, false]) {
          final watch = Stopwatch()..start();
          final blocked = optimized
              ? albumReplayGainBlocked(fixture.items, key)
              : legacyAlbumReplayGainBlocked(fixture.items, key);
          watch.stop();
          samples[optimized ? 'short_circuit' : 'full_list']!.add(
            watch.elapsedMicroseconds,
          );
          expect(blocked, expected);
        }
      }
      report['single_$label'] = samples;
    }
    completed++;
  });
}
