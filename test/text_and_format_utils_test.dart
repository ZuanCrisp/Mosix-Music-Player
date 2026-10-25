import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/mime_utils.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:mornye/utils/string_utils.dart';

void main() {
  group('artist utils', () {
    test('splits common artist separators and removes duplicates for tags', () {
      expect(splitArtistNames(' A, B & C feat. D x E with F '), [
        'A',
        'B',
        'C',
        'D',
        'E',
        'F',
      ]);
      expect(splitArtistTagValues('A, a & B'), ['A', 'B']);
      expect(splitArtistTagValues('   '), isEmpty);
      expect(shouldSplitVorbisArtistTags(artistTagModeSplitVorbis), isTrue);
      expect(shouldSplitVorbisArtistTags(artistTagModeJoined), isFalse);
    });

    // Shared with the Rust and Kotlin primary-artist tests; keep in sync.
    test('primary artist mode keeps the first credited artist', () {
      for (final (input, expected) in [
        ('Calle 24, Chino Pacas', 'Calle 24'),
        ('Calle 24 & Chino Pacas', 'Calle 24'),
        ('Artist A; Artist B', 'Artist A'),
        ('Artist A feat. Artist B', 'Artist A'),
        ('Artist A Feat Artist B', 'Artist A'),
        ('Artist A ft. Artist B', 'Artist A'),
        ('Artist A featuring Artist B', 'Artist A'),
        ('Artist A with Artist B', 'Artist A'),
        ('Artist A x Artist B', 'Artist A'),
        ('Artist A X Artist B', 'Artist A'),
        (' , Artist A, Artist B', 'Artist A'),
        ('Malcolm X', 'Malcolm X'),
        ('Artist Without Fear', 'Artist Without Fear'),
        ('Maxx', 'Maxx'),
        ('AC/DC', 'AC/DC'),
        ('  Various Artists  ', 'Various Artists'),
        ('', ''),
      ]) {
        expect(primaryArtistTagValue(input), expected, reason: input);
        expect(
          artistTagValueForMode(input, ' Primary '),
          expected,
          reason: input,
        );
      }
      for (final mode in [artistTagModeJoined, artistTagModeSplitVorbis]) {
        expect(artistTagValueForMode('A, B', mode), 'A, B');
      }
      expect(artistTagModes, contains(artistTagModePrimary));
      expect(
        artistTagModeForExistingTags(artistTagModePrimary),
        artistTagModeJoined,
      );
      expect(
        artistTagModeForExistingTags(artistTagModeSplitVorbis),
        artistTagModeSplitVorbis,
      );
    });

    test('primary artist mode rewrites every artist key spelling', () {
      final metadata = {
        'ARTIST': 'A, B',
        'album_artist': 'A & B',
        'ALBUM ARTIST': 'A feat. B',
        'albumArtist': 'A x B',
        'TITLE': 'A, B',
        'COMPOSER': 'A, B',
        'artist': '',
      };
      expect(applyArtistTagModeToMetadata(metadata, artistTagModePrimary), {
        'ARTIST': 'A',
        'album_artist': 'A',
        'ALBUM ARTIST': 'A',
        'albumArtist': 'A',
        'TITLE': 'A, B',
        'COMPOSER': 'A, B',
        'artist': '',
      });
      expect(
        identical(
          applyArtistTagModeToMetadata(metadata, artistTagModeJoined),
          metadata,
        ),
        isTrue,
      );
    });
  });

  group('audio conversion utils', () {
    test('normalizes lightweight library scan metadata for display probes', () {
      final normalized = normalizeScannedAudioMetadata({
        'trackName': 'Song',
        'artistName': 'Artist',
        'albumName': 'Album',
        'albumArtist': 'Album Artist',
        'releaseDate': '2026',
        'trackNumber': 2,
        'totalTracks': 10,
        'discNumber': 1,
        'totalDiscs': 2,
        'bitDepth': 24,
        'sampleRate': 96000,
        'bitrate': 1840,
        'albumType': 'album',
        'explicit': true,
        'upc': '4006381333931',
        'comment': 'https://media.example/album/1',
        'format': 'flac',
      });

      expect(normalized['title'], 'Song');
      expect(normalized['artist'], 'Artist');
      expect(normalized['album'], 'Album');
      expect(normalized['album_artist'], 'Album Artist');
      expect(normalized['date'], '2026');
      expect(normalized['track_number'], 2);
      expect(normalized['total_tracks'], 10);
      expect(normalized['disc_number'], 1);
      expect(normalized['total_discs'], 2);
      expect(normalized['bit_depth'], 24);
      expect(normalized['sample_rate'], 96000);
      expect(normalized['bitrate'], 1840);
      expect(normalized['album_type'], 'album');
      expect(normalized['explicit'], isTrue);
      expect(normalized['upc'], '4006381333931');
      expect(normalized['comment'], 'https://media.example/album/1');
      expect(normalized['audio_codec'], 'flac');
    });

    test('does not replace stored tags with filename scan fallbacks', () {
      final normalized = normalizeScannedAudioMetadata({
        'trackName': 'Filename fallback',
        'artistName': 'Unknown Artist',
        'albumName': 'Unknown Album',
        'metadataFromFilename': true,
        'format': 'flac',
      });

      expect(normalized['title'], isNull);
      expect(normalized['artist'], isNull);
      expect(normalized['album'], isNull);
      expect(normalized['audio_codec'], 'flac');
    });

    test('distinguishes an ALAC codec from its M4A container', () {
      expect(normalizeAudioFormatValue('ALAC'), 'alac');
      expect(
        detectedAudioFormatFromMetadata({
          'audio_codec': 'alac',
          'format': 'm4a',
        }),
        'alac',
      );
      expect(
        detectedAudioFormatFromMetadata({'audio_codec': '', 'format': 'alac'}),
        'alac',
      );
    });

    test('treats generic M4A container reports as inconclusive codecs', () {
      expect(isInconclusiveAudioCodec(null), isTrue);
      expect(isInconclusiveAudioCodec('m4a'), isTrue);
      expect(isInconclusiveAudioCodec('MP4'), isTrue);
      expect(isInconclusiveAudioCodec('flac'), isFalse);
      expect(isInconclusiveAudioCodec('aac'), isFalse);
    });

    test('uses m4a for ISO-BMFF audio except AC-4 passthrough', () {
      expect(isoBmffAudioExtensionForCodec('opus'), '.m4a');
      expect(isoBmffAudioExtensionForCodec('ec-3'), '.m4a');
      expect(isoBmffAudioExtensionForCodec('aac'), '.m4a');
      expect(isoBmffAudioExtensionForCodec('ac-4'), '.mp4');
    });

    test(
      'detects Dolby formats from stored scan format before file extension',
      () {
        expect(
          convertibleAudioSourceFormat(
            storedFormat: 'eac3',
            filePath: 'content://media/song.m4a',
          ),
          'EAC3',
        );
        expect(convertibleAudioSourceFormat(fileName: 'Song.ac-3'), 'AC3');
        expect(convertibleAudioSourceFormat(storedFormat: 'ac4'), 'AC4');
      },
    );

    test('allows Dolby sources only for lossy batch conversion targets', () {
      expect(
        canConvertAudioFormat(sourceFormat: 'EAC3', targetFormat: 'MP3'),
        isTrue,
      );
      expect(
        canConvertAudioFormat(sourceFormat: 'EAC3', targetFormat: 'Opus'),
        isTrue,
      );
      expect(
        canConvertAudioFormat(sourceFormat: 'EAC3', targetFormat: 'AAC'),
        isTrue,
      );
      expect(
        canConvertAudioFormat(sourceFormat: 'EAC3', targetFormat: 'FLAC'),
        isFalse,
      );
      expect(
        canConvertAudioFormat(sourceFormat: 'EAC3', targetFormat: 'ALAC'),
        isFalse,
      );
    });
  });

  group('string utils', () {
    test('normalizes optional strings and cover references', () {
      expect(normalizeOptionalString(null), isNull);
      expect(normalizeOptionalString(' null '), isNull);
      expect(normalizeOptionalString(' value '), 'value');
      expect(
        normalizeCoverReference('//cdn.example.test/a.jpg'),
        'https://cdn.example.test/a.jpg',
      );
      expect(
        normalizeCoverReference('https://example.test/a.jpg'),
        'https://example.test/a.jpg',
      );
      expect(
        normalizeCoverReference('/storage/music/a.jpg'),
        '/storage/music/a.jpg',
      );
      expect(normalizeCoverReference('relative/a.jpg'), isNull);
      expect(normalizeRemoteHttpUrl('file:///tmp/a.jpg'), isNull);
      expect(
        normalizeRemoteHttpUrl('http://example.test/a.jpg'),
        'http://example.test/a.jpg',
      );
    });

    test('formats display audio quality from strongest available source', () {
      expect(
        buildDisplayAudioQuality(
          bitrateKbps: 320,
          format: 'mp3',
          bitDepth: 24,
          sampleRate: 96000,
          storedQuality: 'LOSSLESS',
        ),
        'MP3 320kbps',
      );
      expect(
        buildDisplayAudioQuality(bitDepth: 24, sampleRate: 96000),
        '24-bit/96kHz',
      );
      expect(formatSampleRateKHz(44100), '44.1kHz');
      expect(buildDisplayAudioQuality(storedQuality: ' Hi-Res '), 'Hi-Res');
      expect(isPlaceholderQualityLabel('lossless'), isTrue);
      expect(isPlaceholderQualityLabel('FLAC 1411kbps'), isFalse);
    });
  });

  group('mime utils', () {
    test('maps known audio extensions and falls back to wildcard', () {
      expect(audioMimeTypeForPath('/music/song.FLAC'), 'audio/flac');
      expect(audioMimeTypeForPath('/music/song.m4a'), 'audio/mp4');
      expect(audioMimeTypeForPath('/music/song.mp3'), 'audio/mpeg');
      expect(audioMimeTypeForPath('/music/song.ogg'), 'audio/ogg');
      expect(audioMimeTypeForPath('/music/song.wav'), 'audio/wav');
      expect(audioMimeTypeForPath('/music/song.aac'), 'audio/aac');
      expect(audioMimeTypeForPath('/music/song'), 'audio/*');
      expect(audioMimeTypeForPath('/music/song.'), 'audio/*');
      expect(audioMimeTypeForPath('/music/song.txt'), 'audio/*');
    });
  });

  group('path match keys', () {
    test('builds normalized variants for local paths and file uris', () {
      final keys = buildPathMatchKeys('EXISTS: /Music/A%20Song.FLAC ');

      expect(keys, contains('/Music/A%20Song.FLAC'));
      expect(keys, contains('/music/a%20song.flac'));
      expect(keys, contains('/Music/A Song.FLAC'));
      expect(keys, contains('/music/a song.flac'));
      expect(keys, contains('file:///Music/A%2520Song.FLAC'));
      expect(keys, contains('/Music/A%20Song'));
      expect(
        identical(buildPathMatchKeys('/Music/A%20Song.FLAC'), keys),
        isTrue,
      );
      expect(buildPathMatchKeys('   '), isEmpty);
    });

    test('normalizes windows-style separators', () {
      final keys = buildPathMatchKeys(r'C:\Music\Song.mp3');

      expect(keys, contains(r'C:\Music\Song.mp3'));
      expect(keys, contains('C:/Music/Song.mp3'));
      expect(keys, contains('c:/music/song.mp3'));
      expect(keys, contains('C:/Music/Song'));
    });

    test('matches a primary-storage SAF URI to its raw Android path', () {
      const safUri =
          'content://com.android.externalstorage.documents/'
          'tree/primary%3AMusic%2FFlac%20Songs/'
          'document/primary%3AMusic%2FFlac%20Songs%2FAdore%20You.m4a';
      const rawPath = '/storage/emulated/0/Music/Flac Songs/Adore You.m4a';

      expect(physicalFilePathsMatch(safUri, rawPath), isTrue);
      expect(buildPhysicalPathMatchKeys(safUri), contains(rawPath));
    });

    test('physical matching keeps coexisting audio formats distinct', () {
      const flac = '/storage/emulated/0/Music/Song.flac';
      const opus = '/storage/emulated/0/Music/Song.opus';

      expect(
        buildPathMatchKeys(flac),
        contains('/storage/emulated/0/Music/Song'),
      );
      expect(physicalFilePathsMatch(flac, opus), isFalse);
      expect(isPhysicalFileRetained(opus, [flac]), isFalse);
    });

    test('retains a shared SAF file during duplicate cleanup', () {
      const safUri =
          'content://com.android.externalstorage.documents/'
          'document/primary%3AMusic%2FSong.flac';

      expect(
        isPhysicalFileRetained('/storage/emulated/0/Music/Song.flac', [safUri]),
        isTrue,
      );
    });
  });
}
