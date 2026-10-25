import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/models/unified_library_item.dart';
import 'package:mosix/providers/download_queue_provider.dart';
import 'package:mosix/providers/library_collections_provider.dart';
import 'package:mosix/providers/local_library_provider.dart';
import 'package:mosix/providers/music_player_provider.dart';
import 'package:mosix/providers/settings_provider.dart';
import 'package:mosix/screens/library_tracks_folder_screen.dart';
import 'package:mosix/services/library_collections_database.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/theme/app_theme.dart';
import 'package:mosix/theme/mornye_theme.dart';
import 'package:mosix/utils/desktop_platform.dart';
import 'package:mosix/widgets/track_card.dart';

import 'support/fixed_settings.dart';

class _Database extends Fake implements LibraryCollectionsDatabase {
  final loved = <String, Map<String, dynamic>>{};

  @override
  Future<bool> migrateFromSharedPreferences() async => false;

  @override
  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) async {
    loved[trackKey] = {
      'track_key': trackKey,
      'track_json': trackJson,
      'added_at': addedAt,
    };
  }

  @override
  Future<LibraryCollectionsSnapshot> loadSnapshot() async =>
      LibraryCollectionsSnapshot(
        wishlistRows: const [],
        lovedRows: loved.values.toList(),
        favoriteArtistRows: const [],
        playlistRows: const [],
        playlistTrackRows: const [],
      );
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

void main() {
  for (final mornye in [false, true]) {
    testWidgets('Liked Songs reopens with local artwork (Mosix: $mornye)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final directory = await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp('liked-cover-');
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(32, 32);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        await File(
          '${directory.path}/cover.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        return directory;
      });
      final local = UnifiedLibraryItem.fromLocalLibrary(
        LocalLibraryItem(
          id: 'local-song',
          trackName: 'Local song',
          artistName: 'Local artist',
          albumName: 'Local album',
          filePath: 'content://library/local-song.flac',
          coverPath: '${directory!.path}/cover.png',
          duration: 180,
          scannedAt: DateTime.utc(2026),
        ),
      ).toTrack();
      final downloaded = UnifiedLibraryItem.fromDownloadHistory(
        DownloadHistoryItem(
          id: 'downloaded-song',
          trackName: 'Downloaded song',
          artistName: 'Downloaded artist',
          albumName: 'Downloaded album',
          filePath: '/downloads/song.flac',
          service: 'example',
          downloadedAt: DateTime.utc(2026),
        ),
      ).toTrack();
      final database = _Database();
      final container = ProviderContainer(
        overrides: [
          libraryCollectionsProvider.overrideWith(
            () => LibraryCollectionsNotifier(database: database),
          ),
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          localLibraryProvider.overrideWith(_Library.new),
          downloadHistoryProvider.overrideWith(_History.new),
          downloadHistoryVisibleBatchExistsProvider.overrideWith(
            (ref, request) => const {},
          ),
          localLibraryCoverProvider.overrideWith((ref, request) async => null),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(null),
          ),
        ],
      );
      try {
        final collections = container.read(libraryCollectionsProvider.notifier);
        await collections.toggleLoved(downloaded);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: mornye
                  ? MosixTheme.build(Brightness.light)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => const LibraryTracksFolderScreen(
                          mode: LibraryTracksFolderMode.loved,
                        ),
                      ),
                    ),
                    child: const Text('Open Liked Songs'),
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void> open() async {
          await tester.tap(find.text('Open Liked Songs'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        await open();
        expect(find.text('Downloaded song'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await collections.toggleLoved(local);
        // Reload the persisted JSON so the test also covers reopening after
        // collection hydration, rather than only the in-memory addition.
        container.invalidate(libraryCollectionsProvider);
        await open();
        expect(container.read(libraryCollectionsProvider).loved, hasLength(2));
        expect(find.text('Local song'), findsOneWidget);
        expect(find.text('Downloaded song'), findsOneWidget);
        expect(find.byType(TrackCard), findsNWidgets(2));
        await tester.pageBack();
        await tester.pumpAndSettle();
        await open();
        expect(find.text('Local song'), findsOneWidget);
        expect(find.text('Downloaded song'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    });
  }
}
