import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/album_replaygain_readiness.dart';

import 'support/album_replaygain_benchmark.dart';

DownloadItem _item(String album, DownloadStatus status, {String? albumId}) =>
    DownloadItem(
      id: '$album-${status.name}',
      track: Track(
        id: 'shared-track-id',
        name: 'Song',
        artistName: 'Artist & Guest',
        albumName: album,
        albumId: albumId,
        albumArtist: 'Artist',
        duration: 180,
      ),
      service: 'example',
      createdAt: DateTime.utc(2026),
      status: status,
    );

void main() {
  test('album identity keeps ID precedence and literal case/whitespace', () {
    final track = _item('Album', DownloadStatus.completed).track;
    expect(albumReplayGainKey(track), 'name:Album|Artist');
    expect(
      albumReplayGainKey(track.copyWith(albumId: '')),
      'name:Album|Artist',
    );
    expect(albumReplayGainKey(track.copyWith(albumId: ' ID ')), 'id: ID ');
    expect(
      albumReplayGainKey(track.copyWith(albumName: 'album')),
      'name:album|Artist',
    );
    expect(
      albumReplayGainKey(
        const Track(
          id: 'missing-artist',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 180,
        ),
      ),
      'name:Album|',
    );
    expect(albumReplayGainKey(track.copyWith(albumArtist: '')), 'name:Album|');
  });

  for (final status in DownloadStatus.values) {
    test('$status blocks only its own album until completed', () {
      final target = _item('Target', status);
      final items = [
        _item('Other', DownloadStatus.failed),
        _item('Target', DownloadStatus.completed),
        target,
      ];
      final key = albumReplayGainKey(target.track);
      expect(
        albumReplayGainBlocked(items, key),
        status != DownloadStatus.completed,
      );
      expect(
        readyReplayGainAlbums(items, {key: 2}),
        status == DownloadStatus.completed ? [key] : isEmpty,
      );
      expect(albumReplayGainBlocked(items, 'id:absent'), false);
    });
  }

  test(
    'absent, empty and single-entry accumulators retain their policy/order',
    () {
      final items = [
        _item('Single', DownloadStatus.completed),
        _item('Multiple', DownloadStatus.completed),
        _item('Empty', DownloadStatus.completed),
      ];
      const entries = {
        'id:absent-multiple': 2,
        'name:Single|Artist': 1,
        'id:absent-single': 1,
        'name:Empty|Artist': 0,
        'name:Multiple|Artist': 2,
      };
      expect(readyReplayGainAlbums(items, entries), [
        'id:absent-multiple',
        'name:Single|Artist',
        'name:Multiple|Artist',
      ]);
      expect(readyReplayGainAlbums([], entries), [
        'id:absent-multiple',
        'name:Multiple|Artist',
      ]);
    },
  );

  test(
    'retry, removal and new snapshots change readiness without stale cache',
    () {
      final complete = _item('Album', DownloadStatus.completed);
      final failed = _item('Album', DownloadStatus.failed);
      final key = albumReplayGainKey(complete.track);
      final original = [complete, failed];
      expect(readyReplayGainAlbums(original, {key: 2}), isEmpty);
      expect(readyReplayGainAlbums([complete], {key: 2}), [key]);
      expect(
        readyReplayGainAlbums(
          [complete, failed.copyWith(status: DownloadStatus.queued)],
          {key: 2},
        ),
        isEmpty,
      );
      expect(
        readyReplayGainAlbums(
          [complete, failed.copyWith(status: DownloadStatus.completed)],
          {key: 2},
        ),
        [key],
      );
      expect(readyReplayGainAlbums(original, {key: 2}), isEmpty);
    },
  );

  test(
    'empty accumulator set and first blocker avoid unnecessary iteration',
    () {
      Iterable<DownloadItem> neverRead() sync* {
        throw StateError('No scan should be needed');
      }

      expect(readyReplayGainAlbums(neverRead(), {}), isEmpty);
      final first = _item('Album', DownloadStatus.queued);
      Iterable<DownloadItem> firstOnly() sync* {
        yield first;
        throw StateError('Already blocked');
      }

      expect(
        albumReplayGainBlocked(firstOnly(), albumReplayGainKey(first.track)),
        true,
      );
    },
  );

  test('2000 mixed snapshots match both original decisions exactly', () {
    final random = Random(4817);
    for (var iteration = 0; iteration < 2000; iteration++) {
      final albums = [
        for (var i = 0; i < 15; i++)
          _item(
            'Album ${i % 7}',
            DownloadStatus.completed,
            albumId: i.isEven ? (i % 4 == 0 ? '$i' : ' $i ') : null,
          ).track.copyWith(albumArtist: i % 3 == 0 ? '' : 'Artist ${i % 3}'),
      ];
      final items = List.generate(
        random.nextInt(180),
        (index) => DownloadItem(
          id: '$index',
          track: albums[random.nextInt(albums.length)],
          service: 'example',
          createdAt: DateTime.utc(2026),
          status: DownloadStatus
              .values[random.nextInt(DownloadStatus.values.length)],
        ),
      );
      final entries = <String, int>{
        for (final track in albums)
          legacyAlbumReplayGainKey(track): random.nextInt(4),
        'id:absent-single': 1,
        'id:absent-multiple': 2,
      };
      expect(
        readyReplayGainAlbums(items, entries),
        legacyReadyReplayGainAlbums(items, entries),
      );
      for (final key in entries.keys) {
        expect(
          albumReplayGainBlocked(items, key),
          legacyAlbumReplayGainBlocked(items, key),
        );
      }
    }
  });
}
