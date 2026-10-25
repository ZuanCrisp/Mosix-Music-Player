import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/music_player_service.dart';

PlayableMedia track(
  String id, {
  String artist = 'Artist',
  String? genre,
  String? source,
}) => PlayableMedia(
  id: id,
  source: source ?? '/$id.flac',
  title: id,
  artist: artist,
  genre: genre,
);

class _NoNoise implements Random {
  @override
  double nextDouble() => 0;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

void main() {
  test('Autoplay prefers related unplayed Library tracks and deduplicates', () {
    final seed = track('seed', genre: 'Rock');
    final related = track('related', genre: 'Rock');
    final recent = track('recent', genre: 'Rock');
    final selected = selectAutoplayTracks(
      seed: seed,
      candidates: [
        seed,
        related,
        related,
        recent,
        track('unrelated', artist: 'Other'),
        track('queued'),
        track('dismissed'),
        track('remote', source: 'https://example.com/audio.flac'),
        track('related', source: '/copy.flac', genre: 'Rock'),
      ],
      upcoming: [track('queued')],
      recent: [recent],
      dismissedSources: {'/dismissed.flac'},
      random: Random(1),
    );
    expect(selected.map((item) => item.id), ['related', 'unrelated', 'recent']);
  });

  test('a small Library never recommends the current song to itself', () {
    final seed = track('only');
    expect(
      selectAutoplayTracks(
        seed: seed,
        candidates: [seed],
        upcoming: [],
        recent: [seed],
        dismissedSources: {},
        random: Random(1),
      ),
      isEmpty,
    );
  });

  test('recency uses the latest source or normalized song match', () {
    final source = track('source-match', artist: 'A', source: '/same.flac');
    final song = track(' Song ', artist: ' ARTIST ');
    final older = track('older', artist: 'D');
    final unplayed = track('new', artist: 'E');
    final selected = selectAutoplayTracks(
      seed: track('seed', artist: 'Seed'),
      candidates: [source, song, older, unplayed],
      upcoming: [],
      recent: [
        track('source-match', artist: ' a ', source: '/copy.flac'),
        older,
        track(' song ', artist: 'artist', source: '/other.flac'),
        track('renamed', artist: 'different', source: '/same.flac'),
      ],
      dismissedSources: {},
      random: _NoNoise(),
    );
    expect(selected, [unplayed, older, song, source]);
  });

  test('bounded ranking retains its seeded ordering with a full history', () {
    PlayableMedia song(int id) => PlayableMedia(
      id: '$id',
      source: '/music/$id.flac',
      title: ' Song $id ',
      artist: ' Artist ${id % 24} ',
      album: ' Album ${id % 35} ',
      genre: ' Genre ${id % 8} ',
    );
    final selected = selectAutoplayTracks(
      seed: song(1000),
      candidates: List.generate(384, song),
      upcoming: [song(16), song(17)],
      recent: List.generate(200, (i) => song(i + 192)),
      dismissedSources: {'/music/18.flac'},
      random: Random(1),
    );
    expect(selected.map((item) => item.id), [
      '160',
      '40',
      '96',
      '80',
      '90',
      '20',
    ]);
  });

  test('Autoplay preference and recommendation provenance survive restore', () {
    expect(AppSettings.fromJson({}).autoplay, isFalse);
    final settings = const AppSettings().copyWith(autoplay: true);
    expect(AppSettings.fromJson(settings.toJson()).autoplay, isTrue);
    final media = PlayableMedia.fromJson({
      ...track('one', genre: 'Rock').toJson(),
      'autoplay': true,
    })!;
    final restored = PlayableMedia.fromJson(media.toJson())!;
    expect(restored.autoplay, isTrue);
    expect(restored.genre, 'Rock');
    expect(restored.toMediaItem().extras?['autoplay'], isTrue);
  });
}
