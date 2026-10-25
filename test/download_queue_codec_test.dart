import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/download_queue_codec.dart';

DownloadItem _item(
  int index, {
  DownloadStatus status = DownloadStatus.queued,
}) => DownloadItem(
  id: 'queue:$index',
  track: Track(
    id: 'example:$index',
    name: 'Song $index',
    artistName: 'Artist 日本語',
    albumName: 'Album',
    duration: 1000,
    comment: 'Exact metadata — $index',
    availability: const ServiceAvailability(deezer: true),
  ),
  service: 'extension.example',
  status: status,
  createdAt: DateTime.utc(2026).add(Duration(seconds: index)),
  networkDownloadFolder: 'Albums',
  qualityOverride: 'HI_RES',
  preserveQualityVariant: true,
  playlistName: 'Playlist',
  playlistPosition: index + 1,
  fromBatch: true,
);

class _IsolateProbeTrack extends Track {
  const _IsolateProbeTrack({super.comment})
    : super(
        id: 'example:probe',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1000,
      );

  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'encoded_on': Isolate.current.debugName,
  };
}

class _ThrowingTrack extends Track {
  const _ThrowingTrack()
    : super(
        id: 'example:failure',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1000,
      );

  @override
  Map<String, dynamic> toJson() => throw StateError('fixture codec failure');
}

String? _encodedIsolate(String payload) {
  final decoded = jsonDecode(payload) as Map<String, dynamic>;
  final track = decoded['track'] as Map<String, dynamic>;
  return track['encoded_on'] as String?;
}

void main() {
  test(
    'ordinary serialization stays inline; a large batch uses a worker',
    () async {
      final item = _item(0).copyWith(track: const _IsolateProbeTrack());
      final inline = await encodeDownloadQueueItems([item]);
      final worker = await encodeDownloadQueueItems(List.filled(64, item));
      expect(_encodedIsolate(inline.single), Isolate.current.debugName);
      for (final payload in worker) {
        expect(_encodedIsolate(payload), 'download-queue-persist');
      }
    },
  );

  test('chunked serialization preserves exact bytes and order', () async {
    final items = List.generate(
      2100,
      (index) =>
          _item(
            index,
            status: DownloadStatus.values[index % DownloadStatus.values.length],
          ).copyWith(
            progress: .7,
            speedMBps: 8,
            bytesReceived: 70,
            bytesTotal: 100,
            preparationStage: 'metadata',
          ),
    );
    expect(
      await encodeDownloadQueueItems(items),
      items.map(encodeDownloadQueueItemForPersistence).toList(),
    );
  });

  test(
    'a failed later worker chunk releases its wait and allows retry',
    () async {
      final items = List.generate(2100, (index) => _item(index));
      items[1500] = items[1500].copyWith(track: const _ThrowingTrack());
      await expectLater(
        encodeDownloadQueueItems(items).timeout(const Duration(seconds: 10)),
        throwsA(
          isA<RemoteError>().having(
            (error) => error.toString(),
            'message',
            contains('_ThrowingTrack'),
          ),
        ),
      );
      items[1500] = _item(1500);
      expect(
        await encodeDownloadQueueItems(items),
        items.map(encodeDownloadQueueItemForPersistence).toList(),
      );
    },
  );

  test(
    'chunked restore keeps repair IDs, statuses, ordering, and cache identity',
    () async {
      final items = List.generate(2100, (index) => _item(index));
      final rows = <Map<String, dynamic>>[
        for (final item in items)
          {
            'id': item.id,
            'status': item.status.name,
            'item_json': encodeDownloadQueueItemForPersistence(item),
          },
        {'id': 'corrupt', 'status': 'queued', 'item_json': '{broken'},
        {'id': 'invalid', 'status': 'queued', 'item_json': '[]'},
        {'id': '', 'status': 'queued', 'item_json': '{}'},
        {
          'id': 'active',
          'status': 'downloading',
          'item_json': jsonEncode(
            _item(
              2100,
              status: DownloadStatus.downloading,
            ).copyWith(id: 'active', progress: .9).toJson(),
          ),
        },
        {
          'id': 'terminal',
          'status': 'completed',
          'item_json': jsonEncode(
            _item(
              2101,
              status: DownloadStatus.completed,
            ).copyWith(id: 'terminal').toJson(),
          ),
        },
      ];
      var eventLoopResumed = false;
      Timer.run(() => eventLoopResumed = true);
      final restored = await decodeDownloadQueueRows(rows);
      expect(eventLoopResumed, isTrue);
      expect(restored.items.map((item) => item.id), [
        ...items.map((item) => item.id),
        'active',
      ]);
      expect(restored.items.last.status, DownloadStatus.queued);
      expect(restored.items.last.progress, 0);
      for (var index = 0; index < items.length; index++) {
        final item = restored.items[index];
        final saved = restored.saved[item.id]!;
        expect(identical(saved.item, item), isTrue);
        expect(
          saved.payload,
          encodeDownloadQueueItemForPersistence(items[index]),
        );
        expect(item.track.comment, items[index].track.comment);
        expect(item.track.availability!.deezer, isTrue);
      }
      expect(restored.saved['corrupt'], (item: null, payload: null));
      expect(restored.saved['invalid'], (item: null, payload: null));
      expect(restored.saved[''], (item: null, payload: null));
      expect(restored.saved['active']!.payload, isNull);
      expect(
        restored.saved['terminal']!.item!.status,
        DownloadStatus.completed,
      );
    },
  );

  test(
    'a single large payload also yields JSON hydration to a worker',
    () async {
      final item = _item(0).copyWith(
        track: _item(0).track.copyWith(comment: List.filled(70000, 'x').join()),
      );
      var eventLoopResumed = false;
      Timer.run(() => eventLoopResumed = true);
      final restored = await decodeDownloadQueueRows([
        {
          'id': item.id,
          'status': item.status.name,
          'item_json': encodeDownloadQueueItemForPersistence(item),
        },
      ]);
      expect(eventLoopResumed, isTrue);
      expect(restored.items.single.track.comment, item.track.comment);
    },
  );

  test('a single large metadata field serializes in a worker', () async {
    final item = _item(0).copyWith(
      track: _IsolateProbeTrack(comment: List.filled(70000, 'x').join()),
    );
    final encoded = await encodeDownloadQueueItems([item]);
    expect(_encodedIsolate(encoded.single), 'download-queue-persist');
    final decoded = jsonDecode(encoded.single) as Map<String, dynamic>;
    final track = decoded['track'] as Map<String, dynamic>;
    expect(track['comment'], item.track.comment);
  });
}
