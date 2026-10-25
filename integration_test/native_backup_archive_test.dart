import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/backup_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/user_profile_store.dart';

Future<void> _dartWrite(String path, List<Map<String, dynamic>> files) =>
    Isolate.run(() async {
      final encoder = ZipFileEncoder()..create(path);
      try {
        for (final file in files) {
          await encoder.addFile(
            File(file['path'] as String),
            file['name'] as String,
            file['store'] == true ? ZipFileEncoder.store : null,
          );
        }
      } finally {
        await encoder.close();
      }
    });

Future<Map<String, dynamic>> _nativeWrite(
  String path,
  List<Map<String, dynamic>> files,
) => PlatformBridge.runNativeDataJob({
  'operation': 'backup_archive_write',
  'output_path': path,
  'files': files,
});

// Top-level helpers capture only paths, never the integration binding or its
// completers through the test's closure context.
Future<void> _writeHistoryFixture(String path) => Isolate.run(() {
  final output = File(path).openSync(mode: FileMode.write);
  try {
    for (var page = 0; page < 100; page++) {
      final text = StringBuffer();
      for (var index = 0; index < 1000; index++) {
        final id = page * 1000 + index;
        text.writeln(
          jsonEncode({
            'id': 'track-$id',
            'trackName': 'Track $id with a unique title',
            'artistName': 'Artist ${id % 997}',
            'albumName': 'Album ${id ~/ 12}',
            'filePath': '/music/album-${id ~/ 12}/track-$id.flac',
            'coverUrl': 'https://example.test/art/${id ~/ 12}.jpg',
            'isrc': 'XX000${id.toString().padLeft(7, '0')}',
            'downloadedAt': '2026-10-06T00:00:00.000Z',
            'duration': 180 + id % 240,
            'bitDepth': 24,
            'sampleRate': 96000,
          }),
        );
      }
      output.writeStringSync(text.toString());
    }
  } finally {
    output.closeSync();
  }
});

