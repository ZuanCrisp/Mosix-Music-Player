import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/playback_provider.dart';
import 'package:mosix/screens/local_album_screen.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/theme/app_theme.dart';
import 'package:mosix/theme/mosix_theme.dart';
import 'package:mosix/utils/desktop_platform.dart';
import 'package:mosix/widgets/album_track_tile.dart';
import 'package:mosix/widgets/desktop/desktop_selection.dart';
import 'package:mosix/widgets/desktop/track_table.dart';
import 'package:mosix/widgets/mosix_context_menu.dart';
import 'package:mosix/widgets/selection_bottom_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Player extends MusicPlayerController {
  @override
  Future<void> setShuffle(bool enabled) async {}
}

class _Playback extends PlaybackController {
  final started = <String>[];

  @override
  Future<void> playLocalLibraryQueue(
    List<LocalLibraryItem> items, {
    required LocalLibraryItem startItem,
  }) async {
    started.add(startItem.id);
  }
}

final _tracks = [
  for (final (number, name) in [(1, 'Bravo'), (2, 'Alpha'), (3, 'Charlie')])
    LocalLibraryItem(
      id: '$number',
      trackName: name,
      artistName: 'Artist',
      albumName: 'Album',
      filePath: '/music/$name.flac',
      trackNumber: number,
      duration: 60 * (4 - number),
      scannedAt: DateTime(2026),
    ),
];

