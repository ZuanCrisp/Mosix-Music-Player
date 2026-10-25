import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/player_lyrics.dart';

void main() {
  for (final mornye in [false, true]) {
    for (final speed in [1.0, 1.5]) {
      testWidgets('late lyric timers catch up to playback ($mornye, $speed)', (
        tester,
      ) async {
        var now = DateTime(2026);
        await withClock(Clock(() => now), () async {
          final playback = StreamController<PlaybackState>.broadcast();
          final preview = ValueNotifier<Duration?>(null);
          addTearDown(playback.close);
          addTearDown(preview.dispose);
          final theme = mornye
              ? MornyeTheme.build(Brightness.dark)
              : AppTheme.dark();
          final lyrics = LyricsParser.parse('''
[00:13.161]First phrase
[00:26.065]Second phrase
[00:39.067]Third phrase
[00:51.938]Fourth phrase
[04:34.977]Final phrase
''');
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playbackStateProvider.overrideWith((ref) => playback.stream),
              ],
              child: MaterialApp(
                theme: theme,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: SyncedLyricsView(
                    lyrics: lyrics,
                    seekPreview: preview,
                    colorScheme: theme.colorScheme,
                    isActive: true,
                    showPronunciation: false,
                    showTranslation: false,
                  ),
                ),
              ),
            ),
          );
          playback.add(
            PlaybackState(
              playing: true,
              processingState: AudioProcessingState.ready,
              updatePosition: Duration.zero,
              speed: speed,
            ),
          );
          await tester.pump();
          await tester.pump();

          double emphasis(String phrase) => tester
              .widget<AnimatedOpacity>(
                find.ancestor(
                  of: find.text(phrase),
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity;

          final startedAt = now;
          final firstBoundary = Duration(
            microseconds: (13161000 / speed).ceil(),
          );
          now = startedAt.add(firstBoundary);
          await tester.pump(firstBoundary);
          expect(emphasis('First phrase'), 1);

          // The audio clock keeps moving while a timer callback is delayed.
          // No fresh position event is needed to catch up to the real song.
          now = startedAt.add(Duration(milliseconds: (45000 / speed).round()));
          await tester.pump(Duration(microseconds: (12904000 / speed).ceil()));
          expect(emphasis('Third phrase'), 1);
          expect(emphasis('First phrase'), lessThan(1));

          now = now.add(Duration(milliseconds: (231000 / speed).round()));
          await tester.pump(const Duration(seconds: 7));
          expect(emphasis('Final phrase'), 1);
          expect(emphasis('Third phrase'), lessThan(1));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      });
    }
  }
}
