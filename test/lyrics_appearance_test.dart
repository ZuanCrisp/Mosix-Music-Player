import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/app_slider.dart';
import 'package:mornye/widgets/lyrics_size_setting.dart';
import 'package:mornye/widgets/lyrics_text_scale.dart';
import 'package:mornye/widgets/player_lyrics.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('lyric scaling respects accessibility and validates stored bounds', () {
    const scale = LyricsTextScaler(TextScaler.linear(1.5), 1.2);
    expect(scale.scale(20), 36);
    expect(normalizeLyricsTextScale(double.nan), 1);
    expect(normalizeLyricsTextScale(20), 1.4);
    expect(normalizeLyricsTextScale(0), 0.8);
    final settings = const ThemeSettings().copyWith(lyricsTextScale: 1.3);
    expect(ThemeSettings.fromJson(settings.toJson()), settings);
  });

  testWidgets('size slider previews, persists on release and resets', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: LyricsSizeSetting()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final slider = tester.widget<AppSlider>(find.byType(AppSlider));
    slider.onChanged!(1.3);
    await tester.pump();
    expect(find.text('130%'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(kLyricsTextScaleKey), isNull);
    slider.onChangeEnd!(1.3);
    await tester.pumpAndSettle();
    expect(loadBootstrapThemeSettings(prefs).lyricsTextScale, 1.3);
    await tester.tap(find.byTooltip('Reset'));
    await tester.pumpAndSettle();
    expect(loadBootstrapThemeSettings(prefs).lyricsTextScale, 1);
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'Mornye subtly scales active lyrics without changing layout (reduced=$reduced)',
      (tester) async {
        final preview = ValueNotifier<Duration?>(const Duration(seconds: 1));
        addTearDown(preview.dispose);
        final theme = MornyeTheme.build(Brightness.dark);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduced),
                child: child!,
              ),
              home: Scaffold(
                body: SyncedLyricsView(
                  lyrics: const ParsedLyrics(
                    synced: true,
                    wordSynced: false,
                    plainText: '',
                    lines: [
                      LyricLine(time: Duration.zero, text: 'First line'),
                      LyricLine(
                        time: Duration(seconds: 10),
                        text: 'Second line',
                      ),
                    ],
                  ),
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
        await tester.pumpAndSettle();
        final scales = tester
            .widgetList<AnimatedScale>(find.byType(AnimatedScale))
            .toList();
        expect(scales.map((widget) => widget.scale), containsAll([1.0, 0.96]));
        expect(
          scales.first.duration,
          reduced ? Duration.zero : const Duration(milliseconds: 420),
        );
        final sizes = find
            .byType(AnimatedScale)
            .evaluate()
            .map((e) => (e.renderObject! as RenderBox).size)
            .toList();
        preview.value = const Duration(seconds: 11);
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<AnimatedScale>(find.byType(AnimatedScale))
              .map((w) => w.scale)
              .toList(),
          scales.map((w) => w.scale).toList().reversed.toList(),
        );
        expect(
          find
              .byType(AnimatedScale)
              .evaluate()
              .map((e) => (e.renderObject! as RenderBox).size)
              .toList(),
          sizes,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
