import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Plays a generated tone through the runtime's default deck on macOS:
/// `fvm flutter test integration_test/desktop_playback_deck_test.dart -d macos`
Uint8List _toneWav({int seconds = 6}) {
  const sampleRate = 44100;
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

Future<Duration> _positionAfter(PlaybackDeck deck, Duration wait) async {
  await Future<void>.delayed(wait);
  return await deck.getCurrentPosition() ?? Duration.zero;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => debugDesktopPlatformOverride = true);
  tearDownAll(() => debugDesktopPlatformOverride = null);

  testWidgets('the default deck plays, applies EQ and in-app volume', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('deck-');
    final file = File('${directory.path}/tone.wav');
    await file.writeAsBytes(_toneWav());
    final deck = const PlaybackDependencies().createDeck('desktop-deck-test');
    final states = <PlaybackDeckState>[];
    final subscription = deck.onPlayerStateChanged.listen(states.add);
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
        const Duration(milliseconds: 700),
      );
      expect(first, greaterThan(const Duration(milliseconds: 200)));
      expect(deck.state, PlaybackDeckState.playing);

      final bassBoost = EqualizerPreset.builtIn.firstWhere(
        (preset) => preset.name == 'Bass boost',
      );
      playbackEqualizer.value = const EqualizerSettings(
        enabled: true,
      ).withToneOf(bassBoost.settings);
      final second = await _positionAfter(deck, const Duration(seconds: 1));
      expect(playbackEqualizerError.value, isNull);
      expect(second, greaterThan(first));

      playbackOutputVolume.value = 0.5;
      final third = await _positionAfter(
        deck,
        const Duration(milliseconds: 500),
      );
      expect(third, greaterThan(second));

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
    } finally {
      playbackEqualizer.value = const EqualizerSettings();
      playbackOutputVolume.value = 1;
      await subscription.cancel();
      await deck.dispose();
      await directory.delete(recursive: true);
    }
    expect(playbackEqualizerError.value, isNull);
  }, skip: !Platform.isMacOS);

  testWidgets('the media session handler initializes on macOS', (tester) async {
    final runtime = MusicPlayerRuntime(
      settings: const AppSettings(pauseOnMute: false),
    );
    try {
      final handler = await runtime.initialize();
      expect(runtime.handler, same(handler));
      handler.mediaItem.add(
        const MediaItem(id: 'desktop-session', title: 'Desktop session'),
      );
      await tester.pump(const Duration(milliseconds: 200));
    } finally {
      await runtime.dispose();
    }
  }, skip: !Platform.isMacOS);
}
