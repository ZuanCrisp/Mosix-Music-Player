import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/system_volume_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:volume_controller/volume_controller.dart';

final usbVolumeProvider = StreamProvider.autoDispose<UsbVolumeState?>((ref) {
  final events = StreamController<UsbVolumeState?>();
  void changed() => events.add(usbHardwareVolume.value);
  usbHardwareVolume.addListener(changed);
  changed();
  ref.onDispose(() {
    usbHardwareVolume.removeListener(changed);
    unawaited(events.close());
  });
  return events.stream;
});

/// A single shared subscription for the visible player, including hardware
/// volume-button changes. This controls system volume, not ReplayGain gain.
/// Desktop controls the in-app output gain of every deck instead.
final systemVolumeProvider = StreamProvider.autoDispose<double>(
  (ref) => SystemVolumeService.instance.changes,
);

final systemVolumeWriterProvider = Provider<Future<void> Function(double)>((
  ref,
) {
  return (value) {
    if (isDesktopPlatform) {
      playbackOutputVolume.value = value.clamp(0, 1).toDouble();
      return Future.value();
    }
    if (usbHardwareVolume.value != null) return setUsbHardwareVolume(value);
    final volume = VolumeController.instance;
    volume.showSystemUI = false;
    return volume.setVolume(value.clamp(0, 1));
  };
});
