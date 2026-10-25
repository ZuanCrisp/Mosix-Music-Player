import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mosix/models/track.dart';
import 'package:mosix/models/unified_library_item.dart';
import 'package:mosix/providers/download_queue_provider.dart';
import 'package:mosix/services/library_database.dart';
import 'package:mosix/services/music_player_service.dart';

final musicPlayerRuntimeProvider = Provider<MusicPlayerRuntime>(
  (ref) => musicPlayerRuntime,
);

final currentMediaItemProvider = StreamProvider<MediaItem?>((ref) {
  return ref.watch(musicPlayerRuntimeProvider).mediaItemEvents();
});

/// Use the Library's identity for favorites, including restored queues and
/// playback started from a file path rather than a Library row ID.
final playerCollectionTrackProvider = FutureProvider.autoDispose
    .family<Track, MediaItem>((ref, item) async {
      final source = item.extras?['source']?.toString() ?? '';
      if (source.isNotEmpty) {
        final history = await ref
            .read(downloadHistoryProvider.notifier)
            .getByFilePathAsync(source);
        if (history != null) {
          return UnifiedLibraryItem.fromDownloadHistory(history).toTrack();
        }
      }
      final database = ref
          .watch(musicPlayerRuntimeProvider)
          .dependencies
          .libraryDatabase;
      final row = await database.getById(item.id);
      if (row != null) {
        return UnifiedLibraryItem.fromLocalLibrary(
          LocalLibraryItem.fromJson(row),
        ).toTrack();
      }
      if (source.isNotEmpty) {
        final matches = await database.findByTrackAndArtist(
          item.title,
          item.artist ?? '',
        );
        for (final row in matches) {
          final local = LocalLibraryItem.fromJson(row);
          if (local.filePath == source) {
            return UnifiedLibraryItem.fromLocalLibrary(local).toTrack();
          }
        }
      }
      return Track(
        id: item.id,
        name: item.title,
        artistName: item.artist ?? '',
        albumName: item.album ?? '',
        coverUrl: item.artUri?.toString(),
        duration: item.duration?.inSeconds ?? 0,
        source: 'local',
      );
    });

final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  return ref.watch(musicPlayerRuntimeProvider).playbackStateEvents();
});

/// Small derived providers keep position ticks from rebuilding widgets that
/// only care about transport state (and vice versa).
final playbackPositionProvider = Provider<Duration>((ref) {
  return ref.watch(
    playbackStateProvider.select(
      (state) => state.value?.position ?? Duration.zero,
    ),
  );
});

final playbackPlayingProvider = Provider<bool>((ref) {
  return ref.watch(
    playbackStateProvider.select((state) => state.value?.playing ?? false),
  );
});

final playbackLoadingProvider = Provider<bool>((ref) {
  return ref.watch(
    playbackStateProvider.select((state) {
      final processingState = state.value?.processingState;
      return processingState == AudioProcessingState.loading ||
          processingState == AudioProcessingState.buffering;
    }),
  );
});

/// Transport state for one media item. Non-current Library cells only watch
/// the current media ID; the active cell additionally follows play/loading so
/// a transport toggle does not rebuild the entire Library grid.
/// Release each cell's subscription when it scrolls out of the Library.
final mediaItemPlaybackUiProvider = Provider.autoDispose
    .family<({bool isCurrent, bool isPlaying, bool isLoading}), String>((
      ref,
      mediaId,
    ) {
      final currentId = ref.watch(
        currentMediaItemProvider.select((state) => state.value?.id),
      );
      if (mediaId.isEmpty || currentId != mediaId) {
        return (isCurrent: false, isPlaying: false, isLoading: false);
      }
      return (
        isCurrent: true,
        isPlaying: ref.watch(playbackPlayingProvider),
        isLoading: ref.watch(playbackLoadingProvider),
      );
    });

final playQueueProvider = StreamProvider<List<MediaItem>>((ref) {
  return ref.watch(musicPlayerRuntimeProvider).queueEvents();
});

class MusicPlayerController {
  MusicPlayerController({MusicPlayerRuntime? runtime})
    : _runtime = runtime ?? musicPlayerRuntime;

  final MusicPlayerRuntime _runtime;

  MusicPlayerHandler? get _handler => _runtime.handler;

  DateTime? get sleepTimerEndsAt => _handler?.sleepTimerEndsAt;

