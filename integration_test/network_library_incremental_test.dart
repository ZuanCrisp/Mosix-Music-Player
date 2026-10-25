import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/services/library_ingestion_store.dart';
import 'package:mornye/services/library_native_adapter.dart';
import 'package:mornye/services/network_library_scanner.dart';
import 'package:mornye/services/network_storage_service.dart';

import '../test/support/library_native_fixture.dart';

Uint8List _flac(String title) {
  final comments = BytesBuilder();
  void little(int value) => comments.add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  little(0);
  final tags = [
    'TITLE=$title',
    'ARTIST=Network artist',
    'ALBUM=Network album',
    'LYRICS=[00:01.00]Hello',
    'REPLAYGAIN_TRACK_GAIN=-5.0 dB',
  ];
  little(tags.length);
  for (final tag in tags) {
    final bytes = utf8.encode(tag);
    little(bytes.length);
    comments.add(bytes);
  }
  final data = comments.takeBytes();
  final header = BytesBuilder()
    ..add(ascii.encode('fLaC'))
    ..add([0, 0, 0, 34])
    ..add(Uint8List(34))
    ..add([
      0x84,
      (data.length >> 16) & 255,
      (data.length >> 8) & 255,
      data.length & 255,
    ])
    ..add(data)
    ..add([0xff, 0xf8]);
  final result = Uint8List(4096);
  final bytes = header.takeBytes();
  result.setRange(0, bytes.length, bytes);
  return result;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  testWidgets('native WebDAV incremental scan survives database reopen and failures', (
    tester,
  ) async {
    final root = await (await getTemporaryDirectory()).createTemp(
      'network-incremental-',
    );
    final databasePath = '${root.path}/live.db';
    final historyPath = '${root.path}/history.db';
    var database = await openDatabase(databasePath);
    await createNativeLibraryFixture(database, historyPath: historyPath);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    final connection = NetworkConnection(
      id: 'incremental-nas',
      name: 'Incremental fixture',
      protocol: NetworkProtocol.webdav,
      address: 'http://127.0.0.1:${server.port}/music/',
    );
    await storage.save(connection);
    await database.update(
      'library_sources',
      {'path': NetworkStorageService.source(connection.id, '')},
      where: 'id = ?',
      whereArgs: ['source'],
    );
    final store = LibraryIngestionStore(
      openDatabase: () async => database,
      ensureHistoryAttached: (_) async {},
    );
    final revisions = <String, int>{'a.flac': 1, 'b.flac': 1, 'c.flac': 1};
    final audioRequests = <String>{};
    final failedTracks = <String>{};
    var listingFailed = false;
    var validators = true;
    var listings = 0;
    final samples = <Map<String, Object>>[];
    server.listen((request) async {
      try {
        if (request.method == 'PROPFIND') {
          final body = await utf8.decoder.bind(request).join();
          expect(body, contains('getlastmodified'));
          expect(body, contains('getetag'));
          listings++;
          request.response.statusCode = listingFailed ? 503 : 207;
          if (!listingFailed) {
            request.response.write('<d:multistatus xmlns:d="DAV:">');
            for (final entry in revisions.entries) {
              request.response.write(
                '<d:response><d:href>/music/${entry.key}</d:href><d:propstat><d:prop>'
                '<d:getcontentlength>4096</d:getcontentlength>'
                '${validators ? '<d:getetag>&quot;${entry.value}&quot;</d:getetag><d:getlastmodified>Mon, 19 Oct 2026 12:00:00 GMT</d:getlastmodified>' : ''}'
                '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
              );
            }
            request.response.write('</d:multistatus>');
          }
        } else {
          await request.drain<void>();
          final name = request.uri.pathSegments.last;
          audioRequests.add(name);
          if (failedTracks.contains(name)) {
            request.response.statusCode = 500;
          } else {
            final file = _flac('$name revision ${revisions[name]}');
            final range = networkByteRange(
              request.headers.value('range'),
              file.length,
            );
            request.response.statusCode = 206;
            request.response.headers.set(
              'Content-Range',
              'bytes ${range.start}-${range.end}/${file.length}',
            );
            request.response.contentLength = range.end - range.start + 1;
            if (request.method != 'HEAD') {
              request.response.add(
                Uint8List.sublistView(file, range.start, range.end + 1),
              );
            }
          }
        }
        await request.response.close();
      } catch (_) {
        request.response.statusCode = 500;
        await request.response.close();
        rethrow;
      }
    });
    Future<void> scan(
      String stage,
      Set<String> expectedReads, {
      bool force = false,
      int errors = 0,
    }) async {
      audioRequests.clear();
      final scanner = NetworkLibraryScanner(
        storage: storage,
        supportDirectory: () async => root,
        temporaryDirectory: () async => root,
        readCachedRows: (paths) => store.readNetworkScanRows('source', paths),
      );
      final result = await scanner.scan(
        NetworkStorageService.source(connection.id, ''),
        forceFullScan: force,
        checkpoint: () async {},
        onProgress: (_, _, _) {},
      );
      try {
        expect(result.errorCount, errors);
        await LibraryNativeAdapter(
          database,
          temporaryDirectory: root,
        ).importScanFile(
          'source',
          result,
          requestId: 'network-incremental-$stage',
          isCancelled: () => false,
        );
        expect(audioRequests, expectedReads);
        samples.add({
          'stage': stage,
          'metadata_files': audioRequests.toList()..sort(),
          'errors': result.errorCount,
        });
      } finally {
        await result.delete();
      }
    }

    try {
      await scan('initial', {'a.flac', 'b.flac', 'c.flac'});
      final initial = await database.query('library', orderBy: 'id');
      expect(initial.every((row) => row['network_file_version'] != null), true);
      expect(
        initial.every(
          (row) => row['has_lyrics'] == 1 && row['has_replaygain'] == 1,
        ),
        true,
      );
      await database.close();
      database = await openDatabase(databasePath);
      await database.execute('PRAGMA recursive_triggers = ON');
      await database.execute('ATTACH DATABASE ? AS history_db', [historyPath]);
      await scan('unchanged-after-reopen', {});
      expect(await database.query('library', orderBy: 'id'), initial);

      revisions['a.flac'] = 2;
      revisions.remove('b.flac');
      revisions['d.flac'] = 1;
      await scan('changed-and-added', {'a.flac', 'd.flac'});
      expect(
        (await database.query(
          'library',
          orderBy: 'file_path',
        )).map((row) => row['track_name']),
        ['a.flac revision 2', 'c.flac revision 1', 'd.flac revision 1'],
      );
      await scan('unchanged-again', {});
      await scan('forced', {'a.flac', 'c.flac', 'd.flac'}, force: true);

      final beforeFailure = await database.query('library', orderBy: 'id');
      listingFailed = true;
      await expectLater(scan('offline', {}), throwsA(isA<HttpException>()));
      expect(await database.query('library', orderBy: 'id'), beforeFailure);
      listingFailed = false;
      revisions['a.flac'] = 3;
      revisions.remove('c.flac');
      failedTracks.add('a.flac');
      await scan('partial', {'a.flac'}, errors: 1);
      expect(await database.query('library', orderBy: 'id'), beforeFailure);
      failedTracks.clear();
      await scan('retry', {'a.flac'});
      expect(await database.query('library'), hasLength(2));

      validators = false;
      await scan('unknown-validators', {'a.flac', 'd.flac'});
      await scan('unknown-validators-again', {'a.flac', 'd.flac'});
      expect(await database.rawQuery('PRAGMA integrity_check'), [
        {'integrity_check': 'ok'},
      ]);
      binding.reportData ??= {};
      binding.reportData!['network_incremental'] = {
        'platform': Platform.operatingSystem,
        'completed_cases': samples.length,
        'samples': samples,
        'folder_listings': listings,
        'note':
            'Actual native metadata/listing/import workers and SQLite, local WebDAV fixture. No live NAS benchmark.',
      };
    } finally {
      await database.close();
      await storage.dispose();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });
}
