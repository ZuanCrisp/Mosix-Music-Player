import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/batch_track_actions.dart';
import 'package:mornye/widgets/app_action_button.dart';

void main() {
  testWidgets(
    'batch conversion keeps a valid context after its launcher is removed',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: _BatchConvertHarness(),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('open-batch-convert')));
      await tester.pumpAndSettle();

      final convertButton = find.widgetWithText(
        AppActionButton,
        'Convert 1 track',
      );
      await tester.scrollUntilVisible(
        convertButton,
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(convertButton);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.textContaining('Original files will be deleted'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _BatchConvertHarness extends ConsumerStatefulWidget {
  const _BatchConvertHarness();

  @override
  ConsumerState<_BatchConvertHarness> createState() =>
      _BatchConvertHarnessState();
}

class _BatchConvertHarnessState extends ConsumerState<_BatchConvertHarness> {
  bool _showLauncher = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _showLauncher
          ? Builder(
              builder: (launcherContext) => FilledButton(
                key: const Key('open-batch-convert'),
                onPressed: () => showBatchConvertSheet(
                  launcherContext,
                  ref,
                  [
                    UnifiedLibraryItem(
                      id: 'track-1',
                      trackName: 'Track',
                      artistName: 'Artist',
                      albumName: 'Album',
                      filePath: '/music/track.flac',
                      addedAt: DateTime(2026),
                      source: LibraryItemSource.local,
                    ),
                  ],
                  onExitSelectionMode: () {},
                  onSheetOpen: () => setState(() => _showLauncher = false),
                ),
                child: const Text('Open'),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
