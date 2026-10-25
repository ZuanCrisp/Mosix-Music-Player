import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/csv_import_service.dart';
import 'package:mornye/services/network_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixtures =
      jsonDecode(
            File(
              'test/fixtures/native_metadata_parsers.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final (index, raw) in (fixtures['listings'] as List).indexed) {
    final fixture = Map<String, dynamic>.from(raw as Map);
    test('listing worker retains synchronous parser contract $index', () async {
      final connection = NetworkConnection(
        id: 'fixture',
        name: 'fixture',
        protocol: NetworkProtocol.values.byName(fixture['protocol'] as String),
        address: fixture['address'] as String,
      );
      final body = fixture['body'] as String;
      final path = fixture['path'] as String;
      final legacy = NetworkStorageService.parseListing(connection, path, body);
      final worker = await NetworkStorageService.parseListingInBackground(
        connection,
        path,
        Uint8List.fromList(utf8.encode(body)),
      );
      List<Map<String, dynamic>> rows(List<NetworkEntry> entries) => entries
          .map(
            (entry) => {
              'path': entry.path,
              'name': entry.name,
              'directory': entry.directory,
              'size': entry.size,
            },
          )
          .toList(growable: false);
      expect(rows(legacy), fixture['entries']);
      expect(rows(worker), fixture['entries']);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'runNativeDataJob');
        final arguments = call.arguments as Map;
        final request = jsonDecode(arguments['request_json'] as String) as Map;
        expect(request, {
          'operation': 'parse_network_listing',
          'protocol': fixture['protocol'],
          'base_url': fixture['base_url'],
          'path': path,
        });
        expect(arguments['bytes'] as Uint8List, utf8.encode(body));
        return jsonEncode({'entries': fixture['entries']});
      });
      try {
        final nativeRows = await NetworkStorageService.parseListingInBackground(
          connection,
          path,
          Uint8List.fromList(utf8.encode(body)),
        );
        expect(rows(nativeRows), fixture['entries']);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  }

  test('deep valid WebDAV uses the isolated compatibility parser', () async {
    final connection = NetworkConnection(
      id: 'deep-dav',
      name: 'deep-dav',
      protocol: NetworkProtocol.webdav,
      address: 'https://nas.test/dav/',
    );
    final body =
        '<d:multistatus xmlns:d="DAV:">${List.filled(18, '<d:wrapper>').join()}'
        '<d:response><d:href>/dav/Album/Song.flac</d:href>'
        '<d:propstat><d:prop><d:getcontentlength>123</d:getcontentlength>'
        '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '</d:response>${List.filled(18, '</d:wrapper>').join()}</d:multistatus>';
    final bytes = Uint8List.fromList(utf8.encode(body));
    final legacy = NetworkStorageService.parseListing(
      connection,
      'Album/',
      body,
    );
    expect(legacy.single.name, 'Song.flac');
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'runNativeDataJob');
      calls++;
      throw PlatformException(
        code: 'data_job_error',
        message: 'XML nesting exceeds 16 elements',
      );
    });
    try {
      final actual = await NetworkStorageService.parseListingInBackground(
        connection,
        'Album/',
        bytes,
      );
      expect(actual.single.path, legacy.single.path);
      expect(actual.single.name, legacy.single.name);
      expect(actual.single.directory, legacy.single.directory);
      expect(actual.single.size, legacy.single.size);
      expect(calls, 1);
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'data_job_error',
          message: 'Invalid listing document',
        );
      });
      await expectLater(
        NetworkStorageService.parseListingInBackground(
          connection,
          'Album/',
          bytes,
        ),
        throwsA(isA<PlatformException>()),
      );
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  for (final (index, raw) in (fixtures['playlists'] as List).indexed) {
    final fixture = Map<String, dynamic>.from(raw as Map);
    test('playlist worker matches shared native fixture $index', () async {
      final tracks = await CsvImportService.parsePlaylistInBackground(
        Uint8List.fromList(utf8.encode(fixture['body'] as String)),
        format: fixture['format'] as String,
        idSeed: fixture['id_seed'] as int,
      );
      expect(
        tracks
            .map(
              (track) => {
                'id': track.id,
                'name': track.name,
                'artistName': track.artistName,
                'albumName': track.albumName,
                'duration': track.duration,
                'isrc': track.isrc,
                'coverUrl': track.coverUrl,
              },
            )
            .toList(growable: false),
        fixture['tracks'],
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'runNativeDataJob');
        final arguments = call.arguments as Map;
        expect(jsonDecode(arguments['request_json'] as String), {
          'operation': 'parse_playlist',
          'format': fixture['format'],
          'id_seed': fixture['id_seed'],
        });
        expect(
          arguments['bytes'] as Uint8List,
          utf8.encode(fixture['body'] as String),
        );
        return jsonEncode({'tracks': fixture['tracks']});
      });
      try {
        final nativeRows = await CsvImportService.parsePlaylistInBackground(
          Uint8List.fromList(utf8.encode(fixture['body'] as String)),
          format: fixture['format'] as String,
          idSeed: fixture['id_seed'] as int,
        );
        expect(
          nativeRows.map((track) => track.id),
          tracks.map((track) => track.id),
        );
        expect(
          nativeRows.map((track) => track.name),
          tracks.map((track) => track.name),
        );
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  }
}
