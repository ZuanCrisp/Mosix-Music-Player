import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/platform_bridge.dart';

const _lyrics = '[00:01.00]First line\n[00:02.00]Second line';
final _audioPayload = [0xff, 0xf8, ...utf8.encode('unchanged audio payload')];

// Only the metadata blocks are decoded in these tests. Retain an identifiable
// audio payload to verify that embedding lyrics does not rewrite audio bytes.
List<int> _flac() {
  final comments = BytesBuilder();
  void little(int value) {
    comments.add(
      (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
    );
  }

  little(0);
  const tags = ['TITLE=Original title', 'ARTIST=Original artist'];
  little(tags.length);
  for (final tag in tags) {
    final bytes = utf8.encode(tag);
    little(bytes.length);
    comments.add(bytes);
  }
  final bytes = comments.takeBytes();
  return [
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
    ..._audioPayload,
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory library;
  late Directory output;
  late Directory data;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lyrics-access-');
    library = await Directory('${root.path}/Library').create();
    output = await Directory('${root.path}/Exports').create();
    data = await Directory('${root.path}/extension-data').create();
    final sources = await Directory('${root.path}/extensions').create();
    final downloads = await Directory('${root.path}/Downloads').create();
    await PlatformBridge.initExtensionSystem(
      sources.path,
      data.path,
      masterKey: base64Encode(List<int>.filled(32, 1)),
      lyricsProviders: const [],
      lyricsFetchOptions: const {},
      // A selected Library file need not be in the current download folder.
      allowedDirectories: [downloads.path],
    );
  });

  tearDown(() async {
    await PlatformBridge.cleanupExtensions();
    await root.delete(recursive: true);
  });

  for (final alias in [false, true]) {
    testWidgets('embed and read lyrics outside Downloads (alias: $alias)', (
      tester,
    ) async {
      final audio = await File(
        '${library.path}/song.flac',
      ).writeAsBytes(_flac());
      var path = audio.path;
      if (alias) {
        final link = await Link(
          '${root.path}/Library alias',
        ).create(library.path);
        path = '${link.path}/song.flac';
      }

      final result = await PlatformBridge.embedLyricsToFile(path, _lyrics);
      expect(result['success'], true, reason: result.toString());
      expect(
        await PlatformBridge.getLyricsLRC('', 'Song', 'Artist', filePath: path),
        _lyrics,
      );
      final withSource = await PlatformBridge.getLyricsLRCWithSource(
        '',
        'Song',
        'Artist',
        filePath: path,
      );
      expect(withSource['lyrics'], _lyrics);
      expect(withSource['source'], 'Embedded');
      final metadata = await PlatformBridge.readFileMetadata(audio.path);
      expect(metadata['title'], 'Original title');
      expect(metadata['artist'], 'Original artist');
      final bytes = await audio.readAsBytes();
      expect(bytes.sublist(bytes.length - _audioPayload.length), _audioPayload);

      // A second operation must open its own scope and replace the lyric tags.
      const replacement = '[00:01.00]Updated line';
      expect(
        (await PlatformBridge.embedLyricsToFile(path, replacement))['success'],
        true,
      );
      expect(
        await PlatformBridge.getLyricsLRC('', 'Song', 'Artist', filePath: path),
        replacement,
      );
    });
  }

  testWidgets('read sidecar lyrics and export into a separate folder', (
    tester,
  ) async {
    final audio = await File('${library.path}/song.flac').writeAsBytes(_flac());
    await File('${library.path}/song.lrc').writeAsString(_lyrics);
    final result = await PlatformBridge.getLyricsLRCWithSource(
      '',
      'Song',
      'Artist',
      filePath: audio.path,
    );
    expect(result['lyrics'], _lyrics);
    final exported = File('${output.path}/song.lrc');
    final saved = await PlatformBridge.fetchAndSaveLyrics(
      trackName: 'Song',
      artistName: 'Artist',
      spotifyId: '',
      durationMs: 0,
      audioFilePath: audio.path,
      outputPath: exported.path,
    );
    expect(saved['success'], true, reason: saved.toString());
    expect(await exported.readAsString(), _lyrics);
    expect(await audio.readAsBytes(), _flac());
  });

  testWidgets('lyrics operations cannot grant extension storage', (
    tester,
  ) async {
    final protected = await File(
      '${data.path}/private.flac',
    ).writeAsBytes(_flac());
    await expectLater(
      PlatformBridge.embedLyricsToFile(protected.path, _lyrics),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.message,
          'message',
          contains('overlaps extension storage'),
        ),
      ),
    );
    expect(await protected.readAsBytes(), _flac());
  });
}
