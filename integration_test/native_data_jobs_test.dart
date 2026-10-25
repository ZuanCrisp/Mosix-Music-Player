import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_color_utilities/quantize/quantizer_celebi.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/automix_analysis.dart';
import 'package:mornye/services/backup_service.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/id3v23_lyrics.dart';
import 'package:mornye/services/library_row_mapper.dart';
import 'package:mornye/services/library_schema.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/audio_analysis_widget.dart';

// Run on a real Android/iOS host. These tests intentionally use the actual
// channel and native workers; missing bindings must fail, never use a fallback.
Future<Map<String, dynamic>> _job(
  String operation,
  Map<String, dynamic> request, {
  Uint8List? bytes,
  String? requestId,
}) => PlatformBridge.runNativeDataJob(
  {'operation': operation, ...request},
  bytes: bytes,
  requestId: requestId,
);

Map<String, dynamic> _word(LyricWord word) => {
  'timeMs': word.time.inMilliseconds,
  'endMs': word.end?.inMilliseconds,
  'text': word.text,
};

Map<String, dynamic> _lyricsDto(ParsedLyrics lyrics) => {
  'synced': lyrics.synced,
  'wordSynced': lyrics.wordSynced,
  'plainText': lyrics.plainText,
  'writers': lyrics.writers,
  'provider': lyrics.provider,
  'lines': [
    for (final line in lyrics.lines)
      {
        'timeMs': line.time.inMilliseconds,
        'endMs': line.end?.inMilliseconds,
        'text': line.text,
        'words': line.words.map(_word).toList(),
        'romanization': line.romanization,
        'romanizationWords': line.romanizationWords.map(_word).toList(),
        'translation': line.translation,
        'voice': line.voice == null
            ? null
            : {
                'id': line.voice!.id,
                'index': line.voice!.index,
                'isGroup': line.voice!.isGroup,
              },
        'isBackground': line.isBackground,
        'vocalGroup': line.vocalGroup,
      },
  ],
};

