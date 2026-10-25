import 'dart:async';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/media_session_desktop.dart';
import 'package:mornye/services/media_session_mpris.dart';
import 'package:mornye/services/media_session_smtc.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:smtc_windows/smtc_windows.dart' as smtc;

/// Records each handler callback by request type.
class _Callbacks implements AudioHandlerCallbacks {
  final requests = <Object>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    requests.add(invocation.positionalArguments.single as Object);
    return Future<void>.value();
  }
}

class _Controls implements SmtcControls {
  final buttonEvents = StreamController<smtc.PressedButton>.broadcast();
  final statuses = <smtc.PlaybackStatus>[];
  final timelines = <smtc.PlaybackTimeline>[];
  final metadata = <smtc.MusicMetadata>[];
  ({bool next, bool previous})? skips;

  Future<void> close() => buttonEvents.close();

  @override
  Stream<smtc.PressedButton> get buttons => buttonEvents.stream;
  @override
  Future<void> setStatus(smtc.PlaybackStatus status) async =>
      statuses.add(status);
  @override
  Future<void> setTimeline(smtc.PlaybackTimeline timeline) async =>
      timelines.add(timeline);
  @override
  Future<void> setMetadata(smtc.MusicMetadata value) async =>
      metadata.add(value);
  @override
  Future<void> setNextPrevious({
    required bool next,
    required bool previous,
  }) async => skips = (next: next, previous: previous);
}

const _item = MediaItemMessage(
  id: 'track-1',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  extras: {'artCacheFile': '/cache/art.jpg'},
);

