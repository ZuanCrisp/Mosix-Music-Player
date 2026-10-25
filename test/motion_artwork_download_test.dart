import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/motion_artwork_download.dart';

void main() {
  late HttpServer server;
  late Directory root;
  late Uri base;
  late Map<String, String> playlists;
  late List<String> requests;
  late List<int> video;
  late int status;
  late int? declaredLength;
  late String media;
  const validMedia = '''
#EXTM3U
#EXT-X-MAP:URI="cover.mp4",BYTERANGE="4@0"
#EXTINF:1,
#EXT-X-BYTERANGE:4@4
cover.mp4
#EXTINF:1,
#EXT-X-BYTERANGE:4
cover.mp4
#EXT-X-ENDLIST
''';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('motion-download-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    requests = [];
    video = List.generate(12, (index) => index);
    status = HttpStatus.ok;
    declaredLength = null;
    media = validMedia;
    playlists = {
      '/master.m3u8': '''
#EXTM3U
#EXT-X-I-FRAME-STREAM-INF:CODECS="avc1.64001f",URI="preview.m3u8"
#EXT-X-STREAM-INF:CODECS="hvc1.2.4.L120",RESOLUTION=664x886
hevc.m3u8
#EXT-X-STREAM-INF:CODECS="avc1.64001f",RESOLUTION=664x886
video/media.m3u8
''',
    };
    server.listen((request) async {
      requests.add(request.uri.path);
      expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
      if (request.uri.path == '/redirect.m3u8') {
        await request.response.redirect(base.resolve('video/media.m3u8'));
        return;
      }
      final text = request.uri.path == '/video/media.m3u8'
          ? media
          : playlists[request.uri.path];
      if (text != null) {
        request.response.write(text);
      } else if (request.uri.path == '/video/cover.mp4') {
        request.response.statusCode = status;
        if (declaredLength != null) {
          request.response.contentLength = declaredLength!;
          await request.response.flush();
          final socket = await request.response.detachSocket();
          socket.destroy();
          return;
        }
        request.response.add(video);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  Future<File?> download([String path = 'master.m3u8']) =>
      downloadMotionArtworkSource(
        base.resolve(path).toString(),
        '${root.path}/source.mp4',
      );

  test(
    'fetches the complete H.264 resource once without range requests',
    () async {
      final file = await download();
      expect(await file!.readAsBytes(), video);
      expect(requests, [
        '/master.m3u8',
        '/video/media.m3u8',
        '/video/cover.mp4',
      ]);
    },
  );

  test('resolves media URLs relative to the redirected playlist', () async {
    final file = await download('redirect.m3u8');
    expect(await file!.readAsBytes(), video);
    expect(requests.last, '/video/cover.mp4');
  });

  test('leaves other sources to the regular remuxer', () async {
    expect(await download('cover.mp4'), isNull);
    expect(requests, isEmpty);
    expect(root.listSync(), isEmpty);
  });

  for (final unsupported in {
    'separate segments': validMedia.replaceFirst(
      '#EXT-X-BYTERANGE:4\ncover.mp4',
      '#EXT-X-BYTERANGE:4\nother.mp4',
    ),
    'missing bytes': validMedia.replaceFirst('4@4', '4@5'),
    'nonzero initial offset': validMedia.replaceFirst('4@0', '4@1'),
    'encrypted segments': validMedia.replaceFirst(
      '#EXTM3U',
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"',
    ),
    'live playlist': validMedia.replaceFirst('#EXT-X-ENDLIST', ''),
    'discontinuity': validMedia.replaceFirst(
      '#EXTINF:1,',
      '#EXT-X-DISCONTINUITY\n#EXTINF:1,',
    ),
    'non-HTTP video': validMedia.replaceAll('cover.mp4', 'file:///cover.mp4'),
  }.entries) {
    test('does not flatten ${unsupported.key}', () async {
      media = unsupported.value;
      expect(await download('video/media.m3u8'), isNull);
      expect(requests, ['/video/media.m3u8']);
      expect(root.listSync(), isEmpty);
    });
  }

  test('rejects a partial HTTP response', () async {
    status = HttpStatus.partialContent;
    await expectLater(download(), throwsA(isA<HttpException>()));
    expect(root.listSync(), isEmpty);
  });

  test('rejects missing segment bytes and removes the partial file', () async {
    video = [1, 2, 3];
    await expectLater(download(), throwsFormatException);
    expect(root.listSync(), isEmpty);
  });

  test('bounds video size before accepting a large response', () async {
    declaredLength = 25 << 20;
    await expectLater(download(), throwsFormatException);
    expect(root.listSync(), isEmpty);
  });
}
