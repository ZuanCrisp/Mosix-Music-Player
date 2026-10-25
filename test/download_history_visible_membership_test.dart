import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/services/history_database.dart';

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();

  void publish(DownloadHistoryState Function(DownloadHistoryState) update) =>
      state = update(state);
}

const _older = HistoryLookupRequest(
  spotifyId: 'older-track',
  trackName: 'Older song',
  artistName: 'Example artist',
);
const _completed = HistoryLookupRequest(
  spotifyId: 'completed-track',
  trackName: 'Completed song',
  artistName: 'Example artist',
);
const _unrelated = HistoryLookupRequest(
  spotifyId: 'unrelated-track',
  trackName: 'Unrelated song',
  artistName: 'Example artist',
);
const _request = HistoryBatchLookupRequest([_older, _completed]);

DownloadHistoryItem _item(HistoryLookupRequest lookup) => DownloadHistoryItem(
  id: lookup.spotifyId,
  spotifyId: lookup.spotifyId,
  trackName: lookup.trackName,
  artistName: lookup.artistName,
  albumName: 'Example album',
  filePath: '/music/${lookup.spotifyId}.flac',
  service: 'example-provider',
  downloadedAt: DateTime.utc(2026),
);

void main() {
  test(
    'unchanged membership skips unrelated history and revision updates',
    () async {
      final history = _History();
      final databaseProvider = downloadHistoryBatchExistsProvider(_request);
      var queries = 0;
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(() => history),
          databaseProvider.overrideWith((ref) {
            ref.watch(
              downloadHistoryProvider.select((s) => s.loadedIndexVersion),
            );
            queries++;
            return queries == 1
                ? {_older.lookupKey, _completed.lookupKey}
                : {_completed.lookupKey, _older.lookupKey};
          }),
        ],
      );
      addTearDown(container.dispose);
      final provider = downloadHistoryVisibleBatchExistsProvider(_request);
      final notifications = <Set<String>>[];
      final subscription = container.listen(
        provider,
        (_, next) => notifications.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final expected = {_older.lookupKey, _completed.lookupKey};
      expect(notifications, [expected]);
      expect(queries, 1);

      history.publish(
        (s) => s.copyWith(
          items: [_item(_unrelated)],
          lookupItems: [_item(_unrelated)],
          totalCount: 1,
        ),
      );
      await container.pump();
      expect(container.read(provider), expected);
      expect(notifications, hasLength(1));
      expect(queries, 1);

      history.publish((s) => s.copyWith(totalCount: 20));
      await container.pump();
      expect(notifications, hasLength(1));

      history.publish((s) => s.copyWith(loadedIndexVersion: 1));
      await container.pump();
      expect(queries, 2);
      expect(container.read(provider), expected);
      expect(notifications, hasLength(1));
    },
  );

  test(
    'matching completion and removal notify before the revision changes',
    () async {
      final history = _History();
      var queries = 0;
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(() => history),
          downloadHistoryBatchExistsProvider(_request).overrideWith((ref) {
            ref.watch(
              downloadHistoryProvider.select((s) => s.loadedIndexVersion),
            );
            queries++;
            return <String>{};
          }),
        ],
      );
      addTearDown(container.dispose);
      final provider = downloadHistoryVisibleBatchExistsProvider(_request);
      final notifications = <Set<String>>[];
      final subscription = container.listen(
        provider,
        (_, next) => notifications.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      expect(notifications, [<String>{}]);

      history.publish(
        (s) => s.copyWith(
          items: [_item(_completed)],
          lookupItems: [_item(_completed)],
          totalCount: 1,
        ),
      );
      expect(container.read(provider), {_completed.lookupKey});
      await container.pump();
      expect(notifications, [
        <String>{},
        {_completed.lookupKey},
      ]);

      history.publish(
        (s) => s.copyWith(items: [], lookupItems: [], totalCount: 0),
      );
      expect(container.read(provider), isEmpty);
      await container.pump();
      expect(notifications, [
        <String>{},
        {_completed.lookupKey},
        <String>{},
      ]);
      expect(container.read(downloadHistoryProvider).loadedIndexVersion, 0);
      expect(queries, 1);
    },
  );

  for (final refresh in [false, true]) {
    test('retains database keys while loading (refresh=$refresh)', () async {
      final history = _History();
      final databaseProvider = downloadHistoryBatchExistsProvider(_request);
      final response = Completer<Set<String>>();
      addTearDown(() {
        if (!response.isCompleted) response.complete(<String>{});
      });
      var queries = 0;
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(() => history),
          databaseProvider.overrideWith((ref) {
            ref.watch(
              downloadHistoryProvider.select((s) => s.loadedIndexVersion),
            );
            queries++;
            return queries == 1 ? {_older.lookupKey} : response.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      final provider = downloadHistoryVisibleBatchExistsProvider(_request);
      final notifications = <Set<String>>[];
      final subscription = container.listen(
        provider,
        (_, next) => notifications.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      expect(notifications, [
        {_older.lookupKey},
      ]);

      if (refresh) {
        container.invalidate(databaseProvider);
      } else {
        history.publish((s) => s.copyWith(loadedIndexVersion: 1));
      }
      await container.pump();
      final loading = container.read(databaseProvider);
      expect(loading.isLoading, isTrue);
      expect(loading.isRefreshing, refresh);
      expect(loading.isReloading, !refresh);
      expect(queries, 2);
      expect(container.read(provider), {_older.lookupKey});
      expect(notifications, hasLength(1));

      history.publish(
        (s) => s.copyWith(
          items: [_item(_completed)],
          lookupItems: [_item(_completed)],
          totalCount: 1,
        ),
      );
      expect(container.read(provider), {
        _older.lookupKey,
        _completed.lookupKey,
      });
      await container.pump();
      expect(notifications, [
        {_older.lookupKey},
        {_older.lookupKey, _completed.lookupKey},
      ]);

      response.complete(<String>{});
      await container.read(databaseProvider.future);
      await container.pump();
      expect(container.read(provider), {_completed.lookupKey});
      expect(notifications, [
        {_older.lookupKey},
        {_older.lookupKey, _completed.lookupKey},
        {_completed.lookupKey},
      ]);
      expect(queries, 2);
    });
  }
}
