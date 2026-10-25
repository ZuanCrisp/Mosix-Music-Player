import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_storage_service.dart';

class _Storage extends NetworkStorageService {
  _Storage(this.protocol);
  final NetworkProtocol protocol;
  @override
  Future<NetworkConnection> connection(String id) async => NetworkConnection(
    id: id,
    name: 'NAS fixture',
    protocol: protocol,
    address: protocol == NetworkProtocol.smb
        ? 'smb://nas.test/music/'
        : 'https://nas.test/music/',
  );
  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection c, [
    String path = '',
  ]) async =>
      List.generate(48, (index) => NetworkEntry('$index.flac', '$index.flac'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final protocol in [NetworkProtocol.webdav, NetworkProtocol.smb]) {
    test('scan latency and results for ${protocol.name}', () async {
      final directory = await Directory.systemTemp.createTemp('scan-latency-');
      addTearDown(() => directory.delete(recursive: true));
      final storage = _Storage(protocol);
      addTearDown(storage.dispose);
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      var active = 0;
      var maximum = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'runNativeDataJob');
        final args = call.arguments as Map;
        final request = jsonDecode(args['request_json'] as String) as Map;
        expect(request['operation'], 'network_metadata');
        active++;
        if (active > maximum) maximum = active;
        await Future<void>.delayed(const Duration(milliseconds: 15));
        active--;
        return jsonEncode({
          'metadata': {
            'title': request['display_name'],
            'artist': 'Artist',
            'album': 'Album',
          },
          'cacheable': true,
        });
      });
      final watch = Stopwatch()..start();
      final scan =
          await NetworkLibraryScanner(
            storage: storage,
            supportDirectory: () async => directory,
            temporaryDirectory: () async => directory,
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (_, _, _) {},
          );
      watch.stop();
      final rows = await scan.rows().toList();
      expect(scan.errorCount, 0);
      expect(rows, hasLength(48));
      expect(
        rows.map((row) => row['trackName']),
        List.generate(48, (i) => '$i.flac'),
      );
      expect(rows.map((row) => row['id']).toSet(), hasLength(48));
      expect(active, 0);
      // This is a controlled channel-latency measurement, not a NAS benchmark.
      stdout.writeln(
        jsonEncode({
          'protocol': protocol.name,
          'milliseconds': watch.elapsedMilliseconds,
          'maximum_active_reads': maximum,
          'rows': rows.length,
        }),
      );
    });
  }
}