  Future<MusicPlayerHandler?> ensureInitialized() async {
    try {
      return await _runtime.initialize();
    } catch (_) {
      return null;
    }
  }

  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    final handler = await ensureInitialized();
    await handler?.setQueueAndPlay(items, initialIndex: initialIndex);
  }

  Future<void> playSingle(PlayableMedia item) => playAll([item]);

  Future<void> playHistory(
    List<DownloadHistoryItem> items, {
    int initialIndex = 0,
  }) async {
    final media = items
        .where((i) => i.filePath.trim().isNotEmpty)
        .map(playableFromHistory)
        .toList();
    if (media.isEmpty) return;
    await playAll(media, initialIndex: initialIndex.clamp(0, media.length - 1));
  }

  Future<void> playLocal(
    List<LocalLibraryItem> items, {
    int initialIndex = 0,
  }) async {
    final media = items
        .where((i) => i.filePath.trim().isNotEmpty)
        .map(playableFromLocal)
        .toList();
    if (media.isEmpty) return;
    await playAll(media, initialIndex: initialIndex.clamp(0, media.length - 1));
  }

  Future<({LocalLibraryItem item, List<LocalLibraryItem> tracks})?>
  localAlbumFor(String mediaId) async {
    final database = _runtime.dependencies.libraryDatabase;
    final row = await database.getById(mediaId);
    if (row == null) return null;
    final item = LocalLibraryItem.fromJson(row);
    final rows = await database.getQueueLocalAlbumTracksByKey(item.albumKey);
    final tracks = rows.map(LocalLibraryItem.fromJson).toList(growable: false);
    return tracks.isEmpty ? null : (item: item, tracks: tracks);
  }

  Future<bool> shuffleLibrary() async {
    final rows = await _runtime.dependencies.libraryDatabase.getAll();
    final media = rows
        .map(LocalLibraryItem.fromJson)
        .where((item) => item.filePath.trim().isNotEmpty)
        .map(playableFromLocal)
        .toList();
    if (media.isEmpty) return false;
    final handler = await _runtime.initialize();
    media.shuffle();
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    await handler.setQueueAndPlay(media);
    return true;
  }

  Future<void> play() async => _handler?.play();
  Future<void> pause() async => _handler?.pause();
  Future<void> stop() async => _handler?.stop();
  Future<void> seek(Duration position) async => _handler?.seek(position);
  Future<void> next() async => _handler?.skipToNext();
  Future<void> previous() async => _handler?.skipToPrevious();

  void setSleepTimer(Duration duration) => _handler?.setSleepTimer(duration);

  void cancelSleepTimer() => _handler?.cancelSleepTimer();

  Future<void> togglePlayPause(bool isPlaying) async {
    final handler = _handler;
    if (handler == null) return;
    final processingState = handler.playbackState.value.processingState;
    if (processingState == AudioProcessingState.loading ||
        processingState == AudioProcessingState.buffering) {
      return;
    }
    if (isPlaying) {
      await handler.pause();
    } else {
      await handler.play();
    }
  }

  Future<void> setShuffle(bool enabled) async {
    await _handler?.setShuffleMode(
      enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
    );
  }

  Future<void> setRepeatMode(AudioServiceRepeatMode mode) async =>
      _handler?.setRepeatMode(mode);

  Future<void> playNext(PlayableMedia item) async =>
      (await ensureInitialized())?.enqueue(item, playNext: true);

  Future<void> addToQueue(PlayableMedia item) async =>
      (await ensureInitialized())?.enqueue(item);

  Future<void> enqueueLibraryItems(
    List<UnifiedLibraryItem> items, {
    bool playNext = false,
  }) async {
    final media = [
      for (final item in items)
        if (item.localItem != null)
          playableFromLocal(item.localItem!)
        else if (item.historyItem != null)
          playableFromHistory(item.historyItem!),
    ];
    await (await ensureInitialized())?.enqueueAll(media, playNext: playNext);
  }

  Future<void> playNextHistory(DownloadHistoryItem item) async =>
      playNext(playableFromHistory(item));

  Future<void> addToQueueHistory(DownloadHistoryItem item) async =>
      addToQueue(playableFromHistory(item));

  Future<void> playNextLocal(LocalLibraryItem item) async =>
      playNext(playableFromLocal(item));

  Future<void> addToQueueLocal(LocalLibraryItem item) async =>
      addToQueue(playableFromLocal(item));

  Future<void> jumpTo(int index) async => _handler?.skipToQueueItem(index);

  void moveQueueItem(int oldIndex, int newIndex) {
    _handler?.moveQueueItem(oldIndex, newIndex);
  }

  void removeQueuedItem(MediaItem item) => _handler?.removeQueuedItem(item);
}

final musicPlayerControllerProvider = Provider<MusicPlayerController>(
  (ref) =>
      MusicPlayerController(runtime: ref.watch(musicPlayerRuntimeProvider)),
);

PlayableMedia playableFromHistory(DownloadHistoryItem item) {
  return PlayableMedia(
    id: item.id,
    source: item.filePath,
    title: item.trackName,
    artist: item.artistName,
    album: item.albumName,
    artUri: (item.coverUrl != null && item.coverUrl!.trim().isNotEmpty)
        ? item.coverUrl
        : null,
    duration: (item.duration != null && item.duration! > 0)
        ? Duration(seconds: item.duration!)
        : null,
    bitDepth: item.bitDepth,
    sampleRate: item.sampleRate,
    bitrate: item.bitrate,
    format: item.format,
    explicit: item.explicit,
    genre: item.genre,
  );
}

PlayableMedia playableFromLocal(LocalLibraryItem item) {
  String? art;
  final cover = item.coverPath;
  if (cover != null && cover.trim().isNotEmpty) {
    art = cover.startsWith('http') || cover.startsWith('content://')
        ? cover
        : Uri.file(cover).toString();
  }
  return PlayableMedia(
    id: item.id,
    source: item.filePath,
    title: item.trackName,
    artist: item.artistName,
    album: item.albumName,
    artUri: art,
    duration: (item.duration != null && item.duration! > 0)
        ? Duration(seconds: item.duration!)
        : null,
    bitDepth: item.bitDepth,
    sampleRate: item.sampleRate,
    bitrate: item.bitrate,
    format: item.format,
    explicit: item.explicit,
    genre: item.genre,
  );
}
