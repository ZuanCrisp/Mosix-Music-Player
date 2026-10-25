import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/playback_settings_page.dart';
import 'package:mornye/utils/settings_search_catalog.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/settings_group.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets('personalization switch persists and is searchable ($mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(const AppSettings()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark, accent: MornyeAccent.blue)
                : AppTheme.light(),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const PlaybackSettingsPage(),
          ),
        ),
      );
      final label = find.text('Personalized autoplay');
      await tester.scrollUntilVisible(
        label,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      // On by default; the reset action belongs to the enabled state.
      expect(container.read(settingsProvider).autoplayPersonalization, isTrue);
      expect(find.text('Reset recommendation learning'), findsOneWidget);
      // A stray tap only asks; cancelling keeps what was learned.
      await tester.tap(find.text('Reset recommendation learning'));
      await tester.pumpAndSettle();
      expect(find.text('Reset recommendation learning?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Reset recommendation learning?'), findsNothing);
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).autoplayPersonalization, isFalse);
      expect(container.read(settingsProvider).autoplay, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        AppSettings.fromJson(
          jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>,
        ).autoplayPersonalization,
        isFalse,
      );
      expect(find.text('Reset recommendation learning'), findsNothing);
      await tester.ensureVisible(label);
      await tester.pumpAndSettle();
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(container.read(settingsProvider).autoplayPersonalization, isTrue);
      final l10n = AppLocalizations.of(tester.element(label));
      expect(
        SettingsSearchCatalog(l10n).playback.any(
          (entry) => entry.matches(SettingsSearchQuery('machine learning')),
        ),
        isTrue,
      );
      container.read(settingsProvider.notifier).setPlayerMode('external');
      await tester.pump();
      expect(
        tester
            .widget<SettingsSwitchItem>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is SettingsSwitchItem &&
                    widget.title == 'Personalized autoplay',
              ),
            )
            .enabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
