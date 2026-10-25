import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mosix/services/automix_analysis.dart';
import 'package:mosix/services/automix_analyzer.dart';

Uint8List _drumWav(double bpm, {bool silent = false}) {
  const sampleRate = 44100;
  const seconds = 30;
  final bytes = ByteData(44 + sampleRate * seconds * 2);
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
  bytes.setUint32(40, sampleRate * seconds * 2, Endian.little);
  if (!silent) {
    for (var i = 0; i < sampleRate * seconds; i++) {
      final time = i / sampleRate;
      final sinceBeat = (time - 0.17) % (60 / bpm);
      final transient = time < 0.17 ? 0.0 : math.exp(-sinceBeat * 50);
      bytes.setInt16(
        44 + i * 2,
        (24000 * transient * math.sin(time * 2 * math.pi * 100)).round(),
        Endian.little,
      );
    }
  }
  return bytes.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native decoding supplies reliable beats for AutoMix', (
    tester,
  ) async {
    final temporary = await Directory.systemTemp.createTemp('native-beats-');
    final analyzer = AutoMixAnalyzer();
    try {
      final outgoing = File('${temporary.path}/outgoing.wav');
      final incoming = File('${temporary.path}/incoming.wav');
      final silence = File('${temporary.path}/silence.wav');
      await outgoing.writeAsBytes(_drumWav(120));
      await incoming.writeAsBytes(_drumWav(124));
      await silence.writeAsBytes(_drumWav(120, silent: true));
      final outro = await analyzer.analyze(outgoing.path, offset: 6);
      final intro = await analyzer.analyze(incoming.path);
      expect(outro, isNotNull);
      expect(intro, isNotNull);
      expect(
        outro!.reliable,
        isTrue,
        reason: '${outro.bpm}/${outro.confidence}',
      );
      expect(
        intro!.reliable,
        isTrue,
        reason: '${intro.bpm}/${intro.confidence}',
      );
      expect(outro.bpm, closeTo(120, 0.75));
      expect(intro.bpm, closeTo(124, 0.75));
      final plan = AutoMixPlan.create(
        outgoingDuration: const Duration(seconds: 30),
        incomingDuration: const Duration(seconds: 30),
        outro: outro,
        intro: intro,
        outroOffset: 6,
      );
      expect(plan!.beatMatched, isTrue);
      expect(plan.rate, closeTo(120 / 124, 0.01));
      expect(await analyzer.analyze(outgoing.path, offset: 6), same(outro));
      final quiet = await analyzer.analyze(silence.path);
      expect(quiet, isNotNull);
      expect(quiet!.reliable, isFalse);
    } finally {
      analyzer.dispose();
      await temporary.delete(recursive: true);
    }
  });
}
