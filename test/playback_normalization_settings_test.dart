import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/widgets/app_slider.dart';
import 'package:mosix/widgets/playback_normalization_settings.dart';

void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool enabled = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          const AppSettings(playbackNormalization: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: PlaybackNormalizationSettings(enabled: enabled),
            ),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('pre-amp shows its target and saves at the end of a drag', (
    tester,
  ) async {
    final container = await pump(tester);
    expect(find.text('Pre-amp'), findsOneWidget);
    expect(find.text('0 dB (target -18 LUFS)'), findsOneWidget);

    final slider = tester.widget<AppSlider>(find.byType(AppSlider));
    slider.onChanged!(-7);
    await tester.pump();
    expect(find.text('-7 dB (target -25 LUFS)'), findsOneWidget);
    expect(container.read(settingsProvider).playbackNormalizationPreamp, 0);

    slider.onChangeEnd!(-7);
    await tester.pump();
    expect(container.read(settingsProvider).playbackNormalizationPreamp, -7);

    await tester.tap(find.text('Album'));
    await tester.pump();
    expect(container.read(settingsProvider).playbackNormalizationMode, 'album');
  });

  testWidgets('bit-perfect output disables the controls', (tester) async {
    await pump(tester, enabled: false);
    expect(tester.widget<AppSlider>(find.byType(AppSlider)).onChanged, isNull);
  });
}