Uint8List _drums(double bpm) {
  const rate = 11025;
  final data = ByteData(rate * 24 * 2);
  final random = math.Random(7);
  for (var i = 0; i < rate * 24; i++) {
    final time = i / rate;
    final transient = time < 0.17
        ? 0.0
        : math.exp(-((time - 0.17) % (60 / bpm)) * 50);
    final value =
        0.75 * transient * math.sin(time * 2 * math.pi * 100) +
        (random.nextDouble() - 0.5) * 0.003;
    data.setInt16(i * 2, (value * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List _flac({String title = 'Native song', Uint8List? picture}) {
  final comments = BytesBuilder();
  void little(int number) => comments.add(
    (ByteData(4)..setUint32(0, number, Endian.little)).buffer.asUint8List(),
  );
  little(0);
  final tags = ['TITLE=$title', 'ARTIST=Native artist', 'ALBUM=Native album'];
  little(tags.length);
  for (final tag in tags) {
    final bytes = utf8.encode(tag);
    little(bytes.length);
    comments.add(bytes);
  }
  final output = BytesBuilder()..add(ascii.encode('fLaC'));
  void block(int type, List<int> bytes, {bool last = false}) => output.add([
    type | (last ? 128 : 0),
    (bytes.length >> 16) & 255,
    (bytes.length >> 8) & 255,
    bytes.length & 255,
    ...bytes,
  ]);
  // A valid STREAMINFO descriptor; identifiable audio bytes stay unchanged.
  final streamInfo = ByteData(34)
    ..setUint16(0, 4096)
    ..setUint16(2, 4096);
  final descriptor = (44100 << 44) | (1 << 41) | (15 << 36) | 44100;
  streamInfo.setUint64(10, descriptor);
  block(0, streamInfo.buffer.asUint8List());
  block(4, comments.takeBytes(), last: picture == null);
  if (picture != null) block(6, picture, last: true);
  output.add([0xff, 0xf8, ...utf8.encode('unchanged native audio payload')]);
  return output.takeBytes();
}

class _ProxyFixture {
  _ProxyFixture(this.bytes, {this.pause});
  final Uint8List bytes;
  final Completer<void>? pause;
  final requested = Completer<void>();
  late HttpServer server;
  static const token = '0123456789abcdef0123456789abcdef0123456789abcdef';
  String get url => 'http://127.0.0.1:${server.port}/$token';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        if (request.uri.path != '/$token') {
          request.response.statusCode = 404;
          return;
        }
        final range = request.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        var end = bytes.length;
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
          start = int.parse(match[1]!);
          end = match[2]!.isEmpty
              ? bytes.length
              : math.min(bytes.length, int.parse(match[2]!) + 1);
          request.response.statusCode = 206;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${end - 1}/${bytes.length}',
          );
        }
        request.response.contentLength = end - start;
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.contentType = ContentType('audio', 'flac');
        if (request.method == 'GET') {
          if (!requested.isCompleted) requested.complete();
          if (pause != null) {
            request.response.add(bytes.sublist(start, start + 1));
            await request.response.flush();
            await pause!.future;
            request.response.add(bytes.sublist(start + 1, end));
          } else {
            request.response.add(bytes.sublist(start, end));
          }
        }
      } catch (_) {
        // A cancelled native lease can close its stream before our fixture.
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  Future<void> close() async {
    if (pause != null && !pause!.isCompleted) pause!.complete();
    await server.close(force: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory root;
  var initialized = false;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-data-jobs-');
  });
  tearDown(() async {
    if (initialized) {
      await PlatformBridge.cleanupExtensions();
      initialized = false;
    }
    await root.delete(recursive: true);
  });

  testWidgets(
    'palette ordered quantization matches pinned Material before init',
    (tester) async {
      for (final kind in ['opaque', 'mixed_alpha', 'same_bin']) {
        final random = math.Random(7);
        final rgba = Uint8List(112 * 112 * 4);
        for (var i = 0; i < rgba.length; i += 4) {
          for (var channel = 0; channel < 3; channel++) {
            rgba[i + channel] = kind == 'same_bin'
                ? 96 + random.nextInt(8)
                : random.nextInt(256);
          }
          rgba[i + 3] = kind == 'mixed_alpha'
              ? [0, 64, 255][random.nextInt(3)]
              : 255;
        }
        final old = await QuantizerCelebi().quantize(
          rgba.buffer.asUint32List(),
          128,
        );
        final expected = [
          for (final entry in old.colorToCount.entries)
            [entry.key, entry.value],
        ];
        final result = await _job('palette', {}, bytes: rgba);
        final colors = [
          for (final pair in result['colors'] as List)
            List<int>.from(pair as List),
        ];
        expect(colors, expected, reason: kind);
        expect(
          paletteSeedFromColorCounts(colors),
          paletteSeedFromColorCounts(expected),
        );
      }
    },
  );

  testWidgets(
    'AutoMix f64 detector and spectrum classifier preserve production results',
    (tester) async {
      final patterns = <String, Uint8List>{
        for (final bpm in [90.0, 120.0, 124.0, 160.0]) '$bpm': _drums(bpm),
        'silence': Uint8List(11025 * 24 * 2),
        'short': Uint8List(11025 * 5 * 2),
        'empty': Uint8List(0),
        'odd_tail': Uint8List.fromList([..._drums(120), 255]),
      };
      for (final entry in patterns.entries) {
        final file = await File(
          '${root.path}/${entry.key}.pcm',
        ).writeAsBytes(entry.value);
        final expected = analyzeAutoMixPcm(entry.value);
        final native = await _job('automix', {'path': file.path});
        expect(native['bpm'], expected.bpm, reason: entry.key);
        expect(native['phase'], closeTo(expected.phase, 1e-12));
        expect(native['confidence'], closeTo(expected.confidence, 1e-12));
        expect(native['first_sound'], closeTo(expected.firstSound, 1e-12));
      }
      const width = 400;
      const height = 800;
      const maximum = 96000.0;
      for (final kind in [
        'step',
        'noise_floor',
        'pilot',
        'tilt',
        'rolloff',
        'silence',
      ]) {
        for (final cutoff in [18000.0, 30000.0, maximum]) {
          final plane = Uint8List(width * height);
          for (var y = 0; y < height; y++) {
            final frequency = (height - y - 1) * maximum / height;
            for (var x = 0; x < width; x++) {
              final noise = (x * 13 + y * 7) % 16;
              var value = frequency <= cutoff ? 150 : 5;
              if (kind == 'noise_floor') {
                value = frequency <= cutoff ? 130 + noise : 70 + noise;
              }
              if (kind == 'pilot' && (frequency - 70000).abs() < 120) {
                value = 250;
              }
              if (kind == 'tilt') {
                value = (170 - frequency / maximum * 120).round();
              }
              if (kind == 'rolloff') {
                value =
                    (150 -
                            (frequency - cutoff + 6000).clamp(0, 12000) /
                                12000 *
                                145)
                        .round();
              }
              if (kind == 'silence') value = 0;
              plane[y * width + x] = value;
            }
          }
          final file = await File(
            '${root.path}/spectrum.gray',
          ).writeAsBytes(plane);
          final expected = estimateEffectiveSpectralCutoffHz(
            intensity: plane,
            width: width,
            height: height,
            maxFrequencyHz: maximum,
          );
          final result = await _job('spectral_cutoff', {
            'path': file.path,
            'width': width,
            'height': height,
            'max_frequency': maximum,
          });
          expect(result['cutoff'], expected, reason: '$kind/$cutoff');
        }
      }
    },
  );

  testWidgets('all lyric DTO fields match the existing production parser', (
    tester,
  ) async {
    expect(_lyricCases, hasLength(27));
    for (final (name, raw) in _lyricCases) {
      final expected = _lyricsDto(LyricsParser.parse(raw));
      final native = await _job(
        'parse_lyrics',
        {},
        bytes: Uint8List.fromList(utf8.encode(raw)),
      );
      expect(native, expected, reason: name);
      expect(
        _lyricsDto(await LyricsParser.parseAsyncNative(raw)),
        expected,
        reason: '$name public caller',
      );
    }
  });

  testWidgets(
    'streamed file hashing, playlist/listing parsers and M3U output use real bindings',
    (tester) async {
      final file = File('${root.path}/large.bin');
      final sink = file.openWrite();
      final chunk = List<int>.generate(64 * 1024, (i) => i % 251);
      for (var i = 0; i < 128; i++) {
        sink.add(chunk);
      }
      await sink.close();
      final expected = (await sha256.bind(file.openRead()).first).toString();
      expect(
        (await _job('hash_file', {'path': file.path}))['sha256'],
        expected,
      );
      final csv = await _job(
        'parse_playlist',
        {'format': 'csv', 'id_seed': 42},
        bytes: Uint8List.fromList(
          utf8.encode(
            'Track Name,Artist Name(s),Album Name,Track URI,ISRC\r\n"Song, ""One""",Artist,Album,spotify:track:abc,AAABC1200001\r\n',
          ),
        ),
      );
      expect(csv['tracks'], [
        {
          'id': 'abc',
          'name': 'Song, "One"',
          'artistName': 'Artist',
          'albumName': 'Album',
          'duration': 0,
          'coverUrl': null,
          'isrc': 'AAABC1200001',
        },
      ]);
      final m3u = await _job(
        'parse_playlist',
        {'format': 'm3u', 'id_seed': 42},
        bytes: Uint8List.fromList(
          utf8.encode(
            '#EXTM3U\r#EXTINF:180.5,Artist - Song - Mix\rfolder/a.flac\nMusic/02 Demo.flac',
          ),
        ),
      );
      expect((m3u['tracks'] as List).map((row) => (row as Map)['name']), [
        'Song - Mix',
        '02 Demo',
      ]);
      expect(((m3u['tracks'] as List).first as Map)['duration'], 181);
      final output = '${root.path}/export.m3u8';
      await _job('build_m3u', {
        'output_path': output,
        'entries': [
          {
            'name': 'Song',
            'artist': ' Artist ',
            'duration': 180,
            'path': 'folder/a.flac',
          },
          {
            'name': 'Unknown length',
            'artist': '',
            'duration': 0,
            'path': 'b.flac',
          },
        ],
      });
      expect(
        await File(output).readAsString(),
        '#EXTM3U\n#EXTINF:180,Artist - Song\nfolder/a.flac\n#EXTINF:-1,Unknown length\nb.flac\n',
      );
      final listing = await _job(
        'parse_network_listing',
        {'protocol': 'http', 'base_url': 'https://nas.test/music/', 'path': ''},
        bytes: Uint8List.fromList(
          utf8.encode(
            "<a href='../'>parent</a><a href='Folder/'>folder</a><a href='A%20%2B%23%25.flac'>audio</a><a href='nested/a.flac'>nested</a><a href='https://other.test/music/b.flac'>other</a>",
          ),
        ),
      );
      expect(listing['entries'], [
        {'path': 'Folder/', 'name': 'Folder', 'directory': true, 'size': null},
        {
          'path': 'A +#%.flac',
          'name': 'A +#%.flac',
          'directory': false,
          'size': null,
        },
      ]);
      final dav = await _job(
        'parse_network_listing',
        {
          'protocol': 'webdav',
          'base_url': 'https://nas.test/dav/Album/',
          'path': 'Album/',
        },
        bytes: Uint8List.fromList(
          utf8.encode(
            "<d:multistatus xmlns:d='DAV:'><d:response><d:href>/dav/Album/A%20B.flac</d:href><d:propstat><d:prop><d:getcontentlength>123</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>",
          ),
        ),
      );
      expect(dav['entries'], [
        {
          'path': 'Album/A B.flac',
          'name': 'A B.flac',
          'directory': false,
          'size': 123,
        },
      ]);
    },
  );

  testWidgets(
    'ID3 native writer preserves tag frames and audio bytes exactly',
    (tester) async {
      final titleFrame = [84, 73, 84, 50, 0, 0, 0, 2, 0, 0, 0, 65];
      final original = Uint8List.fromList([
        73,
        68,
        51,
        3,
        0,
        0,
        0,
        0,
        0,
        titleFrame.length,
        ...titleFrame,
        ...List.generate(200000, (i) => i % 251),
      ]);
      final file = await File('${root.path}/id3.mp3').writeAsBytes(original);
      const lyrics = '[00:01.00]A😀\n[00:02.00]音';
      final expected = Id3v23Lyrics.writeUnsyncedLyrics(original, lyrics)!;
      expect(
        (await _job('write_id3v23_lyrics', {
          'file_path': file.path,
          'lyrics': lyrics,
        }))['updated'],
        true,
      );
      expect(await file.readAsBytes(), expected);
      final unsupported = Uint8List.fromList(expected)..[3] = 4;
      await file.writeAsBytes(unsupported);
      expect(
        (await _job('write_id3v23_lyrics', {
          'file_path': file.path,
          'lyrics': 'Other',
        }))['updated'],
        false,
      );
      expect(await file.readAsBytes(), unsupported);
    },
  );

  testWidgets(
    'loopback metadata caches/promotes artwork and verifies upload bytes',
    (tester) async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
      );
      final cover = await File('${root.path}/cover.png').writeAsBytes(png);
      final picture = await _job('build_metadata_picture', {
        'file_path': cover.path,
      });
      final payload = _flac(
        picture: base64Decode(picture['picture'] as String),
      );
      final proxy = _ProxyFixture(payload);
      await proxy.start();
      addTearDown(proxy.close);
      final result = await _job('network_metadata', {
        'url': proxy.url,
        'display_name': 'song.flac',
        'cache_directory': '${root.path}/covers',
      });
      final metadata = result['metadata'] as Map;
      expect(metadata['title'], 'Native song');
      expect(metadata['artist'], 'Native artist');
      expect(metadata['cover_base64'], isNull);
      final cached = File(metadata['cover_path'] as String);
      expect(await cached.readAsBytes(), png);
      expect(metadata['cover_sha256'], sha256.convert(png).toString());
      final promoted = await _job('promote_network_cover', {
        'path': cached.path,
        'directory': '${root.path}/permanent-covers',
      });
      expect(await File(promoted['cover_path'] as String).readAsBytes(), png);
      final local = await File(
        '${root.path}/upload.flac',
      ).writeAsBytes(payload);
      final request = {
        'url': proxy.url,
        'path': local.path,
        'length': payload.length,
        'idle_timeout_ms': 20000,
      };
      expect((await _job('matches_network_upload', request))['matches'], true);
      final different = Uint8List.fromList(payload)..[payload.length - 1] ^= 1;
      await local.writeAsBytes(different);
      expect((await _job('matches_network_upload', request))['matches'], false);
      expect(
        (await _job('matches_network_upload', {
          ...request,
          'length': payload.length + 1,
        }))['matches'],
        false,
      );
    },
  );

  testWidgets(
    'native lease cancellation keeps the UI isolate responsive during a stream',
    (tester) async {
      final payload = Uint8List.fromList(
        List.generate(4 * 1024 * 1024, (i) => i % 251),
      );
      final pause = Completer<void>();
      final proxy = _ProxyFixture(payload, pause: pause);
      await proxy.start();
      addTearDown(proxy.close);
      final file = await File('${root.path}/cancel.bin').writeAsBytes(payload);
      const id = 'integration-cancel-upload';
      var heartbeats = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => heartbeats++,
      );
      try {
        final job = _job('matches_network_upload', {
          'url': proxy.url,
          'path': file.path,
          'length': payload.length,
          'idle_timeout_ms': 20000,
        }, requestId: id);
        final cancelled = expectLater(
          job,
          throwsA(
            isA<PlatformException>().having(
              (error) => error.message,
              'cancellation reason',
              contains('cancelled'),
            ),
          ),
        );
        await proxy.requested.future.timeout(const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 140));
        expect(heartbeats, greaterThanOrEqualTo(3));
        await PlatformBridge.cancelNativeDataJob(id);
        pause.complete();
        await cancelled.timeout(const Duration(seconds: 10));
        expect(await file.length(), payload.length);
      } finally {
        timer.cancel();
      }
    },
  );

  testWidgets(
    'native SQLite import/snapshot and filesystem delta share the app schema',
    (tester) async {
      final media = await Directory('${root.path}/media').create();
      final first = await File(
        '${media.path}/first.flac',
      ).writeAsBytes(_flac());
      final downloadedPath = '${media.path}/downloaded.flac';
      final db = await openDatabase(
        '${root.path}/local_library.db',
        version: LibrarySchema.version,
        onCreate: (db, version) async {
          await LibrarySchema.create(db, version);
        },
      );
      final history = await openDatabase('${root.path}/history.db');
      addTearDown(db.close);
      addTearDown(history.close);
      await history.execute(
        'CREATE TABLE history_path_keys(item_id TEXT, path_key TEXT, PRIMARY KEY(item_id,path_key))',
      );
      await history.insert('history_path_keys', {
        'item_id': 'download',
        'path_key': downloadedPath,
      });
      await db.insert('library_sources', {
        'id': 'test-source',
        'path': media.path,
        'display_name': 'Fixture',
        'enabled': 1,
        'available': 1,
      });
      final common = {
        'library_path': db.path,
        'history_path': history.path,
        'source_id': 'test-source',
        'expected_source_path': media.path,
        'platform': Platform.isAndroid ? 'android' : 'ios',
      };
      final firstRow = <String, dynamic>{
        'id': 'first',
        'trackName': ' CAFÉ İ 💫 ',
        'artistName': 'Artist',
        'albumName': 'Album',
        'filePath': first.path,
        'fileModTime': (await first.stat()).modified.millisecondsSinceEpoch,
        'scannedAt': '2026-10-06T12:00:00.000Z',
        'hasLyrics': true,
        'explicit': 1,
      };
      final ndjson = await File('${root.path}/scan.ndjson').writeAsString(
        [
          firstRow,
          {...firstRow, 'id': 'downloaded', 'filePath': downloadedPath},
        ].map(jsonEncode).join('\n'),
      );
      final full = await _job('library_full_import', {
        ...common,
        'ndjson_path': ndjson.path,
        'expected_count': 2,
        'error_count': 0,
      });
      expect(full['inserted'], 1);
      expect(full['skipped'], 1);
      expect(
        (await db.query('library')).single,
        LibraryRowMapper.encode(firstRow, sourceId: 'test-source'),
      );
      final changed = {...firstRow, 'trackName': 'Updated metadata'};
      final delta = await _job('library_incremental_import', {
        ...common,
        'delta': {
          'files': [changed],
          'removedUris': <String>[],
          'skippedCount': 0,
          'totalFiles': 1,
        },
      });
      expect(delta['committed'], true);
      expect(
        (await db.query('library')).single['track_name'],
        'Updated metadata',
      );
      final snapshot = '${root.path}/snapshot.tsv';
      expect(
        (await _job('library_snapshot', {
          ...common,
          'snapshot_path': snapshot,
        }))['count'],
        1,
      );
      expect(
        await File(snapshot).readAsString(),
        '${firstRow['fileModTime']}\t${first.path}\n',
      );
      final extensions = await Directory('${root.path}/extensions').create();
      final data = await Directory('${root.path}/extension-data').create();
      await PlatformBridge.initExtensionSystem(
        extensions.path,
        data.path,
        masterKey: base64Encode(List.filled(32, 1)),
        lyricsProviders: const [],
        lyricsFetchOptions: const {},
        allowedDirectories: [media.path],
      );
      initialized = true;
      await first.delete();
      final second = await File(
        '${media.path}/second.flac',
      ).writeAsBytes(_flac(title: 'Second native song'));
      final scanned = await _job('library_scan_incremental', {
        ...common,
        'folder_path': media.path,
        'snapshot_path': snapshot,
      });
      expect(scanned['committed'], true);
      final rows = await db.query('library');
      expect(rows, hasLength(1));
      expect(rows.single['file_path'], second.path);
      expect(rows.single['track_name'], 'Second native song');
    },
  );

  testWidgets(
    'native backup history uses the complete app schema and stages legacy JSON',
    (tester) async {
      // Read the initialized production schema, then create an isolated fixture.
      // History rows in the running app are never replaced by this test.
      final source = await HistoryDatabase.instance.database;
      final schema = await source.rawQuery('''
      SELECT sql FROM sqlite_master
      WHERE sql IS NOT NULL
        AND tbl_name IN ('history','history_path_keys','history_search_fts')
      ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 ELSE 2 END
    ''');
      final database = await openDatabase(
        '${root.path}/history.db',
        version: HistoryDatabase.schemaVersion,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA recursive_triggers=ON');
        },
        onCreate: (db, _) async {
          for (final row in schema) {
            await db.execute(row['sql'] as String);
          }
        },
      );
      addTearDown(database.close);
      final track = DownloadHistoryItem(
        id: 'complete',
        trackName: '  CAFÉ İ ΑΣ ß  ',
        artistName: ' Artist ',
        albumName: ' Album ',
        albumArtist: ' Album Artist ',
        coverUrl: 'https://example.test/cover.jpg',
        filePath: 'content://nas.provider/tree/root/document/Ab%252FC.flac',
        storageMode: 'saf',
        downloadTreeUri: 'content://nas.provider/tree/root',
        safRelativeDir: 'Album',
        safFileName: 'Track.flac',
        safRepaired: true,
        service: 'provider',
        downloadedAt: DateTime.utc(2026, 10, 6, 12, 0, 0, 123, 456),
        isrc: ' us-aa-a26 00001 ',
        spotifyId: ' Spotify:Track:ABC ',
        trackNumber: 3,
        totalTracks: 10,
        discNumber: 2,
        totalDiscs: 3,
        duration: 240,
        releaseDate: ' 2026-10-01 ',
        quality: 'lossless',
        bitDepth: 24,
        sampleRate: 96000,
        bitrate: 3456,
        format: 'flac',
        genre: ' Rock ',
        composer: 'Composer',
        label: 'Label',
        copyright: 'Copyright',
        explicit: true,
        hasLyrics: true,
        lyricsMetadataScanVersion: 2,
        hasReplayGain: true,
        replayGainMetadataScanVersion: 1,
      ).toJson();
      final input = await File(
        '${root.path}/history-input.ndjson',
      ).writeAsString('${jsonEncode(track)}\n');
      final common = {
        'history_path': database.path,
        'platform': Platform.isAndroid ? 'android' : 'ios',
      };
      expect(
        (await _job('backup_history_import', {
          ...common,
          'ndjson_path': input.path,
          'expected_count': 1,
        }))['committed'],
        true,
      );
      final stored = (await database.query('history')).single;
      expect(stored.keys, hasLength(48));
      expect(stored['isrc_norm'], 'USAAA2600001');
      expect(stored['sort_track'], 'café i ασ ß');
      expect((await database.query('history_path_keys')).isNotEmpty, true);
      final output = '${root.path}/history-export.ndjson';
      expect(
        (await _job('backup_history_export', {
          ...common,
          'ndjson_path': output,
        }))['published'],
        true,
      );
      expect(jsonDecode((await File(output).readAsLines()).single), track);
      await expectLater(
        _job('backup_history_import', {
          ...common,
          'ndjson_path': input.path,
          'expected_count': 2,
        }),
        throwsA(isA<PlatformException>()),
      );
      expect((await database.query('history')).single, stored);

      final legacy = await File('${root.path}/legacy.json').writeAsString(
        jsonEncode({
          'magic': 'spotiflac-backup',
          'format_version': 1,
          'app_version': '5.0.7',
          'data': {
            'settings': {'theme': 'light'},
            'history': [track, 42],
            'collections': {
              'loved': ['complete'],
            },
          },
        }),
      );
      final bundle = await BackupService.parseFile(
        legacy.path,
        temporaryDirectory: root,
      );
      expect(bundle, isNotNull);
      expect(bundle!.historyCount, 1);
      expect(bundle.history, isEmpty);
      expect(bundle.settings, {'theme': 'light'});
      expect(bundle.collections, {
        'loved': ['complete'],
      });
      expect(await bundle.streamHistory().single, track);
      await bundle.cleanup();
    },
  );
}

