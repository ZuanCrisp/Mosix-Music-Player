import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_storage_service.dart';

Uint8List _track(int index) {
  final comments = BytesBuilder();
  void little(int number) => comments.add(
    (ByteData(4)..setUint32(0, number, Endian.little)).buffer.asUint8List(),
  );
  little(0);
  final tags = [
    'TITLE=Track $index',
    'ARTIST=Network artist',
    'ALBUM=Network album',
    'LYRICS=[00:01.00]Hello\n[00:02.00]World',
    'REPLAYGAIN_TRACK_GAIN=-5.0 dB',
  ];
  little(tags.length);
  for (final tag in tags) {
    final bytes = utf8.encode(tag);
    little(bytes.length);
    comments.add(bytes);
  }
  final picture = BytesBuilder();
  void big(int number) =>
      picture.add((ByteData(4)..setUint32(0, number)).buffer.asUint8List());
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3WQAAAAASUVORK5CYII=',
  );
  big(3);
  big(9);
  picture.add(ascii.encode('image/png'));
  big(0);
  big(1);
  big(1);
  big(24);
  big(0);
  big(png.length);
  picture.add(png);
  final header = BytesBuilder()..add(ascii.encode('fLaC'));
  void block(int type, Uint8List data) {
    header.add([
      type,
      (data.length >> 16) & 255,
      (data.length >> 8) & 255,
      data.length & 255,
    ]);
    header.add(data);
  }

  block(0, Uint8List(34));
  block(4, comments.takeBytes());
  block(0x86, picture.takeBytes());
  header.add([0xff, 0xf8]);
  final file = Uint8List(4 * 1024 * 1024);
  final metadata = header.takeBytes();
  file.setRange(0, metadata.length, metadata);
  return file;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  testWidgets(
    'native WebDAV scan overlaps latency without changing metadata or artwork',
    (tester) async {
      const count = 48;
      final files = List.generate(count, _track);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final temporary = await (await getTemporaryDirectory()).createTemp(
        'network-speed-',
      );
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      final connection = NetworkConnection(
        id: 'scan-speed',
        name: 'Latency fixture',
        protocol: NetworkProtocol.webdav,
        address: 'http://127.0.0.1:${server.port}/music/',
      );
      await storage.save(connection);
      var requests = 0;
      var transferred = 0;
      var active = 0;
      var maximum = 0;
      final ports = <int>{};
      server.listen((request) async {
        try {
          await request.drain<void>();
          ports.add(request.connectionInfo!.remotePort);
          if (request.method == 'PROPFIND') {
            expect(request.headers.value('depth'), '1');
            request.response.statusCode = 207;
            request.response.write('<d:multistatus xmlns:d="DAV:">');
            for (var index = 0; index < count; index++) {
              final name = index.toString().padLeft(3, '0');
              request.response.write(
                '<d:response><d:href>/music/$name.flac</d:href><d:propstat>'
                '<d:prop><d:getcontentlength>${files[index].length}</d:getcontentlength></d:prop>'
                '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
              );
            }
            request.response.write('</d:multistatus>');
          } else {
            final index = int.parse(
              request.uri.pathSegments.last.split('.').first,
            );
            final file = files[index];
            final range = networkByteRange(
              request.headers.value('range'),
              file.length,
            );
            active++;
            requests++;
            if (active > maximum) maximum = active;
            await Future<void>.delayed(const Duration(milliseconds: 40));
            request.response.statusCode = 206;
            request.response.headers.set(
              'Content-Range',
              'bytes ${range.start}-${range.end}/${file.length}',
            );
            request.response.contentLength = range.end - range.start + 1;
            if (request.method != 'HEAD') {
              transferred += request.response.contentLength;
              request.response.add(
                Uint8List.sublistView(file, range.start, range.end + 1),
              );
            }
            active--;
          }
          await request.response.close();
        } catch (error) {
          request.response.statusCode = 500;
          await request.response.close();
          rethrow;
        }
      });
      try {
        final samples = <Map<String, Object>>[];
        List<Map<String, dynamic>>? baseline;
        // Warm native bindings and parsers before comparing measured runs.
        for (final concurrency in [3, 1, 3, 1, 3]) {
          requests = 0;
          transferred = 0;
          maximum = 0;
          ports.clear();
          final progress = <int>[];
          final watch = Stopwatch()..start();
          final result =
              await NetworkLibraryScanner(
                storage: storage,
                metadataConcurrency: concurrency,
                supportDirectory: () async => temporary,
                temporaryDirectory: () async => temporary,
              ).scan(
                NetworkStorageService.source(connection.id, ''),
                checkpoint: () async {},
                onProgress: (processed, _, _) => progress.add(processed),
              );
          watch.stop();
          expect(result.errorCount, 0);
          final rows = await result.rows().toList();
          expect(rows, hasLength(count));
          expect(progress, List.generate(count, (index) => index + 1));
          for (var index = 0; index < count; index++) {
            final row = rows[index];
            expect(row['trackName'], 'Track $index');
            expect(row['artistName'], 'Network artist');
            expect(row['albumName'], 'Network album');
            expect(row['hasLyrics'], true);
            expect(row['replaygain_track_gain'], isNotNull);
            final cover = File(row['coverPath'] as String);
            expect(await cover.exists(), true);
            expect(await cover.length(), 68);
            row.remove('scannedAt');
          }
          if (baseline != null) expect(rows, baseline);
          baseline = rows;
          expect(transferred, lessThan(count * 1024 * 1024));
          expect(maximum, concurrency);
          expect(active, 0);
          expect(ports.length, lessThanOrEqualTo(3));
          samples.add({
            'concurrency': concurrency,
            'milliseconds': watch.elapsedMilliseconds,
            'rows': rows.length,
            'errors': result.errorCount,
            'range_requests': requests,
            'bytes_transferred': transferred,
            'maximum_active_reads': maximum,
            'remote_connections': ports.length,
          });
        }
        binding.reportData ??= {};
        binding.reportData!['network_scan_speed'] = {
          'completed_cases': 1,
          'samples': samples,
          'note':
              'Native Rust metadata reader over local WebDAV; 40 ms simulated request latency. First sample is warmup. No live NAS comparison.',
        };
      } finally {
        await storage.dispose();
        await server.close(force: true);
        await temporary.delete(recursive: true);
      }
    },
  );
}