PlaybackStateMessage _state({
  bool playing = true,
  Duration position = Duration.zero,
  DateTime? at,
  AudioProcessingStateMessage processing = AudioProcessingStateMessage.ready,
}) => PlaybackStateMessage(
  processingState: processing,
  playing: playing,
  controls: const [],
  systemActions: const {
    MediaActionMessage.seek,
    MediaActionMessage.skipToNext,
    MediaActionMessage.skipToPrevious,
  },
  updatePosition: position,
  updateTime: at ?? DateTime(2026),
);

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugDesktopPlatformOverride = null;
  });

  test('each desktop OS gets its own media session', () {
    debugDesktopPlatformOverride = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(desktopMediaSession(), isA<MprisAudioService>());
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(desktopMediaSession(), isA<SmtcAudioService>());
    // macOS keeps the audio_service plugin; mobile is unchanged.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(desktopMediaSession(), isNull);
    debugDesktopPlatformOverride = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(desktopMediaSession(), isNull);
  });

  group('MPRIS', () {
    late DateTime now;
    late MprisPlayerObject player;
    late _Callbacks callbacks;

    setUp(() {
      now = DateTime(2026);
      player = MprisPlayerObject(now: () => now)
        ..callbacks = callbacks = _Callbacks();
    });
    tearDown(() {
      player.dispose();
      playbackOutputVolume.value = 1;
    });

    Future<DBusValue> property(String name) async {
      final response = await player.getProperty(
        'org.mpris.MediaPlayer2.Player',
        name,
      );
      return (response as DBusGetPropertyResponse).returnValues.single
          .asVariant();
    }

    Future<DBusMethodResponse> call(String name, [List<DBusValue>? values]) =>
        player.handleMethodCall(
          DBusMethodCall(
            sender: ':1.42',
            interface: 'org.mpris.MediaPlayer2.Player',
            name: name,
            values: values ?? const [],
          ),
        );

    test('publishes metadata with artwork and length', () async {
      player.updateMediaItem(_item);
      final metadata = (await property('Metadata')).asStringVariantDict();
      expect(metadata['xesam:title'], const DBusString('Song'));
      expect(metadata['xesam:artist'], DBusArray.string(['Artist']));
      expect(metadata['xesam:album'], const DBusString('Album'));
      expect(
        metadata['mpris:length'],
        DBusInt64(const Duration(minutes: 3).inMicroseconds),
      );
      expect(
        metadata['mpris:artUrl'],
        const DBusString('file:///cache/art.jpg'),
      );
      expect(metadata['mpris:trackid'], isA<DBusObjectPath>());
    });

    test('status and position follow the handler state', () async {
      expect(await property('PlaybackStatus'), const DBusString('Stopped'));
      player.updateMediaItem(_item);
      player.updateState(_state(position: const Duration(seconds: 10)));
      expect(await property('PlaybackStatus'), const DBusString('Playing'));
      now = now.add(const Duration(seconds: 2));
      expect(
        await property('Position'),
        DBusInt64(const Duration(seconds: 12).inMicroseconds),
      );
      player.updateState(
        _state(playing: false, position: const Duration(seconds: 12)),
      );
      expect(await property('PlaybackStatus'), const DBusString('Paused'));
      expect(await property('CanGoNext'), const DBusBoolean(true));
      expect(await property('CanSeek'), const DBusBoolean(true));
      player.updateStopped();
      expect(await property('PlaybackStatus'), const DBusString('Stopped'));
    });

    test('transport methods reach the handler', () async {
      player.updateMediaItem(_item);
      player.updateState(_state(position: const Duration(seconds: 30)));
      await call('PlayPause');
      await call('Next');
      await call('Previous');
      await call('Seek', [
        DBusInt64(const Duration(seconds: 5).inMicroseconds),
      ]);
      player.updateState(_state(playing: false));
      await call('PlayPause');
      expect(callbacks.requests.map((request) => request.runtimeType), [
        PauseRequest,
        SkipToNextRequest,
        SkipToPreviousRequest,
        SeekRequest,
        PlayRequest,
      ]);
      expect(
        (callbacks.requests[3] as SeekRequest).position,
        const Duration(seconds: 35),
      );
    });

    test('SetPosition ignores another track', () async {
      player.updateMediaItem(_item);
      player.updateState(_state());
      final metadata = (await property('Metadata')).asStringVariantDict();
      final track = metadata['mpris:trackid']!;
      await call('SetPosition', [
        DBusObjectPath('/com/zarz/mornye/track/999'),
        DBusInt64(1000000),
      ]);
      expect(callbacks.requests, isEmpty);
      await call('SetPosition', [track, DBusInt64(1000000)]);
      expect(
        (callbacks.requests.single as SeekRequest).position,
        const Duration(seconds: 1),
      );
    });

    test('Volume is the in-app output volume', () async {
      playbackOutputVolume.value = 0.6;
      expect(await property('Volume'), const DBusDouble(0.6));
      await player.setProperty(
        'org.mpris.MediaPlayer2.Player',
        'Volume',
        const DBusDouble(1.4),
      );
      expect(playbackOutputVolume.value, 1);
    });

    test('a missing session bus leaves playback working', () async {
      final service = MprisAudioService(
        connect: () => throw StateError('no bus'),
      );
      await service.configure(
        ConfigureRequest(
          config: AudioServiceConfigMessage(androidNotificationChannelId: 'id'),
        ),
      );
      await service.setMediaItem(const SetMediaItemRequest(mediaItem: _item));
      service.player.dispose();
    });
  });

  group('SMTC', () {
    late _Controls controls;
    late SmtcAudioService service;
    late _Callbacks callbacks;

    setUp(() async {
      controls = _Controls();
      addTearDown(controls.close);
      service = SmtcAudioService(create: () async => controls)
        ..setHandlerCallbacks(callbacks = _Callbacks());
      await service.configure(
        ConfigureRequest(config: AudioServiceConfigMessage()),
      );
    });
    tearDown(() => service.close());

    test('buttons reach the handler', () async {
      for (final button in [
        smtc.PressedButton.play,
        smtc.PressedButton.pause,
        smtc.PressedButton.next,
        smtc.PressedButton.previous,
      ]) {
        controls.buttonEvents.add(button);
      }
      await Future<void>.delayed(Duration.zero);
      expect(callbacks.requests.map((request) => request.runtimeType), [
        PlayRequest,
        PauseRequest,
        SkipToNextRequest,
        SkipToPreviousRequest,
      ]);
    });

    test('state, timeline and metadata are published', () async {
      await service.setMediaItem(const SetMediaItemRequest(mediaItem: _item));
      await service.setState(
        SetStateRequest(state: _state(position: const Duration(seconds: 7))),
      );
      expect(controls.metadata.single.title, 'Song');
      expect(controls.metadata.single.artist, 'Artist');
      expect(controls.metadata.single.thumbnail, startsWith('file:///'));
      expect(controls.statuses.last, smtc.PlaybackStatus.playing);
      expect(controls.timelines.last.positionMs, 7000);
      expect(controls.timelines.last.endTimeMs, 180000);
      expect(controls.skips, (next: true, previous: true));
      await service.setState(SetStateRequest(state: _state(playing: false)));
      expect(controls.statuses.last, smtc.PlaybackStatus.paused);
      await service.stopService(const StopServiceRequest());
      expect(controls.statuses.last, smtc.PlaybackStatus.stopped);
    });

    test('only readable artwork is passed on', () {
      expect(
        SmtcAudioService.thumbnailFor(
          MediaItemMessage(
            id: 'a',
            title: 'A',
            artUri: Uri.parse('https://example.com/cover.jpg'),
          ),
        ),
        'https://example.com/cover.jpg',
      );
      expect(
        SmtcAudioService.thumbnailFor(
          MediaItemMessage(
            id: 'b',
            title: 'B',
            artUri: Uri.parse('content://media/cover'),
          ),
        ),
        isNull,
      );
    });

    test('unavailable controls are skipped', () async {
      final failing = SmtcAudioService(
        create: () async => throw StateError('no SMTC'),
      );
      await failing.configure(
        ConfigureRequest(config: AudioServiceConfigMessage()),
      );
      await failing.setState(SetStateRequest(state: _state()));
    });
  });
}
