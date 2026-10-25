import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  var completed = 0;
  tearDownAll(() {
    binding.reportData ??= {};
    binding.reportData!['webdav_encoding'] = {
      'completed_cases': completed,
      'platform': Platform.operatingSystem,
      'note': 'Real native parser and local WebDAV transport; no live NAS.',
    };
  });

  String response(String href, {bool directory = false}) =>
      '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
      '${directory ? '<d:resourcetype><d:collection/></d:resourcetype>' : '<d:getcontentlength>123</d:getcontentlength>'}'
      '</d:prop><d:status>HTTP/1.1 200 OK</d:status>'
      '</d:propstat></d:response>';
  String listing(String body) =>
      '<d:multistatus xmlns:d="DAV:">$body</d:multistatus>';

  testWidgets('native WebDAV accepts equivalent parent URI encodings', (
    tester,
  ) async {
    // Direct native calls must fail if the platform artifact is stale or the
    // channel is unavailable. A Dart compatibility fallback cannot hide it.
    for (final encodedParent in [false, true]) {
      final baseParent = encodedParent
          ? 'Rock%20%26%20Roll'
          : 'Rock%20&%20Roll';
      final hrefParent = encodedParent
          ? 'Rock%20&amp;%20Roll'
          : 'Rock%20%26%20Roll';
      final result = await PlatformBridge.runNativeDataJob(
        {
          'operation': 'parse_network_listing',
          'protocol': 'webdav',
          'base_url': 'https://nas.test/dav/$baseParent/',
          'path': 'Rock & Roll/',
        },
        bytes: Uint8List.fromList(
          utf8.encode(
            listing(
              response('/dav/$hrefParent/A%20%26%20B.flac') +
                  response('/dav/$hrefParent/Literal%252F.mp3') +
                  response('/dav/$hrefParent/nested%2Fsong.ogg') +
                  response('/dav/Rock%20%26%20Roller/other.flac'),
            ),
          ),
        ),
      );
      expect(result['entries'], [
        {
          'path': 'Rock & Roll/A & B.flac',
          'name': 'A & B.flac',
          'directory': false,
          'size': 123,
        },
        {
          'path': 'Rock & Roll/Literal%2F.mp3',
          'name': 'Literal%2F.mp3',
          'directory': false,
          'size': 123,
        },
      ]);
    }
    completed++;
  });

  testWidgets('WebDAV transport lists an encoded album through native worker', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((request) async {
      expect(request.method, 'PROPFIND');
      expect(request.headers.value('depth'), '1');
      await request.drain<void>();
      requests.add(request.uri.pathSegments.join('/'));
      request.response.statusCode = HttpStatus.multiStatus;
      request.response.write(
        listing(
          request.uri.pathSegments.length == 2
              ? response('/dav/Artist%20%26%20Band/', directory: true)
              : response('/dav/Artist%20%26%20Band/A%20%26%20B.flac') +
                    response('/dav/Artist%20%26%20Band/Album%20%2B%20Mix.mp3') +
                    response('/dav/Artist%20%26%20Band/%E9%9F%B3%E6%A5%BD.ogg'),
        ),
      );
      await request.response.close();
    });
    final storage = NetworkStorageService();
    addTearDown(storage.dispose);
    final connection = NetworkConnection(
      id: 'dav-encoding',
      name: 'NAS fixture',
      protocol: NetworkProtocol.webdav,
      address: 'http://127.0.0.1:${server.port}/dav/',
    );
    final albums = await storage.list(connection);
    expect(albums.single.path, 'Artist & Band/');
    final tracks = await storage.list(connection, albums.single.path);
    expect(tracks.map((entry) => entry.name), [
      'A & B.flac',
      'Album + Mix.mp3',
      '音楽.ogg',
    ]);
    expect(tracks.every((entry) => entry.audio), isTrue);
    expect(requests, ['dav/', 'dav/Artist & Band/']);
    completed++;
  });
}
