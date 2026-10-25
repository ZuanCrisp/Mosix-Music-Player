import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/providers/music_player_provider.dart';

void main() {
  test('Library playback state follows only the current media item', () async {
    final container = ProviderContainer(
      overrides: [
        currentMediaItemProvider.overrideWith(
          (ref) =>
              Stream.value(const MediaItem(id: 'track-1', title: 'Track 1')),
        ),
        playbackPlayingProvider.overrideWith((ref) => true),
        playbackLoadingProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(container.dispose);
    final currentMediaSubscription = container.listen(
      currentMediaItemProvider,
      (_, _) {},
    );
    addTearDown(currentMediaSubscription.close);

    await container.read(currentMediaItemProvider.future);

    expect(container.read(mediaItemPlaybackUiProvider('track-1')), (
      isCurrent: true,
      isPlaying: true,
      isLoading: false,
    ));
    expect(container.read(mediaItemPlaybackUiProvider('track-2')), (
      isCurrent: false,
      isPlaying: false,
      isLoading: false,
    ));
  });

  test(
    'Library releases playback state for cells that leave the viewport',
    () async {
      final mediaItems = StreamController<MediaItem?>();
      addTearDown(mediaItems.close);
      final container = ProviderContainer(
        overrides: [
          currentMediaItemProvider.overrideWith((ref) => mediaItems.stream),
          playbackPlayingProvider.overrideWith((ref) => true),
          playbackLoadingProvider.overrideWith((ref) => false),
        ],
      );
      addTearDown(container.dispose);
      final visibleProvider = mediaItemPlaybackUiProvider('visible-track');
      final visibleSubscription = container.listen(visibleProvider, (_, _) {});
      addTearDown(visibleSubscription.close);
      mediaItems.add(
        const MediaItem(id: 'visible-track', title: 'Visible track'),
      );
      await container.read(currentMediaItemProvider.future);

      for (var index = 0; index < 200; index++) {
        final provider = mediaItemPlaybackUiProvider('scrolled-track-$index');
        final subscription = container.listen(provider, (_, _) {});
        expect(container.exists(provider), isTrue);
        subscription.close();
      }
      await container.pump();

      for (var index = 0; index < 200; index++) {
        expect(
          container.exists(
            mediaItemPlaybackUiProvider('scrolled-track-$index'),
          ),
          isFalse,
        );
      }
      expect(container.exists(visibleProvider), isTrue);
      expect(visibleSubscription.read(), (
        isCurrent: true,
        isPlaying: true,
        isLoading: false,
      ));

      mediaItems.add(
        const MediaItem(id: 'scrolled-track-0', title: 'Scrolled track'),
      );
      await container.pump();
      final returningSubscription = container.listen(
        mediaItemPlaybackUiProvider('scrolled-track-0'),
        (_, _) {},
      );
      addTearDown(returningSubscription.close);
      expect(returningSubscription.read(), (
        isCurrent: true,
        isPlaying: true,
        isLoading: false,
      ));
      expect(visibleSubscription.read(), (
        isCurrent: false,
        isPlaying: false,
        isLoading: false,
      ));
    },
  );
}
