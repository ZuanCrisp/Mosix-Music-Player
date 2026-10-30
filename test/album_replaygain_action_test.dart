import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/download_history_provider.dart';
import 'package:mosix/screens/downloaded_album_screen.dart';
import 'package:mosix/screens/local_album_screen.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/theme/app_theme.dart';
import 'package:mosix/theme/mosix_theme.dart';
import 'package:mosix/widgets/app_alert_dialog.dart';
import 'package:mosix/widgets/selection_bottom_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zuancrisp.mosix/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final mosix in [false, true]) {
    for (final downloaded in [false, true]) {
      for (final remove in [false, true]) {
        testWidgets(
          'ReplayGain survives hiding the album selection (Mosix: $mosix, downloaded: $downloaded, remove: $remove)',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            var attempts = 0;
            messenger.setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'safCopyToTemp') attempts++;
              // Simulate an inaccessible file. Reaching this call and showing
              // the result proves confirmation actually starts the operation.
              return null;
            });
            addTearDown(
              () => messenger.setMockMethodCallHandler(channel, null),
            );
            const path = 'content://library/document/track.flac';
            final item = DownloadHistoryItem(
              id: 'track',
              trackName: 'Track',
              artistName: 'Artist',
              albumName: 'Album',
              filePath: path,
              service: 'provider-a',
              downloadedAt: DateTime(2026),
            );
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  downloadedAlbumTracksProvider(
                    const DownloadedAlbumTracksRequest(
                      albumName: 'Album',
                      artistName: 'Artist',
                    ),
                  ).overrideWith((ref) async => [item]),
                ],
                child: MaterialApp(
                  theme: mosix
                      ? MosixTheme.build(Brightness.light)
                      : AppTheme.light(),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: SelectionOverlayHost(
                    child: downloaded
                        ? const DownloadedAlbumScreen(
                            albumName: 'Album',
                            artistName: 'Artist',
                          )
                        : LocalAlbumScreen(
                            albumName: 'Album',
                            artistName: 'Artist',
                            tracks: [
                              LocalLibraryItem(
                                id: 'track',
                                trackName: 'Track',
                                artistName: 'Artist',
                                albumName: 'Album',
                                filePath: path,
                                scannedAt: DateTime(2026),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(find.text('Track'), 200);
            await tester.longPress(find.text('Track'));
            await tester.pumpAndSettle();
            final l10n = AppLocalizations.of(
              tester.element(find.byType(SelectionBottomBar)),
            );
            Future<void> openConfirmation() async {
              final action = find.text(
                remove
                    ? l10n.selectionRemoveReplayGainCount(1)
                    : l10n.selectionReplayGainCount(1),
              );
              await tester.ensureVisible(action);
              await tester.tap(action);
              await tester.pumpAndSettle();
              expect(find.byType(SelectionBottomBar), findsNothing);
              expect(find.byType(AppAlertDialog), findsOneWidget);
            }

            await openConfirmation();
            await tester.tap(find.text(l10n.dialogCancel));
            await tester.pumpAndSettle();
            expect(attempts, 0);
            expect(find.byType(SelectionBottomBar), findsOneWidget);

            await openConfirmation();
            await tester.tap(
              find.descendant(
                of: find.byType(AppDialogAction),
                matching: find.text(
                  remove
                      ? l10n.trackRemoveReplayGain
                      : l10n.replayGainBatchConfirmTitle,
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(attempts, 1);
            expect(
              find.text(
                remove
                    ? l10n.replayGainRemoveBatchSuccess(0, 1)
                    : l10n.replayGainBatchSuccess(0, 1),
              ),
              findsOneWidget,
            );
            expect(find.byType(SelectionBottomBar), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