Future<_Playback> _pumpAlbum(WidgetTester tester, {bool mosix = false}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final playback = _Playback();
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) => const Stream.empty(),
        ),
        playbackPlayingProvider.overrideWith((ref) => false),
        musicPlayerControllerProvider.overrideWithValue(_Player()),
        playbackProvider.overrideWith(() => playback),
      ],
      child: MaterialApp(
        theme: mosix ? MosixTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorKey: navigator,
        home: const SizedBox(),
      ),
    ),
  );
  // Opened from another page, as from the Library, so it has a way back.
  navigator.currentState!.push(
    MaterialPageRoute<void>(
      builder: (_) => LocalAlbumScreen(
        albumName: 'Album',
        artistName: 'Artist',
        tracks: _tracks,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return playback;
}

Future<void> _click(WidgetTester tester, Finder finder, {int buttons = 1}) =>
    tester
        .startGesture(
          tester.getCenter(finder),
          kind: PointerDeviceKind.mouse,
          buttons: buttons,
        )
        .then((gesture) => gesture.up());

void main() {
  setUp(DesktopDoubleClick.reset);
  tearDown(() => debugDesktopPlatformOverride = null);

  testWidgets('phones keep the album track tiles', (tester) async {
    debugDesktopPlatformOverride = false;
    await _pumpAlbum(tester);
    expect(find.byType(AlbumTrackTile), findsNWidgets(3));
    expect(find.byType(SliverTrackTable), findsNothing);
  });

  for (final mosix in [false, true]) {
    testWidgets('desktop album lists songs in a table (mosix: $mosix)', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      final playback = await _pumpAlbum(tester, mosix: mosix);
      expect(find.byType(AlbumTrackTile), findsNothing);
      expect(find.byType(SliverTrackTable), findsOneWidget);

      // A right-click opens the long-press actions, the selection bar's, as
      // a menu on the row, without the bar under it.
      await _click(tester, find.text('Charlie'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      final menu = mosix
          ? find.byType(MosixContextMenu)
          : find.ancestor(
              of: find.byType(MenuItemButton).first,
              matching: find.byType(MenuAnchor),
            );
      expect(menu, findsOneWidget);
      expect(
        find.descendant(of: menu, matching: find.text('Play next')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: menu, matching: find.textContaining('Delete')),
        findsOneWidget,
      );
      expect(find.byType(SelectionBottomBar), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byType(mosix ? MosixContextMenu : MenuItemButton),
        findsNothing,
      );
      expect(find.byType(SelectionBottomBar), findsNothing);
      expect(find.text('Play next'), findsNothing);

      // A click plays the row, as a tap does on a phone, and the second
      // click of a double click does not play it again.
      await _click(tester, find.text('Alpha'));
      await tester.pump();
      await _click(tester, find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(playback.started, ['2']);
      expect(find.text('Play next'), findsNothing);

      await _click(tester, find.text('Charlie'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(mosix ? MosixContextMenu : MenuItemButton),
          matching: find.text('Play'),
        ),
      );
      await tester.pumpAndSettle();
      expect(playback.started, ['2', '3']);
      expect(find.byType(SelectionBottomBar), findsNothing);
    });

    testWidgets('desktop selection bar stays bounded (mosix: $mosix)', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      await _pumpAlbum(tester, mosix: mosix);

      final toggle = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(toggle);
      await _click(tester, find.text('Alpha'));
      await tester.sendKeyUpEvent(toggle);
      await tester.pumpAndSettle();

      // The bar's ends sit inside a 640pt column centered on the page.
      final close = tester.getRect(
        find.descendant(
          of: find.byType(SelectionBottomBar),
          matching: find.byTooltip(
            const DefaultMaterialLocalizations().closeButtonTooltip,
          ),
        ),
      );
      final selectAll = tester.getRect(find.text('Select All'));
      expect(close.left, greaterThanOrEqualTo(1280 / 2 - 320));
      expect(selectAll.right, lessThanOrEqualTo(1280 / 2 + 320));
    });

    testWidgets('desktop album header and rows are compact (mosix: $mosix)', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      final playback = await _pumpAlbum(tester, mosix: mosix);

      // No hero: the back control sits at the top of the pane and the
      // details start beside the artwork, at the list's left edge.
      expect(find.byType(FlexibleSpaceBar), findsNothing);
      final back = find.byTooltip(
        const DefaultMaterialLocalizations().backButtonTooltip,
      );
      expect(back, findsOneWidget);
      expect(tester.getTopLeft(back).dy, lessThan(52));
      final row = find
          .ancestor(of: find.text('Alpha'), matching: find.byType(InkWell))
          .first;
      final playAll = find.text('Play').first;
      expect(
        tester.getTopLeft(playAll).dx,
        greaterThan(tester.getTopLeft(row).dx + 200),
      );
      expect(
        tester.getTopLeft(playAll).dy,
        lessThan(tester.getTopLeft(row).dy),
      );
      // The Play button keeps its own width.
      final playButton = find
          .ancestor(
            of: playAll,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is ButtonStyleButton || widget is CupertinoButton,
            ),
          )
          .first;
      expect(tester.getSize(playButton).width, lessThan(200));

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      if (mosix) {
        // Album rows of Apple Music: 46pt, no column headers, the number
        // turns into a play button under the pointer and "More" shows.
        expect(find.text('#'), findsNothing);
        expect(tester.getSize(row).height, 46);
        final more = find.descendant(
          of: row,
          matching: find.byType(AnimatedOpacity),
        );
        double opacity() => tester.widget<AnimatedOpacity>(more).opacity;
        expect(opacity(), 0);
        expect(find.descendant(of: row, matching: find.text('2')), findsOne);
        await mouse.addPointer(location: tester.getCenter(find.text('Alpha')));
        await tester.pumpAndSettle();
        expect(opacity(), 1);
        expect(
          find.descendant(of: row, matching: find.text('2')),
          findsNothing,
        );
        final rowPlay = find.descendant(
          of: row,
          matching: find.byTooltip('Play'),
        );
        await tester.tap(rowPlay);
        await tester.pumpAndSettle();
        expect(playback.started, ['2']);
        return;
      }

      // Material desktop table density (compact, below the touch row), with
      // the row's play button shown on hover.
      expect(tester.getSize(row).height, 44);
      final rowY = tester.getCenter(row).dy;
      final rowPlay = find.ancestor(
        of: find.byWidgetPredicate(
          (widget) => widget is AlbumTrackPlayButton,
          skipOffstage: true,
        ),
        matching: find.byType(AnimatedOpacity),
      );
      final alphaButton = rowPlay.evaluate().firstWhere(
        (element) =>
            ((element.renderObject! as RenderBox)
                        .localToGlobal(Offset.zero)
                        .dy -
                    rowY)
                .abs() <
            30,
      );
      double opacity() => (alphaButton.widget as AnimatedOpacity).opacity;
      expect(opacity(), 0);
      await mouse.addPointer(location: tester.getCenter(find.text('Alpha')));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
    });
  }
}
