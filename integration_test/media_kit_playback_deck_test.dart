import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/media_kit_playback_deck.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Drives the Windows and Linux deck (media_kit) on macOS, where the app
/// itself keeps audioplayers. The macOS app does not bundle libmpv, so the
/// test loads media_kit's audio build from a folder:
///
/// 1. Download `libmpv-xcframeworks_v0.6.0_macos-universal-audio-default
///    .tar.gz` from github.com/media-kit/libmpv-darwin-build releases,
///    extract it and ad-hoc sign each framework
///    (`codesign -s - --force NAME.xcframework/macos-arm64_x86_64/NAME.framework`).
/// 2. `fvm flutter test integration_test/media_kit_playback_deck_test.dart
///    -d macos --dart-define=MORNYE_TEST_LIBMPV=EXTRACTED_FOLDER`
const _libmpvFolder = String.fromEnvironment('MORNYE_TEST_LIBMPV');

// Load order of the frameworks Mpv links through @rpath. Already loaded
// images satisfy those references.
const _frameworks = [
  'Avutil',
  'Swresample',
  'Swscale',
  'Mbedcrypto',
  'Mbedx509',
  'Mbedtls',
  'Avcodec',
  'Avformat',
  'Avfilter',
  'Mpv',
];

String _framework(String name) =>
    '$_libmpvFolder/$name.xcframework/macos-arm64_x86_64/'
    '$name.framework/Versions/A/$name';

Uint8List _toneWav({int seconds = 6, int channels = 2}) {
  const sampleRate = 44100;
  final frames = sampleRate * seconds;
  final dataBytes = frames * channels * 2;
  final bytes = ByteData(44 + dataBytes);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * 2, Endian.little);
  bytes.setUint16(32, channels * 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < frames; i++) {
    final value = math.sin(2 * math.pi * 440 * i / sampleRate) * 0.1;
    for (var channel = 0; channel < channels; channel++) {
      bytes.setInt16(
        44 + (i * channels + channel) * 2,
        (value * 32767).round(),
        Endian.little,
      );
    }
  }
  return bytes.buffer.asUint8List();
}

