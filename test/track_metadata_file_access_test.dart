import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';

void main() {
  const channel = MethodChannel('com.zarz.mornye/backend');

  for (final mornye in [false, true]) {
    for (final unavailable in [false, true]) {
      testWidgets('file status distinguishes provider errors from absence '
          '(Mornye=$mornye, unavailable=$unavailable)', (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 780));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'safStat') {
            if (unavailable) {
              throw PlatformException(code: 'provider_unavailable');
            }
            return {'exists': false};
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final item = DownloadHistoryItem(
          id: 'provider-track',
          trackName: 'Track',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: 'content://provider/music/track.flac',
          service: 'provider-a',
          downloadedAt: DateTime(2026),
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: mornye
                  ? MornyeTheme.build(Brightness.dark)
                  : ThemeData.dark(useMaterial3: true),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: TrackMetadataScreen(item: item),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('File not found'),
          unavailable ? findsNothing : findsOneWidget,
        );
        expect(
          find.text(
            'File is currently unavailable. Check storage access and try again.',
          ),
          unavailable ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
