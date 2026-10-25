import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/system_volume_service.dart';

import 'support/music_player_automix_harness.dart';

const _tracks = testTracks;
const _until = waitUntil;

void main() {
  setUpMusicPlayerHarness();

  group('automatic playback on system volume', () {
    const events = MethodChannel(
      'com.kurenai7968.volume_controller.volume_listener_event',
    );
    late List<String> volumeCalls;

    Future<void> volume(double value) => native.messenger.handlePlatformMessage(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope(value),
      (_) {},
    );

    setUp(() {
      volumeCalls = [];
      native.messenger.setMockMethodCallHandler(events, (call) async {
        volumeCalls.add(call.method);
        return null;
      });
    });

    tearDown(() async {
      setPlaybackAutomationOptions(
        enabled: true,
        pauseOnMute: false,
        playOnHeadphonesConnected: false,
      );
      await Future<void>.delayed(Duration.zero);
      native.messenger.setMockMethodCallHandler(events, null);
    });

    Future<void> enable() async {
      await handler.setQueueAndPlay(_tracks);
      setPlaybackAutomationOptions(
        enabled: true,
        pauseOnMute: true,
        playOnHeadphonesConnected: false,
      );
      await _until(() => volumeCalls.contains('listen'));
      await volume(0.5);
    }

    test(
      'mute pauses the real transport and unmute resumes the same song',
      () async {
        await enable();
        await volume(0);
        await _until(() => !handler.playbackState.value.playing);
        expect(native.playing, isEmpty);
        final current = handler.mediaItem.value!.id;
        await volume(0.5);
        await _until(() => handler.playbackState.value.playing);
        expect(native.playing, {'music-player'});
        expect(handler.mediaItem.value!.id, current);
      },
    );

    test('manual pause cancels automatic resume in the handler', () async {
      await enable();
      await volume(0);
      await _until(() => !handler.playbackState.value.playing);
      await handler.pause();
      await volume(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.playbackState.value.playing, isFalse);
      expect(native.playing, isEmpty);
    });

    test('manual pause wins while unmute resume is awaiting native', () async {
      await enable();
      await volume(0);
      await _until(() => !handler.playbackState.value.playing);
      final resumeCount = native.calls
          .where((call) => call.$2 == 'resume')
          .length;
      native.resumeGate = Completer<void>();
      await volume(0.5);
      await _until(
        () =>
            native.calls.where((call) => call.$2 == 'resume').length >
            resumeCount,
      );
      final paused = handler.pause();
      native.resumeGate!.complete();
      await paused;
      expect(handler.playbackState.value.playing, isFalse);
      expect(native.playing, isEmpty);
    });

    test(
      'changing song during unmute cannot pause the replacement song',
      () async {
        await enable();
        await volume(0);
        await _until(() => !handler.playbackState.value.playing);
        final resumeCount = native.calls
            .where((call) => call.$2 == 'resume')
            .length;
        native.resumeGate = Completer<void>();
        await volume(0.5);
        await _until(
          () =>
              native.calls.where((call) => call.$2 == 'resume').length >
              resumeCount,
        );
        final changed = handler.skipToNext();
        native.resumeGate!.complete();
        await changed;
        expect(handler.mediaItem.value!.id, 'two');
        expect(handler.playbackState.value.playing, isTrue);
        expect(native.playing, {'music-player'});
      },
    );

    test(
      'opening and closing a volume slider preserves the background listener',
      () async {
        await enable();
        final slider = SystemVolumeService.instance.changes.listen((_) {});
        await Future<void>.delayed(Duration.zero);
        await slider.cancel();
        expect(volumeCalls.where((method) => method == 'listen'), hasLength(1));
        expect(volumeCalls, isNot(contains('cancel')));
        await volume(0);
        await _until(() => !handler.playbackState.value.playing);
        expect(native.playing, isEmpty);
      },
    );

    test('USB output bypasses system mute automation', () async {
      await enable();
      setUsbBitPerfectEnabled(true);
      await _until(() => volumeCalls.contains('cancel'));
      await volume(0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.playbackState.value.playing, isTrue);
    });
  });
}
