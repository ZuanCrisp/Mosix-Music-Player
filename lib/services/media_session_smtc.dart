import 'dart:async';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:mornye/utils/logger.dart';
import 'package:smtc_windows/smtc_windows.dart' as smtc;

final _log = AppLogger('Smtc');

/// The System Media Transport Controls calls the session makes. The default
/// wraps smtc_windows; tests substitute a fake.
abstract interface class SmtcControls {
  Stream<smtc.PressedButton> get buttons;
  Future<void> setStatus(smtc.PlaybackStatus status);
  Future<void> setTimeline(smtc.PlaybackTimeline timeline);
  Future<void> setMetadata(smtc.MusicMetadata metadata);
  Future<void> setNextPrevious({required bool next, required bool previous});
}

class _WindowsSmtcControls implements SmtcControls {
  _WindowsSmtcControls(this._smtc);

  static Future<SmtcControls> create() async {
    await smtc.SMTCWindows.initialize();
    return _WindowsSmtcControls(
      smtc.SMTCWindows(
        config: const smtc.SMTCConfig(
          playEnabled: true,
          pauseEnabled: true,
          nextEnabled: true,
          prevEnabled: true,
          stopEnabled: false,
          fastForwardEnabled: false,
          rewindEnabled: false,
        ),
      ),
    );
  }

  final smtc.SMTCWindows _smtc;

  @override
  Stream<smtc.PressedButton> get buttons => _smtc.buttonPressStream;
  @override
  Future<void> setStatus(smtc.PlaybackStatus status) =>
      _smtc.setPlaybackStatus(status);
  @override
  Future<void> setTimeline(smtc.PlaybackTimeline timeline) =>
      _smtc.updateTimeline(timeline);
  @override
  Future<void> setMetadata(smtc.MusicMetadata metadata) =>
      _smtc.updateMetadata(metadata);
  @override
  Future<void> setNextPrevious({required bool next, required bool previous}) {
    final config = _smtc.config;
    if (config.nextEnabled == next && config.prevEnabled == previous) {
      return Future.value();
    }
    return _smtc.updateConfig(
      smtc.SMTCConfig(
        playEnabled: config.playEnabled,
        pauseEnabled: config.pauseEnabled,
        stopEnabled: config.stopEnabled,
        nextEnabled: next,
        prevEnabled: previous,
        fastForwardEnabled: config.fastForwardEnabled,
        rewindEnabled: config.rewindEnabled,
      ),
    );
  }
}

/// The Windows media session: audio_service's platform calls shown in the
/// System Media Transport Controls (media keys, the volume flyout and the
/// lock screen). The controls offer no seek request, so seeking stays in
/// the app.
class SmtcAudioService extends NoOpAudioService {
  SmtcAudioService({Future<SmtcControls> Function()? create})
    : _create = create ?? _WindowsSmtcControls.create;

  final Future<SmtcControls> Function() _create;
  SmtcControls? _controls;
  StreamSubscription<smtc.PressedButton>? _buttons;
  AudioHandlerCallbacks? _callbacks;
  PlaybackStateMessage? _state;
  MediaItemMessage? _item;

  @override
  Future<void> configure(ConfigureRequest request) async {
    if (_controls != null) return;
    try {
      final controls = await _create();
      _controls = controls;
      _buttons = controls.buttons.listen(_pressed);
    } catch (error) {
      _log.w('Media transport controls are unavailable: $error');
    }
  }

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) =>
      _callbacks = callbacks;

  void _pressed(smtc.PressedButton button) {
    final callbacks = _callbacks;
    if (callbacks == null) return;
    final Future<void> action = switch (button) {
      smtc.PressedButton.play => callbacks.play(const PlayRequest()),
      smtc.PressedButton.pause => callbacks.pause(const PauseRequest()),
      smtc.PressedButton.next => callbacks.skipToNext(
        const SkipToNextRequest(),
      ),
      smtc.PressedButton.previous => callbacks.skipToPrevious(
        const SkipToPreviousRequest(),
      ),
      smtc.PressedButton.stop => callbacks.stop(const StopRequest()),
      _ => Future.value(),
    };
    unawaited(
      action.catchError(
        (Object error) => _log.w('Media control ${button.name}: $error'),
      ),
    );
  }

  bool _can(MediaActionMessage action) {
    final state = _state;
    if (state == null) return false;
    return state.systemActions.contains(action) ||
        state.controls.any((control) => control.action == action);
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    _state = request.state;
    final controls = _controls;
    if (controls == null) return;
    final state = request.state;
    final status = state.processingState == AudioProcessingStateMessage.idle
        ? smtc.PlaybackStatus.stopped
        : state.playing
        ? smtc.PlaybackStatus.playing
        : smtc.PlaybackStatus.paused;
    await _guard(() async {
      await controls.setStatus(status);
      await controls.setNextPrevious(
        next: _can(MediaActionMessage.skipToNext),
        previous: _can(MediaActionMessage.skipToPrevious),
      );
      await _publishTimeline(controls);
    });
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    _item = request.mediaItem;
    final controls = _controls;
    if (controls == null) return;
    final item = request.mediaItem;
    await _guard(() async {
      await controls.setMetadata(
        smtc.MusicMetadata(
          title: item.title,
          artist: item.artist,
          album: item.album,
          thumbnail: thumbnailFor(item),
        ),
      );
      await _publishTimeline(controls);
    });
  }

  @override
  Future<void> stopService(StopServiceRequest request) async {
    final controls = _controls;
    if (controls == null) return;
    await _guard(() => controls.setStatus(smtc.PlaybackStatus.stopped));
  }

  Future<void> _publishTimeline(SmtcControls controls) {
    final length = _item?.duration ?? Duration.zero;
    final position = _state?.updatePosition ?? Duration.zero;
    return controls.setTimeline(
      smtc.PlaybackTimeline(
        startTimeMs: 0,
        endTimeMs: length.inMilliseconds,
        positionMs: position.inMilliseconds.clamp(0, length.inMilliseconds),
        minSeekTimeMs: 0,
        maxSeekTimeMs: length.inMilliseconds,
      ),
    );
  }

  /// Artwork the controls can read: the file audio_service cached, or an
  /// http(s) URL. Other schemes would fail to parse in the plugin.
  static String? thumbnailFor(MediaItemMessage item) {
    final cached = item.extras?['artCacheFile'];
    if (cached is String && cached.isNotEmpty) {
      return Uri.file(cached, windows: true).toString();
    }
    final uri = item.artUri;
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      return uri.toString();
    }
    if (uri != null && uri.scheme == 'file') return uri.toString();
    return null;
  }

  Future<void> _guard(Future<void> Function() update) async {
    try {
      await update();
    } catch (error) {
      _log.w('Could not update the media transport controls: $error');
    }
  }

  /// Stops listening, for tests and shutdown.
  Future<void> close() async {
    await _buttons?.cancel();
    _buttons = null;
  }
}
