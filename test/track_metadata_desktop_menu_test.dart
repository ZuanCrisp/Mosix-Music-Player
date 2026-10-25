import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/app_icon_finder.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const ffmpegEvents = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    messenger.setMockMethodCallHandler(ffmpegEvents, (_) async => null);
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'safStat' => jsonEncode({'exists': true, 'size': 100}),
        'readAudioMetadata' => '{}',
        'readFileMetadata' => jsonEncode({'audio_codec': 'flac'}),
        'getLyricsLRCWithSource' => jsonEncode({'lyrics': ''}),
        'extractCoverToFile' => jsonEncode({'error': 'No cover'}),
        'getSafFileModTimes' => '{}',
        _ => null,
      },
    );
  });

  tearDown(() {
    debugDesktopPlatformOverride = null;
    messenger.setMockMethodCallHandler(ffmpegEvents, null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  for (final desktop in [true, false]) {
    testWidgets(
      'Material song page More button opens a ${desktop ? 'menu' : 'sheet'}',
      (tester) async {
        debugDesktopPlatformOverride = desktop;
        tester.view.physicalSize = desktop
            ? const Size(1200, 800)
            : const Size(900, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [extensionProvider.overrideWith(_Extensions.new)],
            child: MaterialApp(
              theme: AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: TrackMetadataScreen(
                item: DownloadHistoryItem(
                  id: 'local-song',
                  trackName: 'Song',
                  artistName: 'Artist',
                  albumName: 'Album',
                  filePath: 'content://library/document/song.flac',
                  service: 'example-provider',
                  downloadedAt: DateTime(2026),
                  format: 'flac',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(findAppIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        // Items that do not depend on the file being readable, since the
        // desktop backend library is absent under flutter test.
        expect(find.text('Copy file path'), findsOneWidget);
        expect(find.text('Go to Artist'), findsOneWidget);
        if (desktop) {
          expect(find.byType(MenuItemButton), findsWidgets);
          expect(find.byType(BottomSheet), findsNothing);
          final button = tester.getRect(findAppIcon(Icons.more_vert));
          final menu = tester.getRect(find.byType(MenuItemButton).first);
          expect(menu.top, greaterThanOrEqualTo(button.bottom - 1));
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
        } else {
          expect(find.byType(BottomSheet), findsOneWidget);
          expect(find.byType(MenuItemButton), findsNothing);
        }
      },
    );
  }
}
