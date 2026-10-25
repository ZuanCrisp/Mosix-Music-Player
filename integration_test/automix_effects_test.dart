import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/services/automix_effect_renderer.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bundled native FFmpeg supports every transition effect', (
    tester,
  ) async {
    final temporary = await Directory.systemTemp.createTemp('native-mix-');
    final renderer = AutoMixEffectRenderer();
    try {
      const sampleRate = 48000;
      final bytes = ByteData(44 + sampleRate * 3 * 2);
      void text(int offset, String value) {
        for (var i = 0; i < value.length; i++) {
          bytes.setUint8(offset + i, value.codeUnitAt(i));
        }
      }

      text(0, 'RIFF');
      bytes.setUint32(4, bytes.lengthInBytes - 8, Endian.little);
      text(8, 'WAVEfmt ');
      bytes.setUint32(16, 16, Endian.little);
      bytes.setUint16(20, 1, Endian.little);
      bytes.setUint16(22, 1, Endian.little);
      bytes.setUint32(24, sampleRate, Endian.little);
      bytes.setUint32(28, sampleRate * 2, Endian.little);
      bytes.setUint16(32, 2, Endian.little);
      bytes.setUint16(34, 16, Endian.little);
      text(36, 'data');
      bytes.setUint32(40, sampleRate * 3 * 2, Endian.little);
      for (var i = 0; i < sampleRate * 3; i++) {
        bytes.setInt16(
          44 + i * 2,
          (12000 * sin(2 * pi * 440 * i / sampleRate)).round(),
          Endian.little,
        );
      }
      final input = File('${temporary.path}/tone.wav');
      await input.writeAsBytes(bytes.buffer.asUint8List());
      for (final options in [
        const AutoMixOptions(effect: AutoMixEffect.pitch, pitchSemitones: 2),
        const AutoMixOptions(effect: AutoMixEffect.echo),
        const AutoMixOptions(effect: AutoMixEffect.muffled),
        const AutoMixOptions(
          effect: AutoMixEffect.custom,
          speed: 1.1,
          pitchSemitones: -3,
          echo: true,
          lowPass: true,
        ),
      ]) {
        final rendered = await renderer.render(
          input.path,
          start: Duration.zero,
          duration: const Duration(seconds: 3),
          options: options,
        );
        expect(rendered, isNotNull, reason: options.effect.name);
        expect(
          await File(rendered!.path).length(),
          inInclusiveRange(48000 * 4 * 3, 48000 * 4 * 3 + 1024),
        );
        await rendered.dispose();
        expect(await rendered.directory.exists(), isFalse);
      }
    } finally {
      renderer.dispose();
      await temporary.delete(recursive: true);
    }
  });
}
