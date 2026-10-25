import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/platform_bridge.dart';

import '../test/support/library_collections_benchmark.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'Five alternating old/new pairs, queued IDs without active transfers. Measures synchronous dispatch, total native cancel/clear completion and caller heartbeat, not UI frames or download throughput. Reset setup and 50ms settle excluded. iOS debug is correctness only.',
  };
  late Directory root;
  late Directory output;
  var completed = 0;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('cancel-dispatch-');
    final sources = await Directory('${root.path}/extensions').create();
    final data = await Directory('${root.path}/data').create();
    output = await Directory('${root.path}/output').create();
    await PlatformBridge.initExtensionSystem(
      sources.path,
      data.path,
      masterKey: base64Encode(List<int>.filled(32, 1)),
      lyricsProviders: const [],
      lyricsFetchOptions: const {},
      allowedDirectories: [output.path],
    );
    expect(
      (await PlatformBridge.getBackendImplementations())['downloads'],
      'rust',
    );
    final provider = await Directory('${sources.path}/example.audio').create();
    await File('${provider.path}/manifest.json').writeAsString(
      jsonEncode({
        'name': 'example.audio',
        'version': '1',
        'description': 'Generic cancellation fixture',
        'type': ['download_provider'],
        'permissions': {'file': true},
        'skipMetadataEnrichment': true,
      }),
    );
    await File('${provider.path}/index.js').writeAsString('''
registerExtension({
  checkAvailability() { return { available: true, track_id: 'track' }; },
  download(trackId, quality, outputPath) {
    const name = outputPath.slice(outputPath.lastIndexOf('/') + 1);
    file.writeBytes(${jsonEncode('${output.path}/')} + name + '.started', 'c3RhcnRlZA==');
    if (name.startsWith('active.')) utils.sleep(30000);
    return { success: false, error: 'fixture finished' };
  }
});
''');
    await PlatformBridge.loadExtensionsFromDir(sources.path);
    await PlatformBridge.setExtensionEnabled('example.audio', true);
  });
  tearDownAll(() async {
    await PlatformBridge.cleanupExtensions();
    await root.delete(recursive: true);
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['cancel_dispatch'] = report;
  });

  Future<Map<String, dynamic>> download(String id, {String? title}) =>
      PlatformBridge.downloadByStrategy(
        payload: DownloadRequestPayload(
          itemId: id,
          service: 'example.audio',
          providerTrackId: id,
          trackName: title ?? id,
          artistName: 'Artist',
          albumName: 'Album',
          outputDir: output.path,
          filenameFormat: '{title}',
          outputExt: '.flac',
          embedMetadata: false,
          embedLyrics: false,
          useExtensions: true,
          useFallback: false,
        ),
      );

  testWidgets(
    'batch stops active work and queued attempts, preserving other IDs',
    (tester) async {
      final pending = download('active');
      final marker = File('${output.path}/active.flac.started');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await marker.exists() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await marker.exists(), true);
      expect(
        (await PlatformBridge.getAllDownloadProgress())['items'],
        contains('active'),
      );
      await PlatformBridge.cancelDownloads([
        'active',
        for (var i = 0; i < 600; i++) 'queued-$i',
        'active',
        '',
      ]);
      final cancelled = await pending.timeout(const Duration(seconds: 5));
      expect(cancelled['error'].toString().toLowerCase(), contains('cancel'));
      expect(
        (await PlatformBridge.getAllDownloadProgress())['items'],
        isNot(contains('active')),
      );
      for (final index in [0, 254, 255, 256, 599]) {
        expect(
          (await download('queued-$index'))['error'].toString().toLowerCase(),
          contains('cancel'),
        );
        expect(
          await File('${output.path}/queued-$index.flac.started').exists(),
          false,
        );
      }
      expect(
        (await download('unselected'))['error'],
        contains('fixture finished'),
      );
      expect(
        await File('${output.path}/unselected.flac.started').exists(),
        true,
      );
      expect(await PlatformBridge.resetDownloadCancels(['active']), {'active'});
      expect(
        (await download('active', title: 'retry'))['error'],
        contains('fixture finished'),
      );
      expect(await File('${output.path}/retry.flac.started').exists(), true);
      completed++;
    },
  );

  testWidgets('invalid native batch leaves IDs uncancelled', (tester) async {
    const channel = MethodChannel('com.zarz.mornye/backend');
    await expectLater(
      channel.invokeMethod<void>('cancelDownloads', {
        'item_ids': ['untouched', 1],
      }),
      throwsA(isA<PlatformException>()),
    );
    expect(
      (await download('untouched'))['error'],
      contains('fixture finished'),
    );
    completed++;
  });

  for (final count in [32, 1024, 2048]) {
    testWidgets('cancel and clear $count queued IDs', (tester) async {
      final ids = [for (var i = 0; i < count; i++) 'cancel-$count-$i'];
      final baseline = <Map<String, int>>[];
      final batched = <Map<String, int>>[];
      for (var sample = 0; sample < 5; sample++) {
        for (final batch in sample.isEven ? [false, true] : [true, false]) {
          expect(await PlatformBridge.resetDownloadCancels(ids), ids.toSet());
          await Future<void>.delayed(const Duration(milliseconds: 50));
          var dispatchUs = 0;
          final result = await measureCollectionOperation<void>(() {
            final watch = Stopwatch()..start();
            final Future<void> pending;
            if (batch) {
              pending = PlatformBridge.cancelDownloads(ids);
            } else {
              final calls = <Future<void>>[];
              for (final id in ids) {
                calls.add(PlatformBridge.cancelDownload(id));
                calls.add(PlatformBridge.clearItemProgress(id));
              }
              pending = Future.wait(calls);
            }
            dispatchUs = watch.elapsedMicroseconds;
            return pending;
          });
          (batch ? batched : baseline).add({
            ...result.timing,
            'dispatch_us': dispatchUs,
          });
        }
      }
      report['ids_$count'] = {
        'baseline': baseline,
        'batched': batched,
        'old_calls': count * 2,
        'new_calls': (count / 256).ceil(),
      };
      completed++;
    });
  }
}
