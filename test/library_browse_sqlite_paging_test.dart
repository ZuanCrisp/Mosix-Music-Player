import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/services/library_queue_store.dart';

import 'support/fixed_settings.dart';
import 'support/library_paging_fixture.dart';
import 'support/sqlite_process_database.dart';

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;
  late LibraryQueueStore store;
  setUp(() async {
    db = await SqliteProcessDatabase.open();
    store = await createLibraryPagingFixture(db);
  });
  tearDown(() => db.close());

  test(
    '1000 albums preserve source ties, dedup, filters and order on paging',
    () async {
      for (final scenario in [
        (
          artists: false,
          sort: 'a-z',
          search: '',
          artist: null,
          completeness: null,
        ),
        (
          artists: false,
          sort: 'latest',
          search: '',
          artist: null,
          completeness: null,
        ),
        (
          artists: true,
          sort: 'a-z',
          search: '',
          artist: null,
          completeness: null,
        ),
        (
          artists: false,
          sort: 'a-z',
          search: 'Album 00',
          artist: null,
          completeness: null,
        ),
        (
          artists: false,
          sort: 'latest',
          search: '',
          artist: 'Artist 0001',
          completeness: null,
        ),
        (
          artists: false,
          sort: 'a-z',
          search: '',
          artist: null,
          completeness: incompleteAlbumFilter,
        ),
        (
          artists: false,
          sort: 'latest',
          search: 'Album',
          artist: null,
          completeness: unknownAlbumCompletenessFilter,
        ),
      ]) {
        final request = (
          artists: scenario.artists,
          sort: scenario.sort,
          search: scenario.search,
          artist: scenario.artist,
          completeness: scenario.completeness,
          limit: 40,
        );
        final reads = <LibraryBrowsePageRequest>[];
        var returned = 0;
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(
                const AppSettings(localLibraryEnabled: true),
              ),
            ),
            downloadHistoryProvider.overrideWith(_History.new),
            localLibraryProvider.overrideWith(_Local.new),
            libraryBrowsePageLoaderProvider.overrideWithValue((page) async {
              reads.add(page);
              final result = await readLibraryPagingFixture(store, page);
              returned += result.entries.length;
              return result;
            }),
          ],
        );
        try {
          final provider = libraryBrowseProvider(request);
          container.listen(provider, (_, _) {});
          await container.read(provider.future);
          final notifier = container.read(provider.notifier);
          while (container.read(provider).requireValue.hasMore) {
            await notifier.loadMore();
            expect(container.read(provider).requireValue.loadMoreError, isNull);
          }
          final actual = container.read(provider).requireValue.entries;
          final expected = await readLibraryPagingFixture(store, (
            browse: (
              artists: request.artists,
              sort: request.sort,
              search: request.search,
              artist: request.artist,
              completeness: request.completeness,
              limit: 2000,
            ),
            offset: 0,
            cursor: null,
            includeLocal: true,
          ));
          expect(
            libraryPagingIdentities(actual),
            libraryPagingIdentities(expected.entries),
            reason: '$scenario',
          );
          expect(
            returned,
            actual.length,
            reason: 'every row is transferred once',
          );
          expect(reads.every((page) => page.browse.limit == 40), true);
          expect(
            actual.every(
              (entry) => entry.trackCount == (request.artists ? 4 : 2),
            ),
            true,
            reason: 'mirrors and unavailable source must not increase counts',
          );
          if (!request.artists &&
              request.search.isEmpty &&
              request.artist == null &&
              request.completeness == null) {
            expect(actual, hasLength(1000));
            expect(reads.skip(1).every((page) => page.cursor != null), true);
          }
        } finally {
          container.dispose();
        }
      }
    },
  );
}
