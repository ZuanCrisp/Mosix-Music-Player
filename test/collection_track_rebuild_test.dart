import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/download_item.dart';
import 'package:mosix/models/track.dart';
import 'package:mosix/providers/download_queue_provider.dart';
import 'package:mosix/providers/library_collections_provider.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/recent_access_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/screens/album_screen.dart';
import 'package:mosix/screens/playlist_screen.dart';
import 'package:mosix/theme/app_theme.dart';
import 'package:mosix/theme/mosix_theme.dart';
import 'package:mosix/widgets/album_detail_header.dart';
import 'package:mosix/widgets/track_list_tile.dart';
import 'package:mosix/widgets/track_detail_actions.dart';

import 'support/fixed_settings.dart';

const _track = Track(
  id: 'example-track',
  name: 'Example song',
  artistName: 'Example artist',
  albumName: 'Example album',
  duration: 180,
);

class _Collections extends LibraryCollectionsNotifier {
  var _batchCalls = 0;
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);

  CollectionTrackEntry get _entry => CollectionTrackEntry(
    key: trackCollectionKey(_track),
    track: _track,
    addedAt: DateTime.utc(2026),
  );

  void publishWishlist() => state = state.copyWith(wishlist: [_entry]);
  void publishLoved() => state = state.copyWith(loved: [_entry]);

  @override
  Future<({bool removed, int count})> toggleLovedTracks(
    Iterable<Track> tracks,
  ) async {
    _batchCalls++;
    final removed = state.loved.isNotEmpty;
    state = state.copyWith(loved: removed ? [] : [_entry]);
    return (removed: removed, count: 1);
  }
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);

  @override
  void recordAlbumAccess({
    required String id,
    required String name,
    String? artistName,
    String? imageUrl,
    String? providerId,
  }) {}
}

Widget _app(ProviderContainer container, Widget child, {bool mosix = false}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: mosix ? MosixTheme.build(Brightness.light) : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    'queue progress leaves track rows untouched but membership updates',
    (tester) async {
      var lookup = const DownloadQueueLookup.empty();
      final snapshot = Provider<DownloadQueueLookup>((ref) => lookup);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(null),
          ),
          downloadQueueLookupProvider.overrideWith(
            (ref) => ref.watch(snapshot),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _app(
          container,
          TrackListTile(
            track: _track,
            isInHistory: false,
            onDownload: ({bool forceQualityPicker = false}) {},
            leading: const Text('1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var builds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is TrackListTile) builds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      var item = DownloadItem(
        id: 'example-download',
        track: _track,
        service: 'example-provider',
        createdAt: DateTime.utc(2026),
      );
      Future<void> publish() async {
        lookup = DownloadQueueLookup.fromItems([item]);
        container.invalidate(snapshot);
        await tester.pump();
      }

      await publish();
      expect(builds, 1);
      builds = 0;
      for (var tick = 1; tick <= 30; tick++) {
        item = item.copyWith(
          progress: tick / 30,
          bytesReceived: tick * 1024,
          status: DownloadStatus.downloading,
        );
        await publish();
      }
      expect(builds, 0);
      lookup = const DownloadQueueLookup.empty();
      container.invalidate(snapshot);
      await tester.pump();
      expect(builds, 1);
      expect(find.text('Example song'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final mosix in [false, true]) {
    testWidgets(
      'Love All action keeps its add/remove feedback in Mosix=$mosix',
      (tester) async {
        final collections = _Collections();
        final container = ProviderContainer(
          overrides: [
            libraryCollectionsProvider.overrideWith(() => collections),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _app(
            container,
            Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => loveAllTracks(context, ref, [_track]),
                child: const Text('Apply'),
              ),
            ),
            mosix: mosix,
          ),
        );
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        final context = tester.element(find.text('Apply'));
        expect(
          find.text(context.l10n.snackbarAddedTracksToLoved(1)),
          findsOneWidget,
        );
        ScaffoldMessenger.of(context).removeCurrentSnackBar();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(
          find.text(context.l10n.snackbarRemovedTracksFromLoved(1)),
          findsOneWidget,
        );
        expect(collections._batchCalls, 2);
        expect(tester.takeException(), isNull);
      },
    );

    for (final album in [false, true]) {
      testWidgets('Love All isolates the $album page in Mosix=$mosix', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(430, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final collections = _Collections();
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            libraryCollectionsProvider.overrideWith(() => collections),
            recentAccessProvider.overrideWith(_Recent.new),
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => Stream.value(null),
            ),
            downloadQueueLookupProvider.overrideWithValue(
              const DownloadQueueLookup.empty(),
            ),
            downloadHistoryVisibleBatchExistsProvider.overrideWith(
              (ref, request) => const <String>{},
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _app(
            container,
            album
                ? const AlbumScreen(
                    albumId: 'example-album',
                    albumName: 'Example album',
                    tracks: [_track],
                  )
                : const PlaylistScreen(
                    playlistName: 'Example playlist',
                    tracks: [_track],
                  ),
            mosix: mosix,
          ),
        );
        await tester.pumpAndSettle();
        var pageBuilds = 0;
        var actionBuilds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (element.widget is AlbumScreen ||
              element.widget is PlaylistScreen) {
            pageBuilds++;
          }
          if (element.widget is HeaderCircleButton) actionBuilds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);
        collections.publishWishlist();
        await tester.pumpAndSettle();
        expect(pageBuilds, 0);
        expect(actionBuilds, 0);
        collections.publishLoved();
        await tester.pumpAndSettle();
        expect(pageBuilds, 0);
        expect(actionBuilds, greaterThan(0));
        final context = tester.element(find.byType(HeaderCircleButton).first);
        expect(
          find.byTooltip(context.l10n.trackOptionRemoveFromLoved),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
