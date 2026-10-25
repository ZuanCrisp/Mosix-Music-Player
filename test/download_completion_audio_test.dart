import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/download_completion_audio.dart';

void main() {
  const backend = <String, dynamic>{
    'actual_bit_depth': 24,
    'actual_sample_rate': 96000,
    'audio_codec': 'flac',
    'bitrate': 900,
  };
  final warnings = <String>[];
  setUp(warnings.clear);

  Future<DownloadCompletionAudio> resolve({
    String path = '/music/track.flac',
    Map<String, dynamic> result = backend,
    Map<String, dynamic>? cached,
    required Future<Map<String, dynamic>> Function(String) probe,
  }) => resolveDownloadCompletionAudio(
    result: result,
    filePath: path,
    fileName: 'track.m4a',
    quality: 'requested quality',
    metadata: cached,
    readMetadata: probe,
    debug: warnings.add,
  );

  test('SAF completion reuses measured audio and tag scan metadata', () async {
    final metadata = <String, dynamic>{
      'bit_depth': '16',
      'sample_rate': 44100.0,
      'audio_codec': 'alac',
      'bit_rate': '256000',
      'hasLyrics': true,
      'replaygain_track_gain': '-2.1 dB',
    };
    final audio = await resolve(
      path: 'content://library/42',
      cached: metadata,
      probe: (_) async => fail('Cached SAF audio must not be copied again'),
    );
    expect(audio.metadata, same(metadata));
    expect(audio.bitDepth, 16);
    expect(audio.sampleRate, 44100);
    expect(audio.bitrate, 256);
    expect(audio.format, 'alac');
    expect(audio.quality, '16-bit/44.1kHz');
    expect(warnings, isEmpty);
  });

  test(
    'failed cache is replaced and lossy specs cannot enter history',
    () async {
      var reads = 0;
      final metadata = <String, dynamic>{
        'audio_codec': 'opus',
        'bit_depth': 32,
        'sample_rate': 48000,
        'bitrate': 192000,
        'lyrics': '',
      };
      final audio = await resolve(
        cached: {'error': 'temporary file missing'},
        probe: (path) async {
          expect(path, '/music/track.flac');
          reads++;
          return metadata;
        },
      );
      expect(reads, 1);
      expect(audio.metadata, same(metadata));
      expect(audio.bitDepth, isNull);
      expect(audio.sampleRate, isNull);
      expect(audio.bitrate, 192);
      expect(audio.format, 'opus');
      expect(audio.quality, 'OPUS 192kbps');
    },
  );

  test('invalid measured values retain usable backend specs', () async {
    final audio = await resolve(
      probe: (_) async => {
        'bit_depth': 0,
        'sample_rate': '-1',
        'bitrate': '0',
        'audio_codec': 'unknown',
      },
    );
    expect(audio.bitDepth, 24);
    expect(audio.sampleRate, 96000);
    expect(audio.bitrate, 900);
    expect(audio.format, 'flac');
    expect(audio.quality, '24-bit/96kHz');
  });

  test('completion reads the typed extension audio protocol', () async {
    final audio = await resolve(
      result: {
        'actual_bit_depth': '24',
        'actual_sample_rate': 96000.0,
        'actual_audio_codec': 'alac',
        'actual_bitrate': '900000',
        'extension_context': {'opaque': 'kept'},
      },
      probe: (_) async => {'error': 'metadata unavailable'},
    );
    expect(audio.bitDepth, 24);
    expect(audio.sampleRate, 96000);
    expect(audio.format, 'alac');
    expect(audio.bitrate, 900);
  });

  for (final throws in [false, true]) {
    test('probe failure preserves quality and prior cache ($throws)', () async {
      final cached = <String, dynamic>{'error': 'old probe failed'};
      final audio = await resolve(
        cached: cached,
        probe: (_) async {
          if (throws) throw StateError('metadata unavailable');
          return {'error': 'metadata unavailable'};
        },
      );
      expect(audio.metadata, same(cached));
      expect(audio.bitDepth, 24);
      expect(audio.sampleRate, 96000);
      expect(audio.bitrate, 900);
      expect(audio.quality, 'requested quality');
      expect(warnings, throws ? hasLength(1) : isEmpty);
    });
  }

  test('unsupported local output skips final audio probing', () async {
    final audio = await resolve(
      path: '/music/track.wav',
      result: {},
      probe: (_) async => fail('Unsupported path must not trigger a probe'),
    );
    expect(audio.format, 'wav');
    expect(audio.metadata, isNull);
    expect(audio.quality, 'requested quality');
  });

  test('lossy filename suppresses stale lossless backend specs', () async {
    final audio = await resolve(
      path: '/music/track.MP3',
      probe: (_) async => {'error': 'metadata unavailable'},
    );
    expect(audio.bitDepth, isNull);
    expect(audio.sampleRate, isNull);
    expect(audio.bitrate, 900);
  });
}