Future<List<String>> _archiveDigests(String path, String historyPath) =>
    Isolate.run(() {
      final input = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        return [
          sha256.convert(archive.find('history.ndjson')!.content).toString(),
          sha256.convert(File(historyPath).readAsBytesSync()).toString(),
        ];
      } finally {
        input.closeSync();
      }
    });

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('native-backup-archive-');
  });
  tearDown(() => root.delete(recursive: true));

  testWidgets('production backup routes every category through native ZIP', (
    tester,
  ) async {
    final cover = await File(
      '${root.path}/cover.jpg',
    ).writeAsBytes([255, 216, 255, 217]);
    final photo = await File('${root.path}/avatar.png').writeAsBytes([1, 2, 3]);
    for (var mask = 1; mask < 16; mask++) {
      final hasSettings = mask & 1 != 0;
      final hasHistory = mask & 2 != 0;
      final hasCollections = mask & 4 != 0;
      final hasExtensions = mask & 8 != 0;
      final output = await Directory('${root.path}/backup-$mask').create();
      final backup = await BackupService.writeBackupArchive(
        settings: hasSettings ? {'theme': 'mornye'} : null,
        includeHistory: hasHistory,
        loadHistoryPage: (_, _) async =>
            throw StateError('Native history export must bypass Dart loader'),
        collections: hasCollections
            ? {
                'playlists': [
                  {'id': 'playlist', 'name': '音楽'},
                ],
              }
            : {},
        playlistCoverFiles: hasCollections
            ? {
                'playlist': {'ext': '.jpg', 'path': cover.path},
              }
            : {},
        extensions: hasExtensions
            ? {
                'items': [
                  {'id': 'provider'},
                ],
              }
            : {},
        profile: UserProfile(name: 'Listener', photoPath: photo.path),
        outputDirectory: output,
        temporaryDirectory: root,
      );
      final bundle = await BackupService.parseFile(
        backup.path,
        temporaryDirectory: root,
      );
      expect(bundle, isNotNull, reason: 'mask $mask');
      expect(bundle!.formatVersion, 3);
      expect(bundle.hasSettings, hasSettings);
      expect(bundle.hasHistory, hasHistory);
      expect(bundle.hasCollections, hasCollections);
      expect(bundle.hasExtensions, hasExtensions);
      expect(bundle.profile!.name, 'Listener');
      expect(await File(bundle.profile!.photoPath!).readAsBytes(), [1, 2, 3]);
      if (hasCollections) {
        final playlists = bundle.collections['playlists'] as List;
        expect((playlists.single as Map)['name'], '音楽');
        final restoredCover = bundle.playlistCovers['playlist'] as Map;
        expect(await File(restoredCover['path'] as String).readAsBytes(), [
          255,
          216,
          255,
          217,
        ]);
      }
      final stagedPhoto = bundle.profile!.photoPath!;
      await bundle.cleanup();
      expect(await File(stagedPhoto).exists(), false);
    }
  });

  testWidgets('Dart v2/v3 archives remain readable by the native parser', (
    tester,
  ) async {
    final history =
        '${jsonEncode({'id': 'old-track', 'trackName': 'Old song'})}\n';
    final historyFile = await File(
      '${root.path}/history.ndjson',
    ).writeAsString(history);
    for (final version in [2, 3]) {
      final metadata = await File('${root.path}/metadata.json').writeAsString(
        jsonEncode({
          'magic': BackupService.magic,
          'format_version': version,
          'history_count': 1,
          'data': {
            'settings': {'theme': 'light'},
          },
        }),
      );
      final path = '${root.path}/dart-$version.sflb';
      await _dartWrite(path, [
        {'path': metadata.path, 'name': 'metadata.json', 'store': false},
        {'path': historyFile.path, 'name': 'history.ndjson', 'store': false},
      ]);
      final bundle = await BackupService.parseFile(
        path,
        temporaryDirectory: root,
      );
      expect(bundle, isNotNull);
      expect(bundle!.formatVersion, version);
      expect(bundle.settings, {'theme': 'light'});
      expect((await bundle.streamHistory().toList()).single['id'], 'old-track');
      await bundle.cleanup();
    }
  });

  testWidgets(
    'direct collection JSON round trips through production native ZIP',
    (tester) async {
      expect(PlatformBridge.supportsCoreBackend, isTrue);
      final cover = await File(
        '${root.path}/raw-cover.jpg',
      ).writeAsBytes([255, 216, 255, 217]);
      final photo = await File(
        '${root.path}/raw-avatar.png',
      ).writeAsBytes([1, 2, 3]);
      for (final collections in <Map<String, dynamic>>[
        {
          'wishlist': <dynamic>[],
          'loved': <dynamic>[],
          'playlists': <dynamic>[],
          'favoriteArtists': <dynamic>[],
        },
        {
          'loved': [
            {'opaque': '日本語 🎵 \\ "\n', 'nil': null},
          ],
          'playlists': [
            {'id': 'playlist', 'name': '音楽 "quoted"', 'unknown': null},
          ],
          'future"key': {'collections': '__raw_collections__', 'value': true},
        },
      ]) {
        final archiveFile = await BackupService.writeBackupArchive(
          settings: const {'theme': 'mornye', 'nil': null},
          includeHistory: false,
          loadHistoryPage: (_, _) async =>
              throw StateError('Disabled history must not be loaded'),
          collections: const {},
          collectionsJson: jsonEncode(collections),
          playlistCoverFiles: {
            'playlist': {'ext': '.jpg', 'path': cover.path},
          },
          extensions: const {'items': <dynamic>[]},
          profile: UserProfile(name: '日本語 🎵', photoPath: photo.path),
          outputDirectory: root,
          temporaryDirectory: root,
        );
        final archive = ZipDecoder().decodeBytes(
          await archiveFile.readAsBytes(),
        );
        final metadata =
            jsonDecode(utf8.decode(archive.find('metadata.json')!.content))
                as Map<String, dynamic>;
        final data = metadata['data'] as Map<String, dynamic>;
        expect(data.keys, [
          'settings',
          'profile',
          'collections',
          'playlist_covers',
          'extensions',
        ]);
        expect(data['collections'], collections);
        expect(archive.find('history.ndjson'), isNull);
        final bundle = await BackupService.parseFile(
          archiveFile.path,
          temporaryDirectory: root,
        );
        expect(bundle, isNotNull);
        expect(bundle!.formatVersion, 3);
        expect(bundle.hasCollections, isTrue);
        expect(bundle.hasHistory, isFalse);
        expect(bundle.collections, collections);
        expect(bundle.profile!.name, '日本語 🎵');
        expect(await File(bundle.profile!.photoPath!).readAsBytes(), [1, 2, 3]);
        final restoredCover = bundle.playlistCovers['playlist'] as Map;
        expect(await File(restoredCover['path'] as String).readAsBytes(), [
          255,
          216,
          255,
          217,
        ]);
        await bundle.cleanup();
      }
    },
  );

  testWidgets('ZIP compression parity, latency and UI-isolate heartbeat', (
    tester,
  ) async {
    final historyFile = File('${root.path}/history.ndjson');
    // Setup is outside measurements. The same files, compression modes and
    // default level are fed to the old Dart worker and the native worker.
    await _writeHistoryFixture(historyFile.path);
    final metadata = await File('${root.path}/metadata.json').writeAsString(
      jsonEncode({
        'magic': BackupService.magic,
        'format_version': 3,
        'history_count': 100000,
        'data': <String, dynamic>{},
      }),
    );
    final files = [
      {'path': metadata.path, 'name': 'metadata.json', 'store': false},
      {'path': historyFile.path, 'name': 'history.ndjson', 'store': false},
    ];
    final dartTimes = <int>[];
    final nativeTimes = <int>[];
    final sizes = <String, int>{};
    final heartbeat = <String, List<Map<String, int>>>{
      'native': [],
      'dart': [],
    };
    for (var sample = 0; sample < 7; sample++) {
      for (final native in sample.isEven ? [false, true] : [true, false]) {
        final label = native ? 'native' : 'dart';
        final path = '${root.path}/$label-$sample.sflb';
        final time = Stopwatch()..start();
        var beats = 0;
        var maximumGap = 0;
        var lastBeat = 0;
        final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
          final now = time.elapsedMicroseconds;
          final gap = now - lastBeat;
          if (gap > maximumGap) maximumGap = gap;
          lastBeat = now;
          beats++;
        });
        try {
          if (native) {
            expect((await _nativeWrite(path, files))['published'], true);
          } else {
            await _dartWrite(path, files);
          }
        } finally {
          time.stop();
          timer.cancel();
        }
        expect(beats, greaterThan(0));
        heartbeat[label]!.add({'count': beats, 'maximum_gap_us': maximumGap});
        (native ? nativeTimes : dartTimes).add(time.elapsedMicroseconds);
        sizes[label] = await File(path).length();
        if (sample == 0) {
          // Native output must also be consumable by the original reader.
          final digests = await _archiveDigests(path, historyFile.path);
          expect(digests[0], digests[1]);
        }
      }
    }
    binding.reportData ??= {};
    binding.reportData!['native_backup_archive'] = {
      'platform': Platform.operatingSystem,
      'mode':
          'same-file end-to-end ZIP worker, seven alternating paired samples',
      'history_rows': 100000,
      'input_bytes': await historyFile.length(),
      'dart_microseconds': dartTimes,
      'native_microseconds': nativeTimes,
      'compressed_bytes': sizes,
      'heartbeat': heartbeat,
      'note': 'Codec/job latency; this is not displayed FPS or device RAM.',
    };
  });
}
