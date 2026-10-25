import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/theme_settings.dart';
import 'package:mosix/providers/runtime_profile_provider.dart';
import 'package:mosix/providers/theme_provider.dart';
import 'package:mosix/screens/settings/appearance_settings_page.dart';
import 'package:mosix/theme/dynamic_color_wrapper.dart';
import 'package:mosix/theme/mornye_theme.dart';

void main() {
  test(
    'old themes retain outlines and new themes serialize the preference',
    () {
      expect(ThemeSettings.fromJson({}).mornyeGlassOutlines, isTrue);
      const settings = ThemeSettings(mornyeGlassOutlines: false);
      expect(ThemeSettings.fromJson(settings.toJson()), settings);
      expect(
        settings.copyWith(mornyeGlassClarity: 1).mornyeGlassOutlines,
        isFalse,
      );
      expect(settings, isNot(const ThemeSettings()));
    },
  );
  test('glass clarity restores safely from old and invalid settings', () {
    expect(
      ThemeSettings.fromJson({}).mornyeGlassClarity,
      kDefaultMosixGlassClarity,
    );
    for (final (saved, expected) in [
      (0, 0.0),
      (1, 1.0),
      (-1, 0.0),
      (2, 1.0),
      (double.nan, kDefaultMosixGlassClarity),
    ]) {
      final settings = ThemeSettings.fromJson({kMosixGlassClarityKey: saved});
      expect(settings.mornyeGlassClarity, expected);
      expect(ThemeSettings.fromJson(settings.toJson()), settings);
    }
  });
  test('custom accents keep text readable in both appearances', () {
    double contrast(Color first, Color second) {
      final a = first.computeLuminance();
      final b = second.computeLuminance();
      return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
    }

    for (final brightness in Brightness.values) {
      // Grouped settings cells, where tinted action rows sit.
      final cell = brightness == Brightness.dark
          ? const Color(0xff1c1c1e)
          : Colors.white;
      for (final accent in MosixAccent.values) {
        final scheme = MosixTheme.build(
          brightness,
          accent: accent,
        ).colorScheme;
        expect(
          contrast(scheme.primary, scheme.surface),
          greaterThanOrEqualTo(4.5),
          reason: '$accent on $brightness',
        );
        expect(
          contrast(scheme.primary, cell),
          greaterThanOrEqualTo(4.5),
          reason: '$accent on a $brightness grouped cell',
        );
        expect(
          contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
          reason: 'Button text for $accent on $brightness',
        );
      }
    }
  });

  Future<void> openSettings(
    WidgetTester tester,
    SharedPreferences prefs, {
    bool lowEnd = false,
  }) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialThemeSettingsProvider.overrideWithValue(
            loadBootstrapThemeSettings(prefs),
          ),
          // Low-end Android without forced blur renders flat, opaque glass.
          if (lowEnd) lowEndDeviceProvider.overrideWithValue(true),
        ],
        child: DynamicColorWrapper(
          builder: (light, dark, mode) => MaterialApp(
            theme: light,
            darkTheme: dark,
            themeMode: mode,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const MosixSettingsTheme(child: AppearanceSettingsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('switching theme style updates the app in place', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        initialThemeSettingsProvider.overrideWithValue(
          loadBootstrapThemeSettings(prefs),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DynamicColorWrapper(
          builder: (light, dark, mode) => MaterialApp(
            theme: light,
            home: const Scaffold(body: TextField(key: ValueKey('app-state'))),
          ),
        ),
      ),
    );
    final before = tester.state(find.byKey(const ValueKey('app-state')));

    await container.read(themeProvider.notifier).setStyle(AppThemeStyle.mornye);
    await tester.pumpAndSettle();
    expect(tester.state(find.byKey(const ValueKey('app-state'))), before);

    await container
        .read(themeProvider.notifier)
        .setStyle(AppThemeStyle.material);
    await tester.pumpAndSettle();
    expect(tester.state(find.byKey(const ValueKey('app-state'))), before);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'glass outlines toggle survives restart and local themes ($mode)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kThemeStyleKey: 'mornye',
          kThemeModeKey: mode.name,
        });
        final prefs = await SharedPreferences.getInstance();
        await openSettings(tester, prefs);
        final toggle = find.byKey(const ValueKey('mornye-glass-outlines'));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Glass outlines'));
        await tester.pumpAndSettle();
        expect(prefs.getBool(kMosixGlassOutlinesKey), isFalse);
        final context = tester.element(toggle);
        expect(MosixTheme.glassOutlinesOf(context), isFalse);
        final local = MosixTheme.fromContext(
          context,
          brightness: Brightness.dark,
        );
        expect(local.extension<MosixTheme>()!.glassOutlines, isFalse);
        expect(
          local.extension<MosixTheme>()!.glassClarity,
          kDefaultMosixGlassClarity,
        );
        await tester.pumpWidget(const SizedBox());
        await openSettings(tester, prefs);
        expect(MosixTheme.glassOutlinesOf(tester.element(toggle)), isFalse);
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Glass outlines'));
        await tester.pumpAndSettle();
        expect(prefs.getBool(kMosixGlassOutlinesKey), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('glass clarity previews live and survives restart ($mode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs);
      final slider = find.byKey(const ValueKey('mornye-glass-clarity'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 1);
      expect(prefs.getDouble(kMosixGlassClarityKey), 1);
      final context = tester.element(slider);
      expect(MosixTheme.glassClarityOf(context), 1);
      expect(
        find.byKey(const ValueKey('mornye-glass-clear-performance')),
        findsOneWidget,
      );
      expect(
        MosixTheme.fromContext(
          context,
          brightness: Brightness.dark,
        ).extension<MosixTheme>()!.glassClarity,
        1,
      );
      await tester.pumpWidget(const SizedBox());
      await openSettings(tester, prefs);
      expect(tester.widget<Slider>(slider).value, 1);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(-320, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 0);
      expect(prefs.getDouble(kMosixGlassClarityKey), 0);
      expect(
        find.byKey(const ValueKey('mornye-glass-clear-performance')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('glass clarity waits for blur on flat devices ($mode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs, lowEnd: true);
      final slider = find.byKey(const ValueKey('mornye-glass-clarity'));
      final hint = find.byKey(
        const ValueKey('mornye-glass-clarity-unavailable'),
      );
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).onChanged, isNull);
      expect(
        find.byKey(const ValueKey('mornye-glass-clear-performance')),
        findsNothing,
      );
      expect(
        tester.widget<Text>(hint).data,
        'Glass is opaque on this device. Turn on '
        '“Always use blur effects” to adjust clarity.',
      );
      await tester.drag(slider, const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, kDefaultMosixGlassClarity);
      expect(prefs.getDouble(kMosixGlassClarityKey), isNull);

      final forceBlur = find.text('Always use blur effects');
      await tester.scrollUntilVisible(
        forceBlur,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(forceBlur);
      await tester.pumpAndSettle();
      // The lazily built slider scrolled away; bring it back.
      await tester.scrollUntilVisible(
        slider,
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(hint, findsNothing);
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      await tester.drag(slider, const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(prefs.getDouble(kMosixGlassClarityKey), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('glass clarity can override system contrast ($mode)', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(highContrast: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs);
      final slider = find.byKey(const ValueKey('mornye-glass-clarity'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).onChanged, isNull);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('mornye-glass-clarity-unavailable')),
            )
            .data,
        'Your system requests increased contrast, so glass stays opaque. '
        'Turn on “Always use blur effects” to use glass anyway; '
        'text contrast is preserved.',
      );
      final forceBlur = find.text('Always use blur effects');
      await tester.scrollUntilVisible(
        forceBlur,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(forceBlur);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        slider,
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      expect(
        find.byKey(const ValueKey('mornye-glass-clarity-unavailable')),
        findsNothing,
      );
      expect(MediaQuery.highContrastOf(tester.element(slider)), isTrue);
      expect(find.byType(BackdropFilter), findsWidgets);
      await tester.drag(slider, const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(prefs.getDouble(kMosixGlassClarityKey), 1);

      await tester.pumpWidget(const SizedBox());
      await openSettings(tester, prefs);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      expect(tester.widget<Slider>(slider).value, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Mosix accent updates live and survives restart ($mode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
        kSeedColorKey: 0xff123456,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs);
      final page = find.byType(AppearanceSettingsPage);
      final initial = Theme.of(tester.element(page));
      expect(
        initial.colorScheme.primary,
        MosixTheme.accentColor(MosixAccent.red, initial.brightness),
      );

      final blue = find.byTooltip('Blue');
      await tester.ensureVisible(blue);
      await tester.tap(blue);
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(page));
      expect(
        theme.colorScheme.primary,
        MosixTheme.accentColor(MosixAccent.blue, theme.brightness),
      );
      expect(prefs.getString(kMosixAccentKey), 'blue');
      expect(prefs.getInt(kSeedColorKey), 0xff123456);
      final overlay = MosixTheme.fromContext(
        tester.element(page),
        brightness: Brightness.dark,
      );
      expect(overlay.extension<MosixTheme>()!.accent, MosixAccent.blue);
      expect(
        overlay.colorScheme.primary,
        MosixTheme.accentColor(MosixAccent.blue, Brightness.dark),
      );

      await tester.pumpWidget(const SizedBox());
      await openSettings(tester, prefs);
      expect(
        Theme.of(tester.element(page)).colorScheme.primary,
        theme.colorScheme.primary,
      );
      await tester.ensureVisible(find.byTooltip('Red (default)'));
      await tester.tap(find.byTooltip('Red (default)'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(page)).colorScheme.primary,
        initial.colorScheme.primary,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final style in AppThemeStyle.values) {
    testWidgets(
      'system font persists and restores the default ($style)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kThemeStyleKey: style.name,
          kMosixAccentKey: 'blue',
          kUseDynamicColorKey: false,
        });
        final prefs = await SharedPreferences.getInstance();
        await openSettings(tester, prefs);
        final page = find.byType(AppearanceSettingsPage);
        final original = Theme.of(
          tester.element(page),
        ).textTheme.bodyLarge!.fontFamily;
        final setting = find.text('Use system font');
        await tester.scrollUntilVisible(
          setting,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(setting);
        await tester.pumpAndSettle();
        final theme = Theme.of(tester.element(page));
        final systemFamily = theme.textTheme.bodyLarge!.fontFamily;
        expect(systemFamily, isNot('Inter'));
        expect(systemFamily, isNot('Google Sans Flex'));
        expect(prefs.getBool(kUseSystemFontKey), isTrue);
        if (style == AppThemeStyle.mornye) {
          final overlay = MosixTheme.fromContext(
            tester.element(page),
            brightness: Brightness.dark,
          );
          expect(overlay.extension<MosixTheme>()!.useSystemFont, isTrue);
          expect(overlay.extension<MosixTheme>()!.accent, MosixAccent.blue);
          expect(overlay.textTheme.bodyLarge!.fontFamily, systemFamily);
        }
        await tester.pumpWidget(const SizedBox());
        await openSettings(tester, prefs);
        expect(
          Theme.of(tester.element(page)).textTheme.bodyLarge!.fontFamily,
          systemFamily,
        );
        await tester.scrollUntilVisible(
          setting,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(setting);
        await tester.pumpAndSettle();
        expect(prefs.getBool(kUseSystemFontKey), isFalse);
        expect(
          Theme.of(tester.element(page)).textTheme.bodyLarge!.fontFamily,
          original,
        );
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }
}
