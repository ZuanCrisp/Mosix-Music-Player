import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/models/theme_settings.dart';
import 'package:mosix/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy Mornye appearance preferences migrate to Mosix fields',
    () async {
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kLegacyMosixAccentKey: 'blue',
        kLegacyMosixGlassClarityKey: 0.3,
        kLegacyMosixGlassOutlinesKey: false,
      });
      final prefs = await SharedPreferences.getInstance();
      final settings = loadBootstrapThemeSettings(prefs);

      expect(settings.style, AppThemeStyle.mosix);
      expect(settings.mosixAccent, MosixAccent.blue);
      expect(settings.mosixGlassClarity, 0.3);
      expect(settings.mosixGlassOutlines, isFalse);
      expect(
        ThemeSettings.fromJson({
          'theme_style': 'mornye',
          'mornye_accent': 'blue',
          'mornye_glass_clarity': 0.3,
          'mornye_glass_outlines': false,
        }),
        settings,
      );
    },
  );

  test(
    'early theme edits preserve untouched saved settings and await saving',
    () async {
      SharedPreferences.setMockInitialValues({
        kThemeModeKey: 'dark',
        kThemeStyleKey: 'mosix',
        kSeedColorKey: 0xff123456,
        kUseDynamicColorKey: false,
        kUseAmoledKey: true,
        kUseSystemFontKey: true,
        kMosixAccentKey: 'blue',
        kMosixGlassClarityKey: 0.2,
      });
      final prefs = await SharedPreferences.getInstance();
      final releaseLoad = Completer<SharedPreferences>();
      final container = ProviderContainer(
        overrides: [
          themeProvider.overrideWith(
            () => ThemeNotifier(preferences: releaseLoad.future),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(themeProvider.notifier);
      // An explicit edit equal to the bootstrap default still owns this field.
      final savingMode = notifier.setThemeMode(ThemeMode.system);
      final savingAccent = notifier.setMosixAccent(MosixAccent.red);
      await notifier.setMosixGlassClarity(0.8, persist: false);
      var saved = false;
      unawaited(savingAccent.then((_) => saved = true));
      await Future<void>.delayed(Duration.zero);
      expect(saved, isFalse);
      expect(container.read(themeProvider).mosixGlassClarity, 0.8);
      expect(prefs.getString(kThemeModeKey), 'dark');

      releaseLoad.complete(prefs);
      await Future.wait([savingMode, savingAccent]);
      final state = container.read(themeProvider);
      expect(state.themeMode, ThemeMode.system);
      expect(state.mosixAccent, MosixAccent.red);
      expect(state.mosixGlassClarity, 0.8);
      expect(state.style, AppThemeStyle.mosix);
      expect(state.seedColorValue, 0xff123456);
      expect(state.useDynamicColor, isFalse);
      expect(state.useAmoled, isTrue);
      expect(state.useSystemFont, isTrue);
      expect(loadBootstrapThemeSettings(prefs), state);
    },
  );

  test('early preview remains immediate without writing preferences', () async {
    SharedPreferences.setMockInitialValues({
      kMosixGlassClarityKey: 0.2,
      kMosixAccentKey: 'blue',
    });
    final prefs = await SharedPreferences.getInstance();
    final releaseLoad = Completer<SharedPreferences>();
    final loaded = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        themeProvider.overrideWith(
          () => ThemeNotifier(preferences: releaseLoad.future),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(themeProvider, (_, next) {
      if (next.mosixAccent == MosixAccent.blue) loaded.complete();
    });
    await container
        .read(themeProvider.notifier)
        .setMosixGlassClarity(0.8, persist: false);
    expect(container.read(themeProvider).mosixGlassClarity, 0.8);
    releaseLoad.complete(prefs);
    await loaded.future;
    expect(container.read(themeProvider).mosixGlassClarity, 0.8);
    expect(prefs.getDouble(kMosixGlassClarityKey), 0.2);
  });

  test(
    'failed preference loading keeps early edits without leaking errors',
    () async {
      final releaseLoad = Completer<SharedPreferences>();
      final container = ProviderContainer(
        overrides: [
          themeProvider.overrideWith(
            () => ThemeNotifier(preferences: releaseLoad.future),
          ),
        ],
      );
      addTearDown(container.dispose);
      final saving = container.read(themeProvider.notifier).setUseAmoled(true);
      releaseLoad.completeError(StateError('theme_load_failed'));
      await saving;
      expect(container.read(themeProvider).useAmoled, isTrue);
    },
  );

  test(
    'disposed theme does not read state or save after delayed loading',
    () async {
      SharedPreferences.setMockInitialValues({kUseAmoledKey: false});
      final prefs = await SharedPreferences.getInstance();
      final releaseLoad = Completer<SharedPreferences>();
      final container = ProviderContainer(
        overrides: [
          themeProvider.overrideWith(
            () => ThemeNotifier(preferences: releaseLoad.future),
          ),
        ],
      );
      final saving = container.read(themeProvider.notifier).setUseAmoled(true);
      container.dispose();
      releaseLoad.complete(prefs);
      await saving;
      expect(prefs.getBool(kUseAmoledKey), isFalse);
    },
  );
}
