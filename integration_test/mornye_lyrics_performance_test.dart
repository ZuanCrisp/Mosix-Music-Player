import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/utils/lyrics_parser.dart';
import 'package:mosix/widgets/player_lyrics.dart';

import 'performance_probe.dart';

final _lyrics = ParsedLyrics(
  synced: true,
  wordSynced: true,
  plainText: '',
  lines: List.generate(200, (index) {
    final words = ['Fixture ', 'line ', '$index ', 'flows ', 'on'];
    return LyricLine(
      time: Duration(seconds: index * 2),
      end: Duration(seconds: (index + 1) * 2),
      text: words.join(),
      words: [
        for (var word = 0; word < words.length; word++)
          LyricWord(
            time: Duration(milliseconds: index * 2000 + word * 400),
            end: Duration(milliseconds: index * 2000 + (word + 1) * 400),
            text: words[word],
          ),
      ],
    );
  }),
);

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  final binding = PerformanceTestBinding.ensureInitialized();
  testWidgets('Mornye production word-synced lyrics and manual scrolling', (
    tester,
  ) async {
    final probe = PerformanceProbe(binding, tester, suite: 'mornye_lyrics');
    final playback = StreamController<PlaybackState>.broadcast();
    final seek = ValueNotifier<Duration?>(null);
    final active = ValueNotifier(true);
    final elapsed = Stopwatch();
    Timer? timer;
    void report(bool playing) => playback.add(
      PlaybackState(
        playing: playing,
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 40) + elapsed.elapsed,
      ),
    );
    void stop() {
      timer?.cancel();
      timer = null;
      elapsed.stop();
      report(false);
    }

    void start() {
      elapsed.start();
      report(true);
      timer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => report(true),
      );
    }

    addTearDown(() async {
      timer?.cancel();
      await playback.close();
      seek.dispose();
      active.dispose();
    });
    final theme = MornyeTheme.build(Brightness.dark);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          playbackStateProvider.overrideWith((ref) => playback.stream),
          musicPlayerControllerProvider.overrideWith(
            (ref) => throw StateError('Unexpected audio controller access'),
          ),
        ],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SafeArea(
              child: ValueListenableBuilder<bool>(
                valueListenable: active,
                builder: (_, value, _) => SyncedLyricsView(
                  lyrics: _lyrics,
                  seekPreview: seek,
                  colorScheme: theme.colorScheme,
                  isActive: value,
                  showPronunciation: false,
                  showTranslation: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    ScrollPosition position() =>
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    Future<void> reset() async {
      stop();
      elapsed.reset();
      active.value = true;
      seek.value = const Duration(seconds: 40);
      report(false);
      await probe.wait(const Duration(milliseconds: 500));
      seek.value = null;
      await probe.wait(const Duration(milliseconds: 150));
    }

    await tester.runAsync(() => probe.wait(const Duration(milliseconds: 100)));
    await probe.measure('lyrics_word_highlight_and_line_progression', () async {
      await reset();
      final before = position().pixels;
      start();
      await probe.wait(const Duration(milliseconds: 2300));
      stop();
      expect(elapsed.elapsed, greaterThan(const Duration(seconds: 2)));
      expect(position().pixels, greaterThan(before + 20));
    });
    await probe.measure('lyrics_manual_scroll_during_playback', () async {
      await reset();
      final before = position().pixels;
      start();
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
      );
      try {
        await touch.moveBy(const Offset(0, -24));
        await probe.wait(const Duration(milliseconds: 50));
        await touch.moveBy(const Offset(0, -100));
        await probe.wait(const Duration(milliseconds: 100));
        final held = position().pixels;
        expect(held, greaterThan(before + 30));
        await probe.wait(const Duration(milliseconds: 2300));
        expect(elapsed.elapsed, greaterThan(const Duration(seconds: 2)));
        expect(position().pixels, closeTo(held, 1));
      } finally {
        stop();
        await touch.up();
      }
    });
    await tester.runAsync(() async {
      stop();
      active.value = false;
      await probe.wait(const Duration(milliseconds: 700));
    });
    await probe.measure(
      'lyrics_inactive_paused_idle',
      () => probe.wait(const Duration(milliseconds: 800)),
      allowIdle: true,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => probe.wait(const Duration(milliseconds: 350)));
    await probe.finish(
      metadata: {
        'scope':
            'Production SyncedLyricsView; 200 generated five-word lines, '
            '200ms in-memory playback stream; no audio, metadata, database, '
            'preferences or network. Active samples include a 650ms paused '
            'seek reset to 40s. Idle is inactive and paused.',
        'lineCount': _lyrics.lines.length,
        'wordsPerLine': 5,
        'manualScrollTolerancePixels': 1,
      },
    );
  });
}
