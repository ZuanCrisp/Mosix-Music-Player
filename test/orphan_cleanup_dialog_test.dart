import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/app_localizations.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/download_history_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/screens/settings/app_settings_page.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _History extends DownloadHistoryNotifier {
  final cleanup = Completer<int>();

  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<int> cleanupOrphanedDownloads() => cleanup.future;
}

void main() {
  testWidgets('orphan cleanup closes its dialog inside a nested navigator', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final history = _History();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadHistoryProvider.overrideWith(() => history),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // The shell hosts settings pages in a tab navigator.
          home: Navigator(
            onGenerateRoute: (_) =>
                MaterialPageRoute(builder: (_) => const AppSettingsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cleanup Orphaned Downloads'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AppAlertDialog), findsOneWidget);

    history.cleanup.complete(0);
    await tester.pumpAndSettle();

    expect(find.byType(AppAlertDialog), findsNothing);
    expect(find.byType(AppSettingsPage), findsOneWidget);
    expect(find.text('No orphaned entries found'), findsOneWidget);
  });
}
