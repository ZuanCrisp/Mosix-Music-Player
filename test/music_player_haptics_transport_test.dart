import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_player_service.dart';

import 'support/music_player_automix_harness.dart';

const _tracks = testTracks;
const _until = waitUntil;

void main() {
  setUpMusicPlayerHarness();

  group('music haptics transport', () {
    void enableHaptics() => musicPlayerRuntime.configure(
      musicPlayerRuntime.settings.copyWith(musicHaptics: true),
    );

    test('direct documents work without AutoMix resolved metadata', () async {
      enableHaptics();
      const source = 'content://music/document/first.flac';
      handler.mediaItem.add(
        const MediaItem(
          id: 'document',
          title: 'Document',
          extras: {'source': source},
        ),
      );
      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      await _until(() => hapticSongs.isNotEmpty);
      expect(hapticSongs.first, 'document');
      expect(hapticsAnalyzer.paths, [source]);
      // A subsequent AutoMix-style metadata update keeps the same analysis.
      handler.mediaItem.add(
        handler.mediaItem.value!.copyWith(
          extras: {'source': source, 'resolvedSource': '/cache/first.flac'},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(hapticsAnalyzer.paths, [source]);
    });

    for (final autoMix in [false, true]) {
      test(
        'first song and manual skips retain haptics (AutoMix: $autoMix)',
        () async {
          enableHaptics();
          setAutoMixEnabled(autoMix);
          await handler.setQueueAndPlay(_tracks);
          await _until(() => hapticSongs.contains('one'));
          await handler.skipToNext();
          await _until(() => hapticSongs.contains('two'));
          final beforePrevious = hapticSongs.length;
          await handler.skipToPrevious();
          await _until(() => hapticSongs.skip(beforePrevious).contains('one'));
          expect(hapticSongs.last, 'one');
          expect(hapticsAnalyzer.paths, [
            '/one.flac',
            '/two.flac',
            '/one.flac',
          ]);
        },
      );
    }

    test(
      'ordinary completion and a subsequent skip both keep haptics',
      () async {
        enableHaptics();
        await handler.setQueueAndPlay(_tracks);
        await _until(() => hapticSongs.contains('one'));
        await native.event('music-player', 'audio.onComplete');
        await _until(() => hapticSongs.contains('two'));
        await handler.skipToNext();
        await _until(() => hapticSongs.contains('three'));
      },
    );
  });
}
