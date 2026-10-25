import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() => debugDesktopPlatformOverride = null);

  testWidgets('desktop artist singles shelf pages with hover arrows', (
    tester,
  ) async {
    debugDesktopPlatformOverride = true;
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final singles = [
      for (var i = 0; i < 24; i++)
        ArtistAlbum(
          id: 'single-$i',
          name: 'Single $i',
          releaseDate: '2020',
          totalTracks: 1,
          albumType: 'single',
          artists: 'Example Artist',
        ),
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ArtistScreen(
            artistId: 'example-artist',
            artistName: 'Example Artist',
            albums: singles,
            // Supplied top tracks keep the screen from fetching again.
            topTracks: const [
              Track(
                id: 'example-song',
                name: 'Example Song',
                artistName: 'Example Artist',
                albumName: 'Example Album',
                duration: 180,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    final first = find.text('Single 0');
    expect(first, findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(first));
    await tester.pump();

    final forward = find.byTooltip('Scroll forward');
    expect(forward, findsOneWidget);
    expect(find.byTooltip('Scroll back'), findsNothing);
    await tester.tap(forward);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // A page moves the first single past the list's cache extent.
    expect(first, findsNothing);
    expect(find.byTooltip('Scroll back'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
