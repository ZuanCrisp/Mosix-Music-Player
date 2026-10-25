import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_output_volume.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PlaybackOutputVolumeStore.debugReset();
    playbackOutputVolume.value = 1;
  });
  tearDown(() {
    PlaybackOutputVolumeStore.debugReset();
    playbackOutputVolume.value = 1;
  });

  test('the in-app volume survives a relaunch', () async {
    SharedPreferences.setMockInitialValues({});
    await PlaybackOutputVolumeStore.ensureRestored();
    expect(playbackOutputVolume.value, 1);
    playbackOutputVolume.value = 0.35;
    await PlaybackOutputVolumeStore.debugFlush();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(PlaybackOutputVolumeStore.storageKey), 0.35);

    PlaybackOutputVolumeStore.debugReset();
    playbackOutputVolume.value = 1;
    await PlaybackOutputVolumeStore.ensureRestored();
    expect(playbackOutputVolume.value, 0.35);
  });

  test('restoring is shared and keeps a change made while loading', () async {
    SharedPreferences.setMockInitialValues({
      PlaybackOutputVolumeStore.storageKey: 0.2,
    });
    final first = PlaybackOutputVolumeStore.ensureRestored();
    expect(PlaybackOutputVolumeStore.ensureRestored(), same(first));
    playbackOutputVolume.value = 0.9;
    await first;
    expect(playbackOutputVolume.value, 0.9);
  });

  test('out-of-range saved values are clamped', () async {
    SharedPreferences.setMockInitialValues({
      PlaybackOutputVolumeStore.storageKey: 3.0,
    });
    playbackOutputVolume.value = 0.5;
    await PlaybackOutputVolumeStore.ensureRestored();
    expect(playbackOutputVolume.value, 1);
  });
}
