import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/audio_analysis_cache.dart';

void main() {
  test('eviction removes whole bundles and retains active analyses', () async {
    final directory = await Directory.systemTemp.createTemp('analysis-budget-');
    addTearDown(() => directory.delete(recursive: true));
    Future<File> write(String name, int size, int age) async {
      final file = await File(
        '${directory.path}/$name',
      ).writeAsBytes(List.filled(size, 0));
      await file.setLastModified(DateTime(2026, 1, age));
      return file;
    }

    final old = [
      await write('aa.json', 10, 1),
      await write('aa.png', 40, 1),
      await write('aa_ch0.png', 40, 1),
    ];
    final active = await write('bb.png', 80, 2);
    final recent = await write('cc.png', 80, 3);
    final unrelated = await write('unrelated.txt', 500, 1);
    final cache = AudioAnalysisCache();
    final release = cache.retain('bb');
    await cache.trim(directory, maxBytes: 180, targetBytes: 160);
    for (final file in old) {
      expect(await file.exists(), false);
    }
    expect(await active.exists(), true);
    expect(await recent.exists(), true);
    expect(await unrelated.exists(), true);

    release();
    release(); // Releasing a cancelled request twice cannot drop another lease.
    await cache.trim(directory, maxBytes: 100, targetBytes: 80);
    expect(await active.exists(), false);
    expect(await recent.exists(), true);
  });

  test(
    'overlapping leases keep a source protected until both finish',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'analysis-active-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/aa.png').writeAsBytes([1, 2]);
      final cache = AudioAnalysisCache();
      final first = cache.retain('aa');
      final second = cache.retain('aa');
      first();
      await cache.trim(directory, maxBytes: 1, targetBytes: 0);
      expect(await file.exists(), true);
      second();
      await cache.trim(directory, maxBytes: 1, targetBytes: 0);
      expect(await file.exists(), false);
    },
  );
}