Future<Duration> _positionAfter(PlaybackDeck deck, Duration wait) async {
  await Future<void>.delayed(wait);
  return await deck.getCurrentPosition() ?? Duration.zero;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    debugDesktopPlatformOverride = true;
    debugPlaybackEngineOverride = PlaybackEngine.mediaKit;
    if (_libmpvFolder.isEmpty) return;
    for (final name in _frameworks) {
      DynamicLibrary.open(_framework(name));
    }
    MediaKit.ensureInitialized(libmpv: _framework('Mpv'));
  });
  tearDownAll(() {
    debugDesktopPlatformOverride = null;
    debugPlaybackEngineOverride = null;
  });

  testWidgets('invalid ID3 BOM does not prevent native MP3 playback or seek', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('mpv-id3-bom-');
    final source = File('${directory.path}/source.mp3');
    final tagged = File('${directory.path}/invalid-bom.mp3');
    final engine = MediaKitEngine();
    final diagnostics = <MpvLogError>[];
    final diagnosticSubscription = engine.errors.listen(diagnostics.add);
    final deck = MediaKitPlaybackDeck(
      playerId: 'mpv-id3-bom-test',
      engine: engine,
    );
    final failures = <Object>[];
    final stateSubscription = deck.onPlayerStateChanged.listen(
      (_) {},
      onError: failures.add,
    );
    try {
      final session = await FFmpegKit.executeWithArguments([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'anullsrc=r=44100:cl=stereo',
        '-t',
        '5',
        '-c:a',
        'libmp3lame',
        '-b:a',
        '128k',
        '-id3v2_version',
        '0',
        '-write_id3v1',
        '0',
        source.path,
      ]);
      expect(
        ReturnCode.isSuccess(await session.getReturnCode()),
        isTrue,
        reason: await session.getOutput(),
      );
      final audio = await source.readAsBytes();
      // ID3v2.3 TIT2 declares UTF-16 but starts with AB instead of a BOM.
      await tagged.writeAsBytes([
        ...'ID3'.codeUnits,
        3,
        0,
        0,
        0,
        0,
        0,
        14,
        ...'TIT2'.codeUnits,
        0,
        0,
        0,
        4,
        0,
        0,
        1,
        0x41,
        0x42,
        0,
        ...audio,
      ]);
      await deck.setVolume(0);
      for (var attempt = 0; attempt < 3; attempt++) {
        await deck.setFileSource(tagged.path);
        expect((await deck.getDuration())!.inMilliseconds, closeTo(5000, 100));
        await deck.resume();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(
          (await deck.getCurrentPosition())!.inMilliseconds,
          greaterThan(100),
        );
        await deck.seek(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(
          (await deck.getCurrentPosition())!.inMilliseconds,
          greaterThanOrEqualTo(1900),
        );
      }
      expect(
        diagnostics.where(
          (error) => error.text.contains('Incorrect BOM value'),
        ),
        isNotEmpty,
      );
      expect(failures, isEmpty);
      final broken = File('${directory.path}/broken.mp3');
      await broken.writeAsString('This is not an audio file.');
      await expectLater(
        deck.setFileSource(broken.path),
        throwsA(isA<MediaKitSourceException>()),
      );
    } finally {
      await stateSubscription.cancel();
      await diagnosticSubscription.cancel();
      await deck.dispose();
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS || _libmpvFolder.isEmpty);

  testWidgets('the media_kit deck plays, filters and scales volume', (
    tester,
  ) async {
    expect(MediaKitPlaybackDeck.isAvailable, isTrue);
    final directory = await Directory.systemTemp.createTemp('mpv-deck-');
    final file = File('${directory.path}/tone.wav');
    await file.writeAsBytes(_toneWav());
    final deck = const PlaybackDependencies().createDeck('mpv-deck-test');
    expect(deck, isA<MediaKitPlaybackDeck>());
    final mpv = deck as MediaKitPlaybackDeck;
    final states = <PlaybackDeckState>[];
    final positions = <Duration>[];
    final subscriptions = [
      deck.onPlayerStateChanged.listen(states.add),
      deck.onPositionChanged.listen(positions.add),
    ];
    try {
      deck.startPositionUpdates(const Duration(milliseconds: 200));
      await deck.configureOutput();
      await deck.setVolume(1);
      await deck.setFileSource(file.path);
      final duration = await deck.getDuration();
      expect(duration!.inMilliseconds, closeTo(6000, 100));

      await deck.resume();
      final first = await _positionAfter(
        deck,
        const Duration(milliseconds: 800),
      );
      expect(first, greaterThan(const Duration(milliseconds: 200)));
      expect(deck.state, PlaybackDeckState.playing);
      // Timer updates, independent of rendered frames.
      expect(positions, isNotEmpty);

      final bassBoost = EqualizerPreset.builtIn.firstWhere(
        (preset) => preset.name == 'Bass boost',
      );
      playbackEqualizer.value = const EqualizerSettings(
        enabled: true,
      ).withToneOf(bassBoost.settings);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final af = await mpv.debugProperty('af');
      expect(af, contains('@mornye_dsp:lavfi'));
      expect(af, contains('equalizer@band0=f=31.25:t=q:w=1.4142:g=6'));
      expect(playbackEqualizerError.value, isNull);
      // media_kit's macOS audio build has no volume filter, so the preamp
      // and headroom move to mpv's volume.
      final gainInChain = af.contains('volume@pre');

      playbackEqualizer.value = playbackEqualizer.value.copyWith(
        gains: [2, 5, 3, 1, 0, 0, 0, 0, 0, 0],
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        await mpv.debugProperty('af'),
        contains('equalizer@band0=f=31.25:t=q:w=1.4142:g=2'),
      );
      expect(playbackEqualizerError.value, isNull);
      final second = await _positionAfter(deck, const Duration(seconds: 1));
      expect(second, greaterThan(first));

      await deck.setVolume(0.8);
      playbackOutputVolume.value = 0.5;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // 0.8 * 0.5 = 0.4 linear gain on mpv's cubic volume scale, with the
      // equalizer's -5 dB headroom when the chain cannot carry it.
      final headroom = gainInChain
          ? 1
          : math.pow(10, playbackEqualizer.value.inputGain / 20);
      final volume = double.parse(await mpv.debugProperty('volume'));
      expect(volume, closeTo(100 * math.pow(0.4 * headroom, 1 / 3), 0.5));

      await deck.pause();
      expect(deck.state, PlaybackDeckState.paused);
      final paused = await deck.getCurrentPosition();
      final still = await _positionAfter(
        deck,
        const Duration(milliseconds: 400),
      );
      expect(
        (still - paused!).abs(),
        lessThan(const Duration(milliseconds: 50)),
      );
      expect(states, contains(PlaybackDeckState.playing));

      playbackEqualizer.value = const EqualizerSettings();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await mpv.debugProperty('af'), isEmpty);
    } finally {
      playbackEqualizer.value = const EqualizerSettings();
      playbackOutputVolume.value = 1;
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await deck.dispose();
      await directory.delete(recursive: true);
    }
    expect(deck.state, PlaybackDeckState.disposed);
    expect(playbackEqualizerError.value, isNull);
  }, skip: !Platform.isMacOS || _libmpvFolder.isEmpty);
}
