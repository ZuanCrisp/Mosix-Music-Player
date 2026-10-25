import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/metadata_separators.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/audio_metadata_mapper.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/utils/artist_utils.dart';

void main() {
  test(
    'old settings preserve source formatting and new settings round trip',
    () {
      expect(AppSettings.fromJson({}).metadataSeparators.isDefault, isTrue);
      const separators = MetadataSeparators(
        artist: '; ',
        albumArtist: ' / ',
        composer: ' | ',
        genre: ', ',
      );
      final settings = const AppSettings(metadataSeparators: separators);
      expect(
        AppSettings.fromJson(settings.toJson()).metadataSeparators.toJson(),
        separators.toJson(),
      );
      expect(
        settings.copyWith(embedLyrics: false).metadataSeparators.toJson(),
        separators.toJson(),
      );
    },
  );

  test(
    'formats lists without splitting names or altering unrelated fields',
    () {
      for (final name in [
        'AC/DC',
        'R&B',
        'Florence and the Machine',
        'Simon & Garfunkel',
        'Malcolm X',
      ]) {
        expect(formatMetadataTagValue(name, '; '), name);
      }
      expect(formatMetadataTagValue(' A, B ; C ', '; '), 'A; B; C');
      expect(formatMetadataTagValue(' A, B ', ''), ' A, B ');
      expect(
        formatDownloadTagFields({
          'artist': 'A, B',
          'composer': 'C; D',
          'title': 'A, B',
        }, const MetadataSeparators(artist: ' / ', composer: ' | ')),
        {'artist': 'A / B', 'composer': 'C | D', 'title': 'A, B'},
      );
      for (final invalid in ['\n', '\x00', 'abcdefghijklmnopq']) {
        expect(MetadataSeparators.fromJson({'artist': invalid}).artist, '');
        expect(formatMetadataTagValue('A, B', invalid), 'A, B');
      }
    },
  );

  test(
    'separator preferences survive native download fallback without renaming tracks',
    () {
      const payload = DownloadRequestPayload(
        trackName: 'Track',
        artistName: 'A, B',
        albumName: 'Album',
        outputDir: '/music',
        filenameFormat: '{artist}',
        metadataSeparators: MetadataSeparators(artist: ' / ', genre: '; '),
      );
      final request = payload.withStrategy(useFallback: true).toJson();
      expect(request['artist_name'], 'A, B');
      expect(
        request['metadata_separators'],
        payload.metadataSeparators.toJson(),
      );
      expect(
        const DownloadRequestPayload(
          trackName: 'Track',
          artistName: 'Artist',
          albumName: 'Album',
          outputDir: '/music',
          filenameFormat: '{title}',
        ).toJson(),
        isNot(contains('metadata_separators')),
      );
    },
  );

  test(
    'custom joined artist tags override Vorbis splitting per field only',
    () {
      final fields = {
        'ARTIST': 'A; B',
        'ALBUMARTIST': 'C, D',
        'COMPOSER': 'E | F',
        'artist_separator': '; ',
      };
      final entries = AudioMetadataMapper.buildVorbisMetadataEntries(
        fields,
        artistTagMode: artistTagModeSplitVorbis,
      );
      expect(
        entries
            .where((entry) => entry.key == 'ARTIST')
            .map((entry) => entry.value),
        ['A; B'],
      );
      expect(
        entries
            .where((entry) => entry.key == 'ALBUMARTIST')
            .map((entry) => entry.value),
        ['C', 'D'],
      );
      expect(entries.any((entry) => entry.key.endsWith('_separator')), isFalse);
      expect(
        AudioMetadataMapper.convertToId3Tags(fields),
        isNot(contains('artist_separator')),
      );
      expect(
        AudioMetadataMapper.convertToM4aTags(fields),
        isNot(contains('artist_separator')),
      );
    },
  );
}