// Embedded from test/fixtures/native_lyrics_parsers.json so device tests do not
// depend on repository files or add fixtures to the production asset bundle.
const _lyricCases = <(String, String)>[
  ("empty", ""),
  (
    "plain IDs and Unicode",
    "﻿[ar:Performer]\r[by:Uploader]\r\nV2: 日本語\n\nPlain text",
  ),
  (
    "voices words supplements offset",
    "[offset:100]\n[x-romaji:2000:U2Vjb25kIHJlYWRpbmc=]\n[x-translation:2000:U2Vjb25kIHRyYW5zbGF0aW9u]\n[00:01.00]v1:<00:01.00>First<00:03.00>\n[00:02.00]<00:02.00> V2: Second<00:04.00>\n[00:04.00]v3:Third\n[00:06.00]v12:Twelfth\n[00:08.00]The v2: label stays inside a sentence",
  ),
  (
    "background groups sorting",
    "[offset:100]\n[00:01.00]v2:<00:01.00>Lead<00:06.00>\n[bg:<00:04.00>Echo<00:05.00>]\n[bg:[00:05.00]<00:05.00>Again<00:06.00>]\n[00:03.00]v1:<00:03.00>Other lead<00:06.00>",
  ),
  (
    "repeated line and empty end tags",
    "[00:08.10][00:01.9]<00:01.00>First <00:00.90><00:01.30><00:01.40><00:02.00>second<00:02.00>",
  ),
  (
    "stable simultaneous voice order",
    "[00:02]v2:Guest\n[00:01]Lead\n[00:02]v1:Lead again\n[bg:echo]",
  ),
  (
    "boundary collision supplements",
    "[x-romaji:1009:TmVhcg==]\n[x-romaji:1010:RXhhY3Q=]\n[x-romaji:1001:RnVydGhlcg==]\n[x-translation:2005:VGll]\n[x-translation:2990:Qm91bmRhcnk=]\n[x-translation:4011:VG9vIGZhcg==]\n[00:01.010]A\n[00:02.000]B\n[00:02.010]C\n[00:03.000]D\n[00:04]E",
  ),
  (
    "romanized timed words offset",
    "[offset:109]\n[x-romaji-words:1009:W3sidGV4dCI6IlJvIiwic3RhcnRUaW1lTXMiOjEwMDksImVuZFRpbWVNcyI6MTEwN30seyJ0ZXh0IjoibWEgIiwic3RhcnRUaW1lTXMiOjExMDcsImVuZFRpbWVNcyI6MTMwN30seyJ0ZXh0Ijoibml6ZWQiLCJzdGFydFRpbWVNcyI6MjAwMywiZW5kVGltZU1zIjoyNDk3fV0=]\n[x-romaji:1009:Um9tYSBuaXplZA==]\n[00:01.01]Original",
  ),
  (
    "romanization mismatched words",
    "[x-romaji:1000:Um9tYW5pemVk]\n[x-romaji-words:1000:W3sidGV4dCI6Ik90aGVyIiwic3RhcnRUaW1lTXMiOjEwMDAsImVuZFRpbWVNcyI6MTMwMH1d]\n[00:01]Original",
  ),
  (
    "only romanization timings remain hidden",
    "[x-romaji-words:1000:W3sidGV4dCI6IlJvIiwic3RhcnRUaW1lTXMiOjEwMDAsImVuZFRpbWVNcyI6MTMwMH1d]\n[00:01]Original",
  ),
  (
    "corrupt optional metadata",
    "[x-romaji:1000:%%%]\n[x-romaji:1000:/w==]\n[x-translation:bad:YQ==]\n[x-translation:1000:]\n[x-romaji-words:1000:W251bGxd]\n[00:01]Original",
  ),
  (
    "supplement base64 normalization",
    "[x-romaji:1000:Um8]\n[x-translation:1000:44GT44KT44Gr44Gh44Gv]\n[00:01]Original",
  ),
  (
    "unicode newline supplement first wins",
    "[x-translation:1000:5pel5pys6KqeIF0KU2Vjb25kIGxpbmU=]\n[x-translation:1000:SWdub3JlZA==]\n[00:01]Original",
  ),
  (
    "negative offset and clamped timing",
    "[offset:2500]\n[00:01]<00:01>Word<00:02>\n[00:03]Next",
  ),
  (
    "credits explicit trailer",
    "[au:Existing Writer]\n[x-provider:extension:stored]\n[00:04]Written By: Ignored Writer\n[00:01]Last lyric",
  ),
  (
    "credits via API",
    "[by:SpotiFLAC-Mobile via Example Lyrics API (source: upstream)]\n[00:01]First line\n[00:04]Written By: Example Writer",
  ),
  (
    "credits source fallback",
    "[by:SpotiFLAC-Mobile (source: extension:example.lyrics)]\n[00:01]Lyric",
  ),
  (
    "TTML namespaced agent inheritance",
    "<t:tt xmlns:t=\"http://www.w3.org/ns/ttml\" xmlns:m=\"http://www.w3.org/ns/ttml#metadata\"><t:head><t:metadata><m:agent xml:id=\"lead\" type=\"person\"/><m:agent xml:id=\"guest\" type=\"person\"/><m:agent xml:id=\"v3\" type=\"group\"/><m:agent xml:id=\"third\" type=\"person\"/></t:metadata></t:head><t:body><t:div m:agent=\"lead\"><t:p begin=\"1s\" end=\"3s\">Lead</t:p><t:p begin=\"3s\" end=\"5s\" m:agent=\"guest\">Guest</t:p><t:p begin=\"5s\" end=\"7s\" m:agent=\"v3\">Together</t:p><t:p begin=\"7s\" end=\"9s\" m:agent=\"third\">Third</t:p></t:div></t:body></t:tt>",
  ),
  (
    "TTML runs voices syllable grouping",
    "<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:m=\"http://www.w3.org/ns/ttml#metadata\"><head><metadata><m:agent xml:id=\"v1\" type=\"person\"/><m:agent xml:id=\"v2\" type=\"person\"/></metadata></head><body><div><p begin=\"1s\" end=\"5s\"><span m:agent=\"v1\"><span begin=\"1s\" end=\"2s\">日本</span><span begin=\"2s\" end=\"3s\">語</span></span><span m:agent=\"v2\" begin=\"2s\" end=\"4s\">Reply</span><span m:agent=\"v1\" m:role=\"x-bg\" begin=\"2s\" end=\"3s\">Echo</span></p></div></body></tt>",
  ),
  (
    "TTML partial timing retains text",
    "<tt><body><p begin=\"1s\" end=\"5s\">Untimed <span begin=\"2s\" end=\"3s\">timed</span> ending</p></body></tt>",
  ),
  (
    "TTML paragraph end and word end separate",
    "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div><p begin=\"00:01.009\" end=\"00:05.000\">\n<span begin=\"00:01.009\" end=\"00:01.307\">First</span>\n<span begin=\"00:02.003\" end=\"00:02.497\">second</span>\n</p></div></body></tt>",
  ),
  (
    "TTML duplicate songwriters nested entity text",
    "<tt xmlns:meta=\"urn:example\"><head><meta:songwriter>Example &amp; Writer</meta:songwriter><meta:songwriter>Second <span>Writer</span></meta:songwriter><meta:songwriter>Example &amp; Writer</meta:songwriter></head><body><p begin=\"00:01.00\">Lyric</p></body></tt>",
  ),
  (
    "TTML invalid missing paragraph timing falls to plain",
    "<tt><body><p>No time</p></body></tt>",
  ),
  (
    "TTML CDATA vocals skipped but songwriter retained",
    "<tt><head><songwriter><![CDATA[Writer & guest]]></songwriter></head><body><p begin=\"1s\"><![CDATA[Skipped]]>Visible<![CDATA[Skipped]]> again</p></body></tt>",
  ),
  ("TTML malformed syntax falls to plain", "<tt invalid"),
  (
    "TTML clocks negative and hours",
    "<tt><body><p begin=\"-1.25s\" end=\"0.5s\">Negative</p><p begin=\"01:02:03.456\" end=\"01:02:04.123\"><span begin=\"01:02:03.456\" end=\"01:02:03.455\">Word</span></p><p begin=\"00:07.0005\" end=\"8s\">Rounded</p></body></tt>",
  ),
  (
    "TTML same-voice fragments merge across interruption",
    "<tt xmlns:m=\"http://www.w3.org/ns/ttml#metadata\"><body><p begin=\"1s\" end=\"5s\"><span m:agent=\"v1\" begin=\"1s\">A </span><span m:agent=\"v2\" begin=\"2s\">B</span><span m:agent=\"v1\" begin=\"3s\"> C</span><span m:role=\"x-bg\" m:agent=\"v1\" begin=\"2s\">Echo</span></p></body></tt>",
  ),
];
