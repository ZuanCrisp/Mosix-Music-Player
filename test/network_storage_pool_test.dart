import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'WebDAV listings and ranges reuse connections; saved credentials rotate the pool',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final ports = <int>{};
      final auth = <String?>[];
      var active = 0;
      var maximum = 0;
      var failListing = false;
      server.listen((request) async {
        ports.add(request.connectionInfo!.remotePort);
        auth.add(request.headers.value('authorization'));
        await request.drain<void>();
        if (request.method == 'PROPFIND') {
          request.response.statusCode = failListing ? 500 : 207;
          request.response.write(
            failListing
                ? 'offline'
                : '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/music/song.flac</d:href>'
                      '<d:propstat><d:prop><d:getcontentlength>4</d:getcontentlength></d:prop>'
                      '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>',
          );
        } else {
          expect(request.headers.value('range'), 'bytes=0-3');
          active++;
          if (active > maximum) maximum = active;
          await Future<void>.delayed(const Duration(milliseconds: 15));
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes 0-3/4');
          request.response.contentLength = 4;
          request.response.add([1, 2, 3, 4]);
          active--;
        }
        await request.response.close();
      });
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      addTearDown(storage.dispose);
      NetworkConnection connection(String password) => NetworkConnection(
        id: 'pool',
        name: 'Pool fixture',
        protocol: NetworkProtocol.webdav,
        address: 'http://127.0.0.1:${server.port}/music/',
        username: 'user',
        password: password,
      );
      final original = connection('first');
      await storage.save(original);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final proxy = await storage.resolve(
        NetworkStorageService.source('pool', 'song.flac'),
      );
      Future<void> read() async {
        final request = await client.getUrl(Uri.parse(proxy));
        request.headers.set('Range', 'bytes=0-3');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'), 'bytes 0-3/4');
        expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
          1,
          2,
          3,
          4,
        ]);
      }

      await storage.list(original);
      await read();
      await storage.list(original);
      expect(ports, hasLength(1));
      await Future.wait(List.generate(9, (_) => read()));
      expect(maximum, greaterThan(1));
      expect(maximum, lessThanOrEqualTo(6));
      expect(ports.length, lessThanOrEqualTo(6));
      expect(auth.toSet(), {
        'Basic ${base64Encode(utf8.encode('user:first'))}',
      });
      failListing = true;
      await expectLater(storage.list(original), throwsA(isA<HttpException>()));
      failListing = false;
      expect(await storage.list(original), hasLength(1));
      final previous = ports.toSet();
      final updated = connection('second');
      await storage.save(updated);
      await read();
      expect(auth.last, 'Basic ${base64Encode(utf8.encode('user:second'))}');
      expect(ports.difference(previous), hasLength(1));
    },
  );
}
