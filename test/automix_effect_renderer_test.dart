import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/automix_options.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/automix_effect_renderer.dart';

void main() {
  late Directory temporary;
  setUp(
    () async => temporary = await Directory.systemTemp.createTemp('mix-test-'),
  );
  tearDown(() async => temporary.delete(recursive: true));

  test('failed render and cancelled native work clean owned output', () async {
    final done = Completer<bool>();
    final started = Completer<void>();
    final renderer = AutoMixEffectRenderer(
      temporaryDirectory: () async => temporary,
      jobs: AudioAnalysisJobs<bool>(
        start: (arguments) async {
          await File(arguments.last).writeAsString('partial');
          started.complete();
          return (id: 42, completed: done.future);
        },
        cancel: (id) async {
          expect(id, 42);
          done.complete(false);
        },
      ),
    );
    final render = renderer.render(
      '/missing.flac',
      start: Duration.zero,
      duration: const Duration(seconds: 3),
      options: const AutoMixOptions(effect: AutoMixEffect.echo),
    );
    await started.future;
    renderer.cancel();
    expect(await render, isNull);
    expect(await temporary.list().toList(), isEmpty);
    renderer.dispose();
  });

  test('faster effects read enough source to fill the overlap', () async {
    List<String>? captured;
    final renderer = AutoMixEffectRenderer(
      temporaryDirectory: () async => temporary,
      jobs: AudioAnalysisJobs<bool>(
        start: (arguments) async {
          captured = arguments;
          return (id: 1, completed: Future.value(false));
        },
        cancel: (_) async {},
      ),
    );
    await renderer.render(
      '/missing.flac',
      start: const Duration(seconds: 10),
      duration: const Duration(seconds: 4),
      options: const AutoMixOptions(effect: AutoMixEffect.custom, speed: 1.2),
    );
    final input = captured!.indexOf('-i');
    // 4 s of output at 1.2× needs 4.8 s of the outgoing song.
    expect(captured![input - 1], '4.800000');
    expect(captured![captured!.lastIndexOf('-t') + 1], '4.000000');
    renderer.dispose();
  });

  test(
    'real filters change pitch, attenuate highs, and generate delayed echoes',
    () async {
      final ffmpeg = Platform.environment['MORNYE_TEST_FFMPEG'] ?? 'ffmpeg';
      final ProcessResult probe;
      try {
        probe = await Process.run(ffmpeg, ['-version']);
      } on ProcessException {
        markTestSkipped('Host FFmpeg is unavailable');
        return;
      }
      expect(probe.exitCode, 0);
      final jobs = AudioAnalysisJobs<bool>(
        start: (arguments) async => (
          id: 1,
          completed: Process.run(
            ffmpeg,
            arguments,
          ).then((result) => result.exitCode == 0),
        ),
        cancel: (_) async {},
      );
      final renderer = AutoMixEffectRenderer(
        jobs: jobs,
        temporaryDirectory: () async => temporary,
      );
      Future<Float64List> signal(
        String source,
        AutoMixOptions options, {
        bool bassHandoff = false,
      }) async {
        final input = File('${temporary.path}/input.wav');
        final generated = await Process.run(ffmpeg, [
          '-y',
          '-f',
          'lavfi',
          '-i',
          source,
          '-t',
          '3',
          input.path,
        ]);
        expect(generated.exitCode, 0, reason: '${generated.stderr}');
        final tail = await renderer.render(
          input.path,
          start: Duration.zero,
          duration: const Duration(seconds: 3),
          options: options,
          bassHandoff: bassHandoff,
        );
        expect(tail, isNotNull);
        final pcm = '${temporary.path}/output.pcm';
        final decoded = await Process.run(ffmpeg, [
          '-y',
          '-i',
          tail!.path,
          '-ac',
          '1',
          '-f',
          'f64le',
          pcm,
        ]);
        expect(decoded.exitCode, 0);
        final bytes = await File(pcm).readAsBytes();
        final data = ByteData.sublistView(bytes);
        final samples = Float64List(bytes.length ~/ 8);
        for (var i = 0; i < samples.length; i++) {
          samples[i] = data.getFloat64(i * 8, Endian.little);
        }
        expect(samples.length, 48000 * 3);
        await tail.dispose();
        return samples;
      }

      final pitched = await signal(
        'sine=frequency=440:sample_rate=48000',
        const AutoMixOptions(effect: AutoMixEffect.pitch, pitchSemitones: 2),
      );
      var crossings = 0;
      for (var i = 96001; i < 144000; i++) {
        if (pitched[i - 1] <= 0 && pitched[i] > 0) crossings++;
      }
      expect(crossings, closeTo(440 * pow(2, 2 / 12), 2));
      final filtered = await signal(
        'sine=frequency=5000:sample_rate=48000',
        const AutoMixOptions(effect: AutoMixEffect.muffled),
      );
      double rms(double from, double to) {
        final count = ((to - from) * 48000).round();
        return sqrt(
          filtered
                  .skip((from * 48000).round())
                  .take(count)
                  .fold<double>(0, (sum, value) => sum + value * value) /
              count,
        );
      }

      // The handover starts with the original signal, then progressively
      // removes highs rather than switching to a muffled signal at t=0.
      final dry = rms(0.03, 0.15);
      final easing = rms(0.6, 0.7);
      final wet = rms(2, 3);
      expect(dry, greaterThan(0.08));
      expect(easing, inExclusiveRange(wet, dry));
      expect(wet, lessThan(0.01));
      final echo = await signal(
        "aevalsrc=if(between(t\\,1.5\\,1.501)\\,0.5\\,0):s=48000",
        const AutoMixOptions(effect: AutoMixEffect.echo),
      );
      double peak(double time) => echo
          .skip((time * 48000).round())
          .take(100)
          .fold<double>(0, (p, value) => max(p, value.abs()));
      expect(peak(1.68), greaterThan(0.05));
      expect(peak(1.86), greaterThan(0.02));
      final bass = await signal(
        'sine=frequency=80:sample_rate=48000',
        const AutoMixOptions(),
        bassHandoff: true,
      );
      final treble = await signal(
        'sine=frequency=1000:sample_rate=48000',
        const AutoMixOptions(),
        bassHandoff: true,
      );
      double level(Float64List samples, double start, double end) {
        final slice = samples
            .skip((start * 48000).round())
            .take(((end - start) * 48000).round());
        return sqrt(
          slice.fold<double>(0, (sum, sample) => sum + sample * sample) /
              slice.length,
        );
      }

      expect(level(bass, 0.03, 0.15), greaterThan(0.08));
      expect(level(bass, 2, 3), lessThan(0.02));
      expect(level(treble, 2, 3), greaterThan(0.07));
      renderer.dispose();
    },
  );
}
