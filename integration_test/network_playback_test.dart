import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/network_metadata_service.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native reader gets embedded tags and lyrics over network ranges',
    (tester) async {
      final comments = BytesBuilder();
      void little(int n) {
        comments.add(
          (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List(),
        );
      }

      little(0);
      final tags = [
        'TITLE=Network title',
        'ARTIST=Network artist',
        'ALBUM=Network album',
        'LYRICS=[00:01.00]Hello\n[00:02.00]World',
      ];
      little(tags.length);
      for (final tag in tags) {
        final bytes = utf8.encode(tag);
        little(bytes.length);
        comments.add(bytes);
      }
      final bytes = comments.takeBytes();
      final file = Uint8List(4 * 1024 * 1024);
      final header = [
        ...ascii.encode('fLaC'),
        0,
        0,
        0,
        34,
        ...List<int>.filled(34, 0),
        0x84,
        (bytes.length >> 16) & 255,
        (bytes.length >> 8) & 255,
        bytes.length & 255,
        ...bytes,
        0xff,
        0xf8,
      ];
      file.setRange(0, header.length, header);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var transferred = 0;
      server.listen((r) async {
        final range = networkByteRange(r.headers.value('range'), file.length);
        r.response.statusCode = 206;
        r.response.headers.set(
          'Content-Range',
          'bytes ${range.start}-${range.end}/${file.length}',
        );
        r.response.contentLength = range.end - range.start + 1;
        transferred += r.response.contentLength;
        r.response.add(file.sublist(range.start, range.end + 1));
        await r.response.close();
      });
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      try {
        await storage.save(
          NetworkConnection(
            id: 'tags',
            name: 'Tags',
            protocol: NetworkProtocol.http,
            address: 'http://127.0.0.1:${server.port}/song.flac',
          ),
        );
        final reader = NetworkMetadataService(
          storage: storage,
          reader: (url, name) async {
            final result = await PlatformBridge.readFileMetadata(
              url,
              displayName: name,
            );
            expect(
              result['error'],
              isNull,
              reason: result['error']?.toString(),
            );
            return result;
          },
        );
        final source = NetworkStorageService.source('tags', '');
        final metadata = await reader.read(source);
        expect(metadata['title'], 'Network title');
        expect(metadata['artist'], 'Network artist');
        expect(metadata['lyrics'], '[00:01.00]Hello\n[00:02.00]World');
        expect(transferred, lessThan(1024 * 1024));
        final before = transferred;
        await reader.read(source);
        expect(transferred, before);
      } finally {
        await storage.dispose();
        await server.close(force: true);
      }
    },
  );
  testWidgets('native player prepares and seeks through the network proxy', (
    tester,
  ) async {
    // Five seconds of silent PCM: tests decoding/transport without audible noise.
    final wav = Uint8List(44 + 8000 * 2 * 5);
    final data = ByteData.sublistView(wav);
    wav.setRange(0, 4, 'RIFF'.codeUnits);
    data.setUint32(4, wav.length - 8, Endian.little);
    wav.setRange(8, 16, 'WAVEfmt '.codeUnits);
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 8000, Endian.little);
    data.setUint32(28, 16000, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    wav.setRange(36, 40, 'data'.codeUnits);
    data.setUint32(40, wav.length - 44, Endian.little);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    server.listen((r) async {
      final range = r.headers.value('range');
      requests.add(range ?? 'full');
      final part = networkByteRange(range, wav.length);
      r.response.statusCode = range == null ? 200 : 206;
      r.response.headers.set('Content-Type', 'audio/wav');
      r.response.headers.set('Accept-Ranges', 'bytes');
      if (range != null) {
        r.response.headers.set(
          'Content-Range',
          'bytes ${part.start}-${part.end}/${wav.length}',
        );
      }
      r.response.contentLength = part.end - part.start + 1;
      if (r.method != 'HEAD') {
        r.response.add(wav.sublist(part.start, part.end + 1));
      }
      await r.response.close();
    });
    final service = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    final deck = AudioplayersPlaybackDeck(playerId: 'network-integration');
    try {
      await service.save(
        NetworkConnection(
          id: 'test',
          name: 'Test',
          protocol: NetworkProtocol.http,
          address: 'http://127.0.0.1:${server.port}/test.wav',
        ),
      );
      final url = await service.resolve(
        NetworkStorageService.source('test', ''),
      );
      await deck.setNetworkSource(url);
      expect(await deck.getDuration(), const Duration(seconds: 5));
      await deck.resume();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await deck.seek(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        (await deck.getCurrentPosition())!.inMilliseconds,
        greaterThanOrEqualTo(1900),
      );
      expect(requests, isNotEmpty);
      expect(deck.isDirect, false);
    } finally {
      await deck.dispose();
      await service.dispose();
      await server.close(force: true);
    }
  });
}
