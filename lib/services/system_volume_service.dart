import 'dart:async';

import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_output_volume.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:volume_controller/volume_controller.dart';

/// The volume plugin owns one listener. Share it between background playback
/// and volume sliders so opening or closing a player cannot replace it.
/// On desktop the stream follows [playbackOutputVolume] instead.
class SystemVolumeService {
  SystemVolumeService({Stream<double>? source}) : _source = source;

  static final SystemVolumeService instance = SystemVolumeService();

  final Stream<double>? _source;
  final Set<MultiStreamController<double>> _listeners = {};
  StreamSubscription<double>? _subscription;
  double? _latest;

  Stream<double> get changes => Stream<double>.multi((listener) {
    _listeners.add(listener);
    if (_latest case final value?) listener.add(value);
    if (_subscription == null) {
      // Desktop never changes the system volume; it reports the in-app gain,
      // restored from the previous launch.
      if (_source == null && isDesktopPlatform) {
        unawaited(PlaybackOutputVolumeStore.ensureRestored());
      }
      final source =
          _source ?? (isDesktopPlatform ? playbackOutputVolumeChanges() : null);
      _subscription = source == null
          ? VolumeController.instance.addListener(_publish)
          : source.listen(_publish);
      _subscription!.onError((Object error, StackTrace stack) {
        for (final listener in _listeners.toList()) {
          listener.addError(error, stack);
        }
      });
    }
    listener.onCancel = () {
      _listeners.remove(listener);
      if (_listeners.isEmpty) {
        _latest = null;
        // Cancel only our subscription; removeListener could cancel a newer
        // plugin subscription while cancellation is still in flight.
        if (_subscription != null) unawaited(_subscription!.cancel());
        _subscription = null;
      }
    };
  });

  void _publish(double value) {
    if (!value.isFinite) return;
    _latest = value.clamp(0, 1);
    for (final listener in _listeners.toList()) {
      listener.add(_latest!);
    }
  }
}
