import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/services/playback_normalization.dart';

void main() {
  test('updated gain replaces the cached volume for the same URI', () async {
    var gain = '-4.00 dB';
    final cache = PlaybackNormalizationCache(
      readMetadata: (_, {displayName}) async => {'replaygain_track_gain': gain},
    );
    const source = 'content://music/song';
    expect(await cache.volumeFor(source), closeTo(0.630957, 0.000001));
    gain = '-12.20 dB';
    cache.invalidate(source);
    expect(await cache.volumeFor(source), closeTo(0.245471, 0.000001));
  });

  test(
    'a read started before an edit cannot restore stale cache data',
    () async {
      final staleRead = Completer<Map<String, dynamic>>();
      var reads = 0;
      final cache = PlaybackNormalizationCache(
        readMetadata: (_, {displayName}) async {
          if (++reads == 1) return staleRead.future;
          return {'replaygain_track_gain': '-12.20 dB'};
        },
      );
      final pending = cache.volumeFor('song');
      cache.invalidate('song');
      await cache.volumeFor('song');
      staleRead.complete({'replaygain_track_gain': '-4.00 dB'});
      await pending;
      expect(await cache.volumeFor('song'), closeTo(0.245471, 0.000001));
      expect(reads, 2);
    },
  );

  test(
    'descriptor normalization uses hint and caches by original URI',
    () async {
      var reads = 0;
      final cache = PlaybackNormalizationCache(
        readMetadata: (path, {displayName}) async {
          reads++;
          expect(path, '/proc/self/fd/42');
          expect(displayName, 'Song.flac');
          return {
            'replaygain_track_gain': '-6.00 dB',
            'replaygain_album_gain': '-3.00 dB',
          };
        },
      );
      expect(
        await cache.volumeFor(
          '/proc/self/fd/42',
          displayName: 'Song.flac',
          cacheKey: 'content://music/song',
        ),
        closeTo(0.501187, 0.000001),
      );
      expect(
        await cache.volumeFor(
          '/proc/self/fd/99',
          displayName: 'Song.flac',
          cacheKey: 'content://music/song',
        ),
        closeTo(0.501187, 0.000001),
      );
      expect(reads, 1);
    },
  );

  test(
    'failed descriptor metadata does not poison local fallback cache',
    () async {
      var reads = 0;
      final cache = PlaybackNormalizationCache(
        readMetadata: (path, {displayName}) async {
          reads++;
          if (path.startsWith('/proc/')) {
            return {'error': 'descriptor access denied'};
          }
          return {'replaygain_album_gain': '-6.00 dB'};
        },
      );
      expect(
        await cache.volumeFor(
          '/proc/self/fd/42',
          displayName: 'Song.mp3',
          cacheKey: 'song',
        ),
        1.0,
      );
      expect(
        await cache.volumeFor('/cache/Song.mp3', cacheKey: 'song'),
        closeTo(0.501187, 0.000001),
      );
      expect(reads, 2);
    },
  );

  test('exceptions are retried and positive gain only attenuates', () async {
    var reads = 0;
    final cache = PlaybackNormalizationCache(
      readMetadata: (path, {displayName}) async {
        if (++reads == 1) throw StateError('temporarily unavailable');
        return {'replaygain_track_gain': '+6.00 dB'};
      },
    );
    expect(await cache.volumeFor('song'), 1.0);
    expect(await cache.volumeFor('song'), 1.0);
    expect(reads, 2);
  });
}
