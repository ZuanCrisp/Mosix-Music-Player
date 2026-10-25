import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/download_result.dart';

void main() {
  test('typed updates retain unknown extension fields in the original map', () {
    final original = <String, dynamic>{
      'success': true,
      'file_path': '/source.flac',
      'actual_bit_depth': 24,
      'actual_sample_rate': 96000,
      'extension_context': {'version': 3, 'opaque': 'kept'},
    };
    final result = DownloadResult.fromMap(original);
    result.markConvertedAudio(
      path: '/converted.opus',
      name: 'Song.opus',
      format: 'opus',
      bitrateKbps: 192,
    );
    expect(original['file_path'], '/converted.opus');
    expect(result.actualBitDepth, isNull);
    expect(result.actualSampleRate, isNull);
    expect(result.bitrateKbps, 192);
    expect(jsonDecode(jsonEncode(result)), original);
    expect(result['extension_context'], {'version': 3, 'opaque': 'kept'});
    expect(identical(DownloadResult.fromMap(result), result), isTrue);
  });

  test(
    'output extension honors explicit fields, logical names, then codec',
    () {
      final cases = <(Map<String, dynamic>, String)>[
        ({'actual_extension': ' MP4 ', 'output_extension': '.flac'}, '.mp4'),
        ({'actual_container': 'invalid', 'container': 'ogg'}, '.ogg'),
        ({'file_name': 'Song.OPUS', 'file_path': '/cache.flac'}, '.opus'),
        (
          {'file_path': 'content://tree/123', 'actual_audio_codec': 'mp4a'},
          '.m4a',
        ),
        ({'file_path': 'content://tree/123', 'audio_codec': 'flac'}, '.flac'),
      ];
      for (final (raw, expected) in cases) {
        expect(DownloadResult.fromMap(raw).outputExtension(), expected);
      }
      expect(
        DownloadResult.fromMap({
          'file_path': '/source.flac',
        }).outputExtension(path: '/final.mp3'),
        '.mp3',
      );
      expect(DownloadResult.fromMap({}).outputExtension(), isNull);
    },
  );

  test(
    'final FLAC clears obsolete provider container and conversion hints',
    () {
      final result = DownloadResult.fromMap({
        'file_name': 'Song.m4a',
        'file_path': '/cache/input.m4a',
        'container': 'mp4',
        'actual_container': 'mp4',
        'requires_container_conversion': true,
        'requiresContainerConversion': true,
        'actual_bit_depth': 24,
        'actual_sample_rate': 96000,
      });
      result.markFlacContainer(path: '/music/Song.flac', name: 'Song.flac');
      expect(result.filePath, '/music/Song.flac');
      expect(result.fileName, 'Song.flac');
      expect(result['actual_container'], 'flac');
      expect(result['container'], 'flac');
      expect(result.outputExtension(), '.flac');
      expect(result.requiresContainerConversion, isFalse);
      expect(result.actualBitDepth, 24);
      expect(result.actualSampleRate, 96000);
    },
  );

  test(
    'conversion and decryption accept current and legacy extension keys',
    () {
      for (final key in [
        'requires_container_conversion',
        'requiresContainerConversion',
      ]) {
        expect(
          DownloadResult.fromMap({key: true}).requiresContainerConversion,
          isTrue,
        );
      }
      for (final raw in <Map<String, dynamic>>[
        {
          'decryption': {'strategy': 'ffmpeg_mov_key', 'key': 'abcd'},
          'output_extension': '.mp4',
        },
        {'decryption_key': ' abcd ', 'output_extension': '.mp4'},
      ]) {
        final descriptor = DownloadResult.fromMap(raw).decryption!;
        expect(descriptor.normalizedStrategy, 'ffmpeg.mov_key');
        expect(descriptor.key, 'abcd');
        expect(descriptor.normalizedOutputExtension, '.mp4');
      }
    },
  );

  test('typed failures retain authentication and legacy error semantics', () {
    final authentication = DownloadResult.fromMap({
      'error': 'Provider challenge',
      'error_type': 'provider_reauth_required',
      'service': 'ext:example',
    }).failure!;
    expect(authentication.type, DownloadErrorType.unknown);
    expect(authentication.retryMessage, 'Provider challenge');
    expect(authentication.service, 'ext:example');
    final rateLimit = DownloadResult.fromMap({
      'error': 'Busy',
      'error_type': 'rate_limit',
      'retry_after_seconds': '30',
    }).failure!;
    expect(rateLimit.type, DownloadErrorType.rateLimit);
    expect(rateLimit.retryMessage, 'Busy retry-after: 30');
    expect(
      DownloadResult.fromMap({'error_type': 'cancelled'}).failure!.cancelled,
      isTrue,
    );
    expect(DownloadResult.fromMap({}).failure!.type, isNull);
    expect(DownloadResult.fromMap({'success': true}).failure, isNull);
  });
}
