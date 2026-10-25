import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/services/local_track_batch_actions.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/widgets/app_bottom_sheet.dart';
import 'package:mosix/widgets/re_enrich_review_sheet.dart';
import 'package:mosix/widgets/selection_bottom_bar.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> syncLyricsSettingsToBackend({AppSettings? settings}) async {}
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets('result is readable above an open metadata sheet ($mornye)', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAppBottomSheet<void>(
                    context: context,
                    builder: (sheetContext) => SizedBox(
                      height: 400,
                      child: TextButton(
                        onPressed: () => showReEnrichResultDialog(
                          sheetContext,
                          message: 'Metadata lookup failed',
                        ),
                        child: const Text('Look up metadata'),
                      ),
                    ),
                  ),
                  child: const Text('Open metadata'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open metadata'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Look up metadata'));
      await tester.pumpAndSettle();
      expect(find.text('Metadata lookup failed').hitTestable(), findsOneWidget);
      expect(find.text('Look up metadata').hitTestable(), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Look up metadata').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final fails in [false, true]) {
      testWidgets(
        'empty/failed preview stays visible before selection returns ($mornye/$fails)',
        (tester) async {
          const channel = MethodChannel('com.zuancrisp.mosix/backend');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async {
              expect(call.method, 'reEnrichFile');
              if (fails) throw PlatformException(code: 'lookup_failed');
              return {
                'method': 'preview',
                'enriched_metadata': <String, dynamic>{},
              };
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          final overlay = SelectionOverlayController();
          addTearDown(overlay.hide);
          var restored = 0;
          Future<void>? action;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [settingsProvider.overrideWith(_Settings.new)],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.dark)
                    : ThemeData(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: Consumer(
                    builder: (context, ref, _) => TextButton(
                      onPressed: () {
                        action = reEnrichLocalTracks(
                          context,
                          ref,
                          [
                            LocalLibraryItem(
                              id: 'song',
                              trackName: 'Song',
                              artistName: 'Artist',
                              albumName: 'Album',
                              filePath: '/music/song.flac',
                              scannedAt: DateTime(2026),
                            ),
                          ],
                          isActive: () => true,
                          onSelectionHide: () async => overlay.hide(),
                          onSelectionRestore: () {
                            restored++;
                            overlay.show(
                              context,
                              (_) => const SizedBox(
                                height: 350,
                                child: ColoredBox(
                                  color: Colors.blue,
                                  child: Center(child: Text('Selection card')),
                                ),
                              ),
                            );
                          },
                          onComplete: () => fail('No tags should be applied'),
                        );
                      },
                      child: const Text('Re-enrich song'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Re-enrich song'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Review changes'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Review changes'));
          await tester.pumpAndSettle();
          expect(
            find
                .text('No metadata changes were found for the selected tracks.')
                .hitTestable(),
            findsOneWidget,
          );
          expect(restored, 0);
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          await action;
          expect(restored, 1);
          expect(find.text('Selection card').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
