import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/app_localizations.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/screens/settings/keyboard_shortcuts_page.dart';
import 'package:mosix/theme/app_theme.dart';
import 'package:mosix/theme/mosix_theme.dart';
import 'package:mosix/widgets/desktop/desktop_commands.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  for (final mosix in [false, true]) {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
      final style = mosix ? 'Mosix' : 'Material';
      testWidgets('$style lists every ${platform.name} shortcut', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1200, 3000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [settingsProvider.overrideWith(_Settings.new)],
            child: MaterialApp(
              theme: mosix
                  ? MosixTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: KeyboardShortcutsPage(platform: platform),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final shown = tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data ?? '')
            .join('\n');
        final destinations = desktopDestinationTabs(
          mosix: mosix,
          showStore: const AppSettings().showExtensionStore,
        ).length;
        final bound = desktopShortcutBindings(platform).keys;
        for (final activator in bound.cast<SingleActivator>()) {
          // Unused destination numbers have no page to describe.
          final number = int.tryParse(activator.trigger.keyLabel);
          if (number != null && number > destinations) continue;
          expect(
            shown,
            contains(desktopShortcutLabel(activator, platform)),
            reason: '${activator.trigger.keyLabel} is not listed',
          );
        }
        expect(find.text('Play/Pause'), findsOneWidget);
        expect(
          find.text(
            desktopShortcutLabel(
              desktopCommandShortcut(DesktopCommand.settings, platform)!,
              platform,
            ),
          ),
          findsNothing,
          reason: 'Settings lists its command and destination in one row',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
