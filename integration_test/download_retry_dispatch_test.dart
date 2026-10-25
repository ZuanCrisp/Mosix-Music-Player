import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/platform_bridge.dart';

import '../test/support/library_collections_benchmark.dart';

Uint8List _wave() {
  final bytes = Uint8List(1644);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  data.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

Future<void> _seed(List<String> ids) async {
  // Keep setup bounded too; Java GC from thousands of simultaneous channel
  // calls must not dominate whichever measured operation happens next.
  for (var start = 0; start < ids.length; start += 64) {
    await Future.wait(
      ids.skip(start).take(64).map(PlatformBridge.cancelDownload),
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'Real native cancellation bridge, five alternating old/new pairs per size. Bounded cancellation seeding and a 50ms settle are excluded. Measures reset dispatch latency and caller heartbeat, not download speed or FPS. iOS debug is correctness only.',
  };
  var completed = 0;
  late Directory root;
  late Directory output;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('retry-dispatch-');
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
    final implementations = await PlatformBridge.getBackendImplementations();
    expect(implementations['downloads'], 'rust');
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
    file.writeBytes(outputPath, ${jsonEncode(base64Encode(_wave()))});
    return { success: true, file_path: outputPath, actual_extension: '.wav' };
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
    binding.reportData!['retry_dispatch'] = report;
  });

  Future<Map<String, dynamic>> download(String id) =>
      PlatformBridge.downloadByStrategy(
        payload: DownloadRequestPayload(
          itemId: id,
          service: 'example.audio',
          providerTrackId: id,
          trackName: id,
          artistName: 'Artist',
          albumName: 'Album',
          outputDir: output.path,
          filenameFormat: '{title}',
          outputExt: '.wav',
          embedMetadata: false,
          embedLyrics: false,
          useExtensions: true,
          useFallback: false,
        ),
      );

  testWidgets('reset selected idle flags across chunk boundaries', (
    tester,
  ) async {
    final ids = [for (var i = 0; i < 260; i++) 'selected-$i', '音楽'];
    await _seed([...ids, 'unselected']);
    expect(
      await PlatformBridge.resetDownloadCancels([...ids, ids.first, 'missing']),
      {...ids, 'missing'},
    );
    for (final id in [ids.first, ids[255], ids[256], ids[259], '音楽']) {
      final response = await download(id);
      expect(response['success'], true, reason: response.toString());
      expect(
        await File(response['file_path'] as String).readAsBytes(),
        _wave(),
      );
    }
    final cancelled = await download('unselected');
    expect(cancelled['success'], false);
    expect(cancelled['error'].toString().toLowerCase(), contains('cancel'));
    expect(await File('${output.path}/unselected.wav').exists(), false);
    completed++;
  });

  testWidgets('malformed native batch does not reset any flags', (
    tester,
  ) async {
    const channel = MethodChannel('com.zarz.mornye/backend');
    await PlatformBridge.cancelDownload('invalid-batch');
    await expectLater(
      channel.invokeMethod<void>('resetDownloadCancels', {
        'item_ids': ['invalid-batch', 1],
      }),
      throwsA(isA<PlatformException>()),
    );
    final cancelled = await download('invalid-batch');
    expect(cancelled['success'], false);
    expect(cancelled['error'].toString().toLowerCase(), contains('cancel'));
    completed++;
  });

  for (final count in [32, 1024, 2048]) {
    testWidgets('reset $count idle cancellation flags', (tester) async {
      final ids = [for (var i = 0; i < count; i++) 'retry-probe-$count-$i'];
      final baseline = <Map<String, int>>[];
      final batched = <Map<String, int>>[];
      for (var sample = 0; sample < 5; sample++) {
        for (final batch in sample.isEven ? [false, true] : [true, false]) {
          await _seed(ids);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final result = await measureCollectionOperation<Set<String>>(
            () async {
              if (batch) return PlatformBridge.resetDownloadCancels(ids);
              await Future.wait(ids.map(PlatformBridge.resetDownloadCancel));
              return ids.toSet();
            },
          );
          expect(result.value, ids.toSet());
          (batch ? batched : baseline).add(result.timing);
        }
      }
      report['ids_$count'] = {
        'baseline': baseline,
        'batched': batched,
        'baseline_calls': count,
        'batched_calls': (count / 256).ceil(),
      };
      completed++;
    });
  }
}
