import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/utils/file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const path = 'Album/日本語 100% + #1.flac';
  for (final (statStatus, deleteStatus, directory, deleted) in [
    (207, 204, false, true),
    (207, 200, false, true),
    (207, 404, false, true),
    (404, 204, false, true),
    (410, 204, false, true),
    (207, 403, false, false),
    (207, 500, false, false),
    (401, 204, false, false),
    (500, 204, false, false),
    (207, 202, false, false),
    (207, 207, false, false),
    (207, 307, false, false),
    (207, 204, true, false),
    (207, 204, null, false),
  ]) {
    test('WebDAV deletion: stat=$statStatus delete=$deleteStatus '
        'directory=$directory', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final methods = <String>[];
      server.listen((request) async {
        methods.add(request.method);
        expect(request.uri.pathSegments, [
          'music',
          'Album',
          path.split('/').last,
        ]);
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Basic ${base64Encode(utf8.encode('user:password'))}',
        );
        if (request.method == 'PROPFIND') {
          expect(request.headers.value('Depth'), '0');
          await request.drain<void>();
          request.response.statusCode = statStatus;
          if (statStatus == 207) {
            final href = Uri(path: '/music/$path').toString();
            request.response.write(
              '<d:multistatus xmlns:d="DAV:"><d:response>'
              '<d:href>$href</d:href><d:propstat><d:prop>'
              '${directory == null ? '' : '<d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>'}'
              '</d:prop><d:status>HTTP/1.1 200 OK</d:status>'
              '</d:propstat></d:response></d:multistatus>',
            );
          }
        } else {
          expect(request.method, 'DELETE');
          request.response.statusCode = deleteStatus;
          if (deleteStatus == 307) {
            request.response.headers.set('Location', '/different-file.flac');
          }
        }
        await request.response.close();
      });
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      addTearDown(() async {
        await storage.dispose();
        await server.close(force: true);
      });
      await storage.save(
        NetworkConnection(
          id: 'nas',
          name: 'Fixture NAS',
          protocol: NetworkProtocol.webdav,
          address: 'http://127.0.0.1:${server.port}/music/',
          username: 'user',
          password: 'password',
        ),
      );
      final source = NetworkStorageService.source('nas', path);
      final events = SourceDeletionEvents();
      final removed = <String>[];
      events.subscribe((value) async => removed.add(value));
      expect(await storage.canDeleteFile(source), isTrue);
      expect(
        await deleteFile(
          'EXISTS:$source',
          networkStorage: storage,
          deletionEvents: events,
        ),
        deleted,
      );
      expect(removed, deleted ? [source] : isEmpty);
      expect(methods, [
        'PROPFIND',
        if (statStatus == 207 && directory == false) 'DELETE',
      ]);
    });
  }

  test(
    'read-only HTTP, roots, folders and invalid paths cannot be deleted',
    () async {
      final storage = NetworkStorageService(
        read: () async => null,
        write: (_) async {},
      );
      addTearDown(storage.dispose);
      for (final protocol in NetworkProtocol.values) {
        await storage.save(
          NetworkConnection(
            id: protocol.name,
            name: protocol.name,
            protocol: protocol,
            address: protocol == NetworkProtocol.smb
                ? 'smb://example.test/'
                : 'https://example.test/music/',
          ),
        );
      }
      for (final source in [
        'network://http/song.flac',
        'network://webdav/',
        'network://webdav/album/',
        'network://webdav/song.flac?delete=yes',
        'network://webdav/song.flac#track01',
        'network://user@webdav/song.flac',
        'network://webdav/album%2Fsong.flac',
        'network://smb/MUSIC',
      ]) {
        expect(await storage.canDeleteFile(source), isFalse, reason: source);
        expect(await storage.deleteFile(source), isFalse, reason: source);
      }
      expect(
        await storage.canDeleteFile('network://smb/MUSIC/song.flac'),
        isTrue,
      );
      expect(await storage.canDeleteFile('network://webdav/song.flac'), isTrue);
    },
  );
}
