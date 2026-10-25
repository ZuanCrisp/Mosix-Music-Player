import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/services/app_remote_config_service.dart';
import 'package:mosix/services/update_checker.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';
import 'package:mosix/widgets/app_announcement_dialog.dart';
import 'package:mosix/widgets/app_bottom_sheet.dart';
import 'package:mosix/widgets/app_choice_chip.dart';
import 'package:mosix/widgets/mornye_chrome.dart';
import 'package:mosix/widgets/update_dialog.dart';

Widget _app(ThemeData theme, Widget home) => ProviderScope(
  child: MaterialApp(
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

void main() {
  for (final mornye in [false, true]) {
    for (final brightness in Brightness.values) {
      final theme = mornye
          ? MornyeTheme.build(brightness)
          : ThemeData(brightness: brightness);
      final variant = 'Mornye: $mornye, $brightness';

      testWidgets('sheet selects, disables and returns values ($variant)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var selected = false;
        var disabledTaps = 0;
        bool? result;
        await tester.pumpWidget(
          _app(
            theme,
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Open'),
                  onPressed: () async {
                    result = await showAppBottomSheet<bool>(
                      context: context,
                      title: 'Library filter',
                      builder: (context) => StatefulBuilder(
                        builder: (context, setSheetState) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Wrap(
                              children: [
                                AppChoiceChip(
                                  label: const Text('Downloaded tracks'),
                                  selected: selected,
                                  onSelected: (value) => setSheetState(() {
                                    selected = value;
                                  }),
                                ),
                              ],
                            ),
                            AppSheetOption(
                              enabled: false,
                              title: const Text('Unavailable'),
                              onTap: () => disabledTaps++,
                            ),
                            AppSheetOption(
                              title: const Text('Apply'),
                              onTap: () => Navigator.pop(context, selected),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          find.byType(MornyeGlassPanel),
          mornye ? findsOneWidget : findsNothing,
        );
        expect(find.byType(M3EChip), mornye ? findsNothing : findsOneWidget);
        await tester.tap(find.text('Unavailable'));
        expect(disabledTaps, 0);
        await tester.tap(find.text('Downloaded tracks'));
        await tester.pumpAndSettle();
        expect(selected, isTrue);
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(result, isTrue);
        expect(find.text('Library filter'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('nested dialog retains theme and navigation ($variant)', (
        tester,
      ) async {
        final nestedNavigator = GlobalKey<NavigatorState>();
        bool? result;
        await tester.pumpWidget(
          _app(
            ThemeData(),
            Navigator(
              key: nestedNavigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Theme(
                  data: theme,
                  child: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        child: const Text('Open import'),
                        onPressed: () async {
                          result = await showAppDialog<bool>(
                            context: context,
                            useRootNavigator: false,
                            builder: (context) => AppAlertDialog(
                              title: const Text('Import playlist'),
                              actions: [
                                AppDialogAction(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Confirm'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open import'));
        await tester.pumpAndSettle();
        expect(nestedNavigator.currentState!.canPop(), isTrue);
        expect(
          find.byType(MornyeGlassPanel),
          mornye ? findsOneWidget : findsNothing,
        );
        expect(
          Theme.of(tester.element(find.text('Import playlist'))).brightness,
          brightness,
        );
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(result, isTrue);
        expect(nestedNavigator.currentState!.canPop(), isFalse);
        expect(find.text('Open import'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('available update can be dismissed ($variant)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(393, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          _app(
            theme,
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Update'),
                  onPressed: () => showUpdateDialog(
                    context,
                    updateInfo: UpdateInfo(
                      version: '9.0.0',
                      changelog: 'Playback and library improvements.\n' * 8,
                      downloadUrl: 'https://example.com/release',
                      publishedAt: DateTime(2026),
                    ),
                    onDisableUpdates: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Update'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(5, 5));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(UpdateDialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('announcement keeps explicit dismissal (Mornye: $mornye)', (
      tester,
    ) async {
      var dismissals = 0;
      await tester.pumpWidget(
        _app(
          mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open notice'),
                onPressed: () => showAppAnnouncementDialog(
                  context,
                  announcement: const RemoteAnnouncement(
                    id: 'notice',
                    enabled: true,
                    title: 'Service notice',
                    message: 'An announcement without an external action.',
                    dismissible: false,
                  ),
                  onDismiss: () => dismissals++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open notice'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Service notice'), findsOneWidget);
      expect(dismissals, 0);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Service notice'), findsNothing);
      expect(dismissals, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
