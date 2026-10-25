import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;

/// Converts a generated tone with the FFmpeg bundled in the desktop app:
/// `fvm flutter test integration_test/desktop_ffmpeg_bundle_test.dart -d macos`
/// Run it with a PATH that has no ffmpeg (for example `env PATH=/usr/bin:/bin`)
/// to prove the bundle, not a package manager build, did the work.
Uint8List _toneWav({int sampleRate = 44100, int seconds = 2}) {
  final samples = sampleRate * seconds;
  final bytes = ByteData(44 + samples * 2);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + samples * 2, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final value = math.sin(2 * math.pi * 440 * i / sampleRate) * 0.1;
    bytes.setInt16(44 + i * 2, (value * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => debugDesktopPlatformOverride = true);
  tearDownAll(() => debugDesktopPlatformOverride = null);

  testWidgets('the bundled ffmpeg converts and ffprobe probes', (
    tester,
  ) async {
    final tools = await DesktopFFmpegTools.locate();
    final bundled = p.normalize(
      p.join(p.dirname(Platform.resolvedExecutable), '..', 'Resources'),
    );
    expect(tools.ffmpegPath, p.join(bundled, 'ffmpeg', 'ffmpeg'));
    expect(tools.ffprobePath, p.join(bundled, 'ffmpeg', 'ffprobe'));

    final temporary = await Directory.systemTemp.createTemp('ffmpeg-bundle-');
    try {
      final wav = p.join(temporary.path, 'tone.wav');
      await File(wav).writeAsBytes(_toneWav());

      // FLAC through the soxr resampler, which the conversion settings offer.
      final flac = p.join(temporary.path, 'tone.flac');
      final toFlac = await FFmpegExecution.arguments([
        '-v',
        'error',
        '-i',
        wav,
        '-af',
        'aresample=resampler=soxr:osr=48000',
        '-c:a',
        'flac',
        '-compression_level',
        '8',
        flac,
        '-y',
      ]);
      expect(toFlac.success, isTrue, reason: toFlac.output);

      final info = await FFmpegExecution.mediaInformation(flac);
      expect(info, isNotNull);
      final stream = info!.getStreams().single;
      expect(stream.getCodec(), 'flac');
      expect(stream.getSampleRate(), '48000');
      expect(double.parse(info.getDuration()!), closeTo(2, 0.05));

      // The lossy encoders the conversion screen offers.
      for (final (codec, extension) in [
        ('libmp3lame', 'mp3'),
        ('libopus', 'opus'),
        ('aac', 'm4a'),
        ('alac', 'm4a'),
      ]) {
        final output = p.join(temporary.path, 'tone-$codec.$extension');
        final result = await FFmpegExecution.arguments([
          '-v',
          'error',
          '-i',
          flac,
          '-c:a',
          codec,
          output,
          '-y',
        ]);
        expect(result.success, isTrue, reason: '$codec: ${result.output}');
        expect(await File(output).length(), greaterThan(0));
      }
    } finally {
      await temporary.delete(recursive: true);
    }
  });
}
