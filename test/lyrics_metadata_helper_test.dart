import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/utils/lyrics_metadata_helper.dart';

import 'support/lyrics_usability_benchmark.dart';

void main() {
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
[by:Mosix]
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
