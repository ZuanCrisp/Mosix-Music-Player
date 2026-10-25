import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';

import 'support/lyrics_usability_benchmark.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('re-enrich sidecars', () {
    const wordLyrics = '[00:01.00]<00:01.00>New <00:01.50>words<00:02.00>';
    const result = {'write_external_lrc': true, 'lyrics': wordLyrics};

    test(
      'replaces old LRC without dropping word timestamps or touching audio',
      () async {
        final dir = await Directory.systemTemp.createTemp('reenrich-lyrics-');
        addTearDown(() => dir.delete(recursive: true));
        final audio = await File(
          '${dir.path}/Song.flac',
        ).writeAsBytes([1, 2, 3]);
        final sidecar = await File('${dir.path}/Song.lrc').writeAsString(
          '[00:01.00]Old lyrics that are deliberately longer than the replacement lyric line',
        );
        expect(
          await writeReEnrichSidecarLrc(
            audioFilePath: audio.path,
            reEnrichResult: result,
          ),
          isTrue,
        );
        expect(await sidecar.readAsString(), wordLyrics);
        expect(await audio.readAsBytes(), [1, 2, 3]);
      },
    );

    test(
      'failed requested filesystem write is not reported as success',
      () async {
        final dir = await Directory.systemTemp.createTemp('reenrich-lyrics-');
        addTearDown(() => dir.delete(recursive: true));
        await Directory('${dir.path}/Song.lrc').create();
        await expectLater(
          writeReEnrichSidecarLrc(
            audioFilePath: '${dir.path}/Song.flac',
            reEnrichResult: result,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          await writeReEnrichSidecarLrc(
            audioFilePath: '${dir.path}/Song.flac',
            reEnrichResult: const {'write_external_lrc': false},
          ),
          isFalse,
        );
      },
    );

    test(
      'failed requested SAF write propagates and is not silently ignored',
      () async {
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var succeeds = false;
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'writeSafSidecarLrc');
          expect((call.arguments as Map)['lyrics'], wordLyrics);
          calls++;
          return {'success': succeeds};
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        const path = 'content://example/tree/music/document/opaque';
        await expectLater(
          writeReEnrichSafSidecarLrc(safUri: path, reEnrichResult: result),
          throwsStateError,
        );
        succeeds = true;
        expect(
          await writeReEnrichSafSidecarLrc(
            safUri: path,
            reEnrichResult: result,
          ),
          isTrue,
        );
        // The native FLAC handler has already handled this SAF write.
        expect(
          await writeReEnrichSidecarLrc(
            audioFilePath: path,
            reEnrichResult: result,
          ),
          isFalse,
        );
        expect(calls, 2);
      },
    );
  });

  test(
    'lazy usability and display retain the original normalization contract',
    () {
      final random = Random(8127);
      const fragments = [
        '',
        ' ',
        '\t',
        '\r',
        '\u00a0',
        '\ufeff',
        '\u200b',
        '[ti:Title]',
        '[AR:Artist]',
        '[x-translation:0:YQ==]',
        '[comment:] ',
        '[00:00.00]',
        '[100:2:004]',
        '[00:00.00][00:01.00]',
        '<00:01.00>',
        'v1:',
        'V23: ',
        'v0: ',
        '[bg:]',
        '[bg:  ]',
        '[BG:<00:00.1> v1: ]',
        '[bg:Backing]',
        '[00:00.00]v2:  Words',
        '[broken',
        'Words — 音楽 🎵',
        '[Instrumental:TRUE]',
        '[instrumental:false]',
      ];
      final inputs = <String>[
        lyricsUsabilityFixture(10000),
        lyricsUsabilityFixture(5000, metadataOnly: true),
        '${lyricsUsabilityFixture(5000, metadataOnly: true)}\nLast line',
        for (var sample = 0; sample < 2000; sample++)
          List.generate(
            1 + random.nextInt(12),
            (_) => fragments[random.nextInt(fragments.length)],
          ).join(['\n', '\r\n', '\r', ' '][random.nextInt(4)]),
      ];
      for (final input in inputs) {
        expect(
          cleanLyricsForDisplay(input),
          legacyCleanLyricsForDisplay(input),
        );
        expect(
          hasUsableLyricsContent(input),
          fullDisplayLyricsUsability(input),
        );
      }
    },
  );

  group('shared lyric usability cases', () {
    final cases = File(
      'android/app/src/test/resources/lyrics_usability_cases.tsv',
    ).readAsLinesSync();
    for (final line in cases) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final fields = line.split('\t');
      test(fields.first, () {
        expect(fields, hasLength(3));
        final lyrics = fields[2]
            .replaceAll(r'\n', '\n')
            .replaceAll(r'\r', '\r')
            .replaceAll(r'\t', '\t');
        expect(hasUsableLyricsContent(lyrics), fields[1] == 'true');
      });
    }
  });

  group('lyrics display normalization', () {
    test('rejects metadata-only embedded LRC', () {
      const raw = '''
[ti:Banna Re]
[ar:Dhvani Bhanushali]
[al:Banna Re]
[by:SpotiFLAC Mobile]
''';

      expect(cleanLyricsForDisplay(raw), isEmpty);
      expect(hasUsableLyricsContent(raw), isFalse);
      expect(
        hasEmbeddedLyricsMetadata({'LYRICS': raw, 'UNSYNCEDLYRICS': raw}),
        isFalse,
      );
    });

    test('keeps timed, background, and speaker lyric content', () {
      const raw = '''
[ti:Song]
[00:01.25]Lead line
[bg:Background line]
[00:02:500]<00:02.500>v2: Harmony line
[00:03.00]v3:Third voice
[00:04.00]V12:Twelfth voice
''';

      expect(
        cleanLyricsForDisplay(raw),
        'Lead line\nBackground line\nHarmony line\nThird voice\nTwelfth voice',
      );
      expect(hasUsableLyricsContent(raw), isTrue);
    });

    test('recognizes the instrumental marker without rendering it as text', () {
      expect(isInstrumentalLyricsMarker(' [Instrumental:TRUE] '), isTrue);
      expect(hasUsableLyricsContent('[instrumental:true]'), isTrue);
      expect(cleanLyricsForDisplay('[instrumental:true]'), isEmpty);
    });
  });

  group('metadata conversion merge', () {
    test('preserves explicit advisory using the canonical tag', () {
      final metadata = <String, String>{};

      mergePlatformMetadataForTagEmbed(
        target: metadata,
        source: {'explicit': true},
      );

      expect(metadata['ITUNESADVISORY'], '1');
    });

    test('removes a stale explicit advisory for a non-explicit file', () {
      final metadata = <String, String>{'ITUNESADVISORY': '1'};

      mergePlatformMetadataForTagEmbed(
        target: metadata,
        source: {'explicit': false},
      );

      expect(metadata, isNot(contains('ITUNESADVISORY')));
    });
  });
}
