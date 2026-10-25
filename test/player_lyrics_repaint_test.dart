import 'dart:async';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/utils/lyrics_parser.dart';
import 'package:mosix/widgets/player_lyrics.dart';

const _text = 'AAAA BBBB';
const _lyrics = ParsedLyrics(
  synced: true,
  wordSynced: true,
  plainText: '',
  lines: [
    LyricLine(
      time: Duration.zero,
      end: Duration(seconds: 20),
      text: _text,
      words: [
        LyricWord(
          time: Duration.zero,
          end: Duration(seconds: 10),
          text: 'AAAA ',
        ),
        LyricWord(
          time: Duration(seconds: 10),
          end: Duration(seconds: 20),
          text: 'BBBB',
        ),
      ],
    ),
  ],
);

Finder get _paint => find.descendant(
  of: find.bySemanticsLabel(_text),
  matching: find.byType(CustomPaint),
);

Future<List<int>> _pixels(WidgetTester tester) async {
  final painter = tester.widget<CustomPaint>(_paint).painter!;
  final size = tester.getSize(_paint);
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final result = bytes.buffer.asUint8List().toList();
    image.dispose();
    picture.dispose();
    return result;
  }))!;
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets(
      'playing lyrics retain their painter and refresh stopped highlights ($mornye)',
      (tester) async {
        final playback = StreamController<PlaybackState>.broadcast();
        final preview = ValueNotifier<Duration?>(null);
        addTearDown(playback.close);
        addTearDown(preview.dispose);
        final theme = mornye
            ? MornyeTheme.build(Brightness.dark)
            : ThemeData.dark();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              playbackStateProvider.overrideWith((ref) => playback.stream),
            ],
            child: MaterialApp(
              theme: theme,
              home: Scaffold(
                body: SyncedLyricsView(
                  lyrics: _lyrics,
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
        Future<void> report(
          int seconds, {
          bool playing = false,
          AudioProcessingState state = AudioProcessingState.ready,
        }) async {
          playback.add(
            PlaybackState(
              playing: playing,
              processingState: state,
              updatePosition: Duration(seconds: seconds),
            ),
          );
          await tester.pump();
          await tester.pump();
        }

        await report(2);
        await tester.pumpAndSettle();
        await report(2, playing: true);
        await tester.pump(const Duration(milliseconds: 500));
        final retained = tester.widget<CustomPaint>(_paint).painter!;
        final early = await _pixels(tester);
        var repaintNotifications = 0;
        void repaint() => repaintNotifications++;
        retained.addListener(repaint);
        await report(6, playing: true);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<CustomPaint>(_paint).painter, same(retained));
        expect(repaintNotifications, greaterThan(0));
        expect(await _pixels(tester), isNot(orderedEquals(early)));
        retained.removeListener(repaint);

        await report(8);
        await tester.pumpAndSettle();
        final paused = await _pixels(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(await _pixels(tester), orderedEquals(paused));
        await report(3);
        await tester.pumpAndSettle();
        expect(await _pixels(tester), isNot(orderedEquals(paused)));

        await report(4, playing: true, state: AudioProcessingState.buffering);
        await tester.pumpAndSettle();
        if (mornye) {
          expect(_paint, findsNothing);
        } else {
          final buffered = await _pixels(tester);
          await tester.pump(const Duration(seconds: 1));
          expect(await _pixels(tester), orderedEquals(buffered));
          await report(7, playing: true, state: AudioProcessingState.buffering);
          await tester.pumpAndSettle();
          expect(await _pixels(tester), isNot(orderedEquals(buffered)));
        }

        preview.value = const Duration(seconds: 2);
        await tester.pumpAndSettle();
        final sought = await _pixels(tester);
        preview.value = const Duration(seconds: 8);
        await tester.pumpAndSettle();
        expect(await _pixels(tester), isNot(orderedEquals(sought)));
        preview.value = const Duration(seconds: 2);
        await tester.pumpAndSettle();
        expect(await _pixels(tester), orderedEquals(sought));
        await report(12, playing: true, state: AudioProcessingState.buffering);
        await tester.pumpAndSettle();
        expect(await _pixels(tester), orderedEquals(sought));
        preview.value = null;
        await report(2);
        await tester.pumpAndSettle();
        expect(await _pixels(tester), orderedEquals(sought));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
