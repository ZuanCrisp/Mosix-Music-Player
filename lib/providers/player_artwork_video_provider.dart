import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:video_player/video_player.dart';

/// The mini player prepares the current offline cover, paused and silent.
/// The full player borrows it so opening the route does not restart decoding.
final playerArtworkVideoProvider = FutureProvider.autoDispose
    .family<VideoPlayerController, String>((ref, source) async {
      final uri = Uri.parse(source);
      if (uri.scheme != 'file') {
        throw ArgumentError('Player artwork must be saved locally');
      }
      final controller = VideoPlayerController.file(
        File.fromUri(uri),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      Future<void>? disposal;
      Future<void> disposeController() => disposal ??= controller.dispose();
      ref.onDispose(() => unawaited(disposeController()));
      try {
        await controller.initialize();
        if (!ref.mounted) return controller;
        await controller.setVolume(0);
        if (!ref.mounted) return controller;
        await controller.setLooping(true);
        return controller;
      } catch (_) {
        unawaited(disposeController());
        rethrow;
      } finally {
        await restoreMusicAudioSessionAfterVideo();
      }
    });
