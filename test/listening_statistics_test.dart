import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_statistics.dart';

const _one = ListeningTrack(
  key: 'one',
  title: 'One',
  artist: 'Artist',
  album: 'Album',
);
const _two = ListeningTrack(
  key: 'two',
  title: 'Two',
  artist: 'Artist',
  album: 'Album',
);

void main() {
  test(
    'counts elapsed playback once, excluding pauses and seek-like updates',
    () async {
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 2).add(elapsed),
      );
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 20);
      recorder.update(_one, playing: false);
      elapsed += const Duration(minutes: 10);
      recorder.update(_one, playing: true);
      // A seek can cause a state update but cannot create elapsed listening.
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 20);
      await recorder.flush();
      expect(writes.single.milliseconds, 40000);
      expect(writes.single.plays, 1);
      elapsed += const Duration(seconds: 40);
      await recorder.flush();
      expect(writes.last.milliseconds, 40000);
      expect(writes.last.plays, 0);
    },
  );

  test(
    'track changes and repeat completion start a new counted play',
    () async {
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 2),
      );
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 35);
      recorder.update(_one, playing: false, ended: true);
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 35);
      recorder.update(_two, playing: true);
      elapsed += const Duration(seconds: 10);
      await recorder.flush();
      expect(writes.first.plays, 2);
      expect(writes.first.milliseconds, 70000);
      expect(writes.last.plays, 0);
      expect(writes.last.milliseconds, 10000);
    },
  );

  test('splits midnight and excludes disabled collection', () async {
    var elapsed = Duration.zero;
    final start = DateTime(2026, 10, 1, 23, 59, 50);
    final writes = <ListeningDelta>[];
    final recorder = ListeningRecorder(
      write: (batch) async => writes.addAll(batch),
      elapsed: () => elapsed,
      now: () => start.add(elapsed),
    );
    recorder.update(_one, playing: true);
    elapsed += const Duration(seconds: 20);
    recorder.setEnabled(false);
    elapsed += const Duration(hours: 1);
    await recorder.flush();
    expect(writes.map((e) => e.day), ['2026-10-01', '2026-10-02']);
    expect(writes.map((e) => e.milliseconds), [10000, 10000]);
  });

  test(
    'retries failed writes without dropping or double-counting deltas',
    () async {
      var elapsed = Duration.zero;
      var fail = true;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async {
          if (fail) throw StateError('temporary database error');
          writes.addAll(batch);
        },
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 2),
      );
      recorder.update(_one, playing: true);
      elapsed += const Duration(seconds: 30);
      await recorder.flush();
      fail = false;
      elapsed += const Duration(seconds: 10);
      await recorder.flush();
      expect(writes.single.milliseconds, 40000);
      expect(writes.single.plays, 1);
    },
  );

  test('clear waits for in-flight writes and drops failed retries', () async {
    var elapsed = Duration.zero;
    final blockedWrite = Completer<void>();
    final started = Completer<void>();
    final writes = <ListeningDelta>[];
    var firstWrite = true;
    var cleared = false;
    final recorder = ListeningRecorder(
      write: (batch) async {
        if (firstWrite) {
          firstWrite = false;
          started.complete();
          await blockedWrite.future;
          throw StateError('write interrupted');
        }
        writes.addAll(batch);
      },
      elapsed: () => elapsed,
      now: () => DateTime(2026, 10, 2),
    );
    recorder.update(_one, playing: true);
    elapsed += const Duration(seconds: 35);
    final flushing = recorder.flush();
    await started.future;
    final clearing = recorder.clear(() async => cleared = true);
    expect(cleared, isFalse);
    elapsed += const Duration(seconds: 20);
    final duringClear = recorder.flush();
    blockedWrite.complete();
    await flushing;
    await clearing;
    await duringClear;
    expect(cleared, isTrue);
    elapsed += const Duration(seconds: 30);
    await recorder.flush();
    expect(writes.single.milliseconds, 30000);
    expect(writes.single.plays, 1);
  });

  test('summary merges days for the same track and credits artists once', () {
    final summary = ListeningSummary.fromRows([
      for (final day in ['2026-10-01', '2026-10-02'])
        {
          'day': day,
          'track_key': 'one',
          'title': 'One',
          'artist': 'Artist',
          'album': 'Album',
          'artwork': null,
          'milliseconds': 60000,
          'plays': 1,
        },
    ]);
    expect(summary.milliseconds, 120000);
    expect(summary.plays, 2);
    expect(summary.tracks.single.milliseconds, 120000);
    expect(summary.artists, {'Artist': 120000});
    expect(summary.days.length, 2);
  });

  test(
    'artist artwork uses the most listened track with an available cover',
    () {
      final summary = ListeningSummary(
        tracks: [
          ListeningTotal(_one, 180000, 3),
          ListeningTotal(
            const ListeningTrack(
              key: 'other',
              title: 'Other',
              artist: 'Other Artist',
              album: 'Other Album',
              artwork: 'https://example.com/other.jpg',
            ),
            60000,
            1,
          ),
          ListeningTotal(
            const ListeningTrack(
              key: 'less',
              title: 'Less',
              artist: 'Artist',
              album: 'Another Album',
              artwork: 'https://example.com/less.jpg',
            ),
            30000,
            1,
          ),
          ListeningTotal(
            const ListeningTrack(
              key: 'more',
              title: 'More',
              artist: 'Artist',
              album: 'Album',
              artwork: ' file:///covers/album.jpg ',
            ),
            120000,
            2,
          ),
        ],
      );
      expect(summary.artistArtwork, {
        'Artist': 'file:///covers/album.jpg',
        'Other Artist': 'https://example.com/other.jpg',
      });
      expect(
        ListeningSummary(
          tracks: [ListeningTotal(_one, 60000, 1)],
        ).artistArtwork,
        isEmpty,
      );
    },
  );
}
