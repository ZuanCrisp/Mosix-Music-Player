import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mosix/services/automix_analysis.dart';
import 'package:mosix/services/automix_analyzer.dart';
import 'package:mosix/services/music_player_service.dart';
import 'package:mosix/services/music_playback_deck.dart';
import 'package:mosix/models/settings.dart';
import 'package:mosix/services/playback_notification.dart';
import 'package:mosix/models/automix_options.dart';
import 'package:mosix/services/automix_effect_renderer.dart';
import 'package:mosix/services/automix_status.dart';
import 'package:mosix/services/system_volume_service.dart';

class _EffectRenderer extends AutoMixEffectRenderer {
  final tails = <RenderedMixTail>[];
  bool fail = false;

  @override
  Future<RenderedMixTail?> render(
    String path, {
    required Duration start,
    required Duration duration,
    required AutoMixOptions options,
  }) async {
    if (fail) return null;
    final work = await Directory.systemTemp.createTemp('fake-mix-tail-');
    final tail = RenderedMixTail(work, '${work.path}/tail.wav');
    tails.add(tail);
    return tail;
  }
}

class _Analyzer extends AutoMixAnalyzer {
  final calls = <String>[];
  Completer<AutoMixBeatGrid?>? pending;
  bool matchBeats = false;

  @override
  Future<AutoMixBeatGrid?> analyze(String path, {double offset = 0}) async {
    calls.add(path);
    if (matchBeats) {
      return AutoMixBeatGrid(
        bpm: offset > 0 ? 120 : 124,
        phase: 0.17,
        confidence: 0.9,
        firstSound: 0.1,
      );
    }
    return pending?.future;
  }
}

/// Exercises the real AudioPlayer transport/streams against a native-channel
/// fake, including preparation, seek completion and outgoing completion events.
class _AudioNative {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <(String, String, Map<Object?, Object?>)>[];
  final positions = <String, int>{};
  final live = <String>{};
  final playing = <String>{};
  final sources = <String, String>{};
  final sourceContents = <String, String>{};
  final preparedContents = <String, String>{};
  final sourceGates = <String, Completer<void>>{};
  final resumedSources = <String>[];
  Completer<void>? resumeGate;
  final resumeGates = <String, Completer<void>>{};
  bool emitsDuration = true;

  void install() {
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        final args = call.arguments as Map<Object?, Object?>;
        final id = args['playerId']! as String;
        calls.add((id, call.method, args));
        switch (call.method) {
          case 'create':
            live.add(id);
            positions[id] = 0;
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          case 'setSourceUrl':
            final source = args['url']! as String;
            await sourceGates[source]?.future;
            // Android caches equal URLs, including recycled SAF descriptors.
            if (sources[id] != source) {
              sources[id] = source;
              preparedContents[id] = sourceContents[source] ?? source;
            }
            unawaited(event(id, 'audio.onPrepared', true));
            if (emitsDuration) unawaited(event(id, 'audio.onDuration', 60000));
          case 'seek':
            positions[id] = args['position']! as int;
            unawaited(event(id, 'audio.onSeekComplete'));
          case 'resume':
            await resumeGate?.future;
            await resumeGates[id]?.future;
            playing.add(id);
            resumedSources.add(sources[id]!);
          case 'pause' || 'stop':
            playing.remove(id);
          case 'release':
            playing.remove(id);
            sources.remove(id);
            preparedContents.remove(id);
          case 'dispose':
            playing.remove(id);
            live.remove(id);
          case 'getDuration':
            return 60000;
          case 'getCurrentPosition':
            return positions[id];
        }
        return null;
      },
    );
  }

  Future<void> event(String id, String name, [Object? value]) async {
    await messenger.handlePlatformMessage(
      'xyz.luan/audioplayers/events/$id',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'event': name,
        'value': ?value,
      }),
      (_) {},
    );
  }

  String get prepared => live.singleWhere((id) => id != 'music-player');

  double? lastVolume(String id) =>
      calls
              .where((call) => call.$1 == id && call.$2 == 'setVolume')
              .lastOrNull
              ?.$3['volume']
          as double?;
}

const _tracks = [
  PlayableMedia(id: 'one', source: '/one.flac', title: 'One', artist: 'Artist'),
  PlayableMedia(id: 'two', source: '/two.flac', title: 'Two', artist: 'Artist'),
  PlayableMedia(
    id: 'three',
    source: '/three.flac',
    title: 'Three',
    artist: 'Artist',
  ),
];

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Playback did not reach the expected state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late _AudioNative native;
  late _Analyzer analyzer;
  late _EffectRenderer effectRenderer;
  late MusicPlayerHandler handler;
  late AutoplayLibraryLoader autoplayLoader;

  setUp(() {
    setPlaybackAutomationOptions(
      enabled: true,
      pauseOnMute: false,
      playOnHeadphonesConnected: false,
    );
    setAutoMixEnabled(false);
    setAutoMixOptions(const AutoMixOptions());
    setUsbBitPerfectEnabled(false);
    setAutoplayEnabled(false);
    native = _AudioNative()..install();
    analyzer = _Analyzer();
    effectRenderer = _EffectRenderer();
    autoplayLoader = (_) async => _tracks;
    handler = MusicPlayerHandler(
      autoMixAnalyzer: analyzer,
      autoMixEffectRenderer: effectRenderer,
      autoplayLibraryLoader: (seed) => autoplayLoader(seed),
    );
  });

  tearDown(() async {
    await handler.dispose();
    configurePlaybackNotification(
      presentation: const PlaybackNotification(),
      toggleFavorite: (_) async => false,
    );
    analyzer.pending?.complete(null);
    setAutoMixEnabled(false);
    setUsbBitPerfectEnabled(false);
    setAutoplayEnabled(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(native.live, isEmpty);
    expect(native.playing, isEmpty);
    expect(autoMixStatus.value, AutoMixStatus.idle);
    for (final tail in effectRenderer.tails) {
      expect(await tail.directory.exists(), isFalse);
    }
  });

  test(
    'USB preference is opt-in and persists with existing DSP preferences',
    () {
      const defaults = AppSettings();
      expect(defaults.usbBitPerfect, isFalse);
      expect(defaults.usbDirect, isFalse);
      expect(defaults.usbDsdOverPcm, isFalse);
      expect(defaults.usbAllowFixedVolume, isFalse);
      expect(defaults.dapExclusive, isFalse);
      final upgraded = AppSettings.fromJson({
        'usbBitPerfect': true,
        'usbDirect': true,
      });
      expect(upgraded.usbAllowFixedVolume, isFalse);
      final selected = defaults.copyWith(
        usbBitPerfect: true,
        usbDirect: true,
        usbDsdOverPcm: true,
        usbAllowFixedVolume: true,
        autoMix: true,
        playbackNormalization: true,
      );
      final restored = AppSettings.fromJson(selected.toJson());
      expect(restored.usbBitPerfect, isTrue);
      expect(restored.usbDirect, isTrue);
      expect(restored.usbDsdOverPcm, isTrue);
      expect(restored.usbAllowFixedVolume, isTrue);
      expect(
        AppSettings.fromJson(
          defaults.copyWith(dapExclusive: true).toJson(),
        ).dapExclusive,
        isTrue,
      );
      expect(restored.autoMix, isTrue);
      expect(restored.playbackNormalization, isTrue);
    },
  );

  test(
    'USB mode prevents a second DSP deck even when AutoMix is enabled',
    () async {
      setAutoMixEnabled(true);
      setUsbBitPerfectEnabled(true);
      await handler.setQueueAndPlay(_tracks);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(native.live, {'music-player'});
      expect(native.lastVolume('music-player'), 1);
      expect(analyzer.calls, isEmpty);
    },
  );

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

  group('USB playback transport', () {
    const methods = MethodChannel('com.zuancrisp.mosix/usb_pcm');
    const events = MethodChannel('com.zuancrisp.mosix/usb_pcm/events');
    late MusicPlaybackDeck deck;
    late List<String> usbCalls;
    late int token;
    late String? fallbackReason;
    late bool failResume;
    late bool fatal;
    late bool volumeBlocked;
    Map<String, dynamic>? hardwareVolume;
    late String transport;
    late Map<dynamic, dynamic> prepareArguments;
    Completer<void>? pauseReply;
    Completer<Map<String, dynamic>>? prepareReply;
    var position = 0;

    Future<void> event(String name, {int? withToken}) =>
        native.messenger.handlePlatformMessage(
          events.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'event': name,
            'token': withToken ?? token,
          }),
          (_) {},
        );

    setUp(() {
      usbCalls = [];
      token = 0;
      fallbackReason = null;
      failResume = false;
      fatal = false;
      volumeBlocked = false;
      hardwareVolume = null;
      transport = 'pcm';
      prepareArguments = {};
      pauseReply = null;
      prepareReply = null;
      position = 0;
      native.messenger.setMockMethodCallHandler(events, (_) async => null);
      native.messenger.setMockMethodCallHandler(methods, (call) async {
        usbCalls.add(call.method);
        switch (call.method) {
          case 'prepare':
            prepareArguments = call.arguments as Map;
            token = (call.arguments as Map)['token'] as int;
            if (prepareReply != null) return prepareReply!.future;
            if (fallbackReason != null) {
              return {'reason': fallbackReason, 'fatal': fatal};
            }
            return {
              'ready': true,
              'duration': 60000,
              'device': 'Test DAC',
              'sampleRate': 96000,
              'bitDepth': 24,
              'transport': transport,
              'driver': prepareArguments['direct'] == true
                  ? 'usb_direct'
                  : 'android',
              'volumeBlocked': volumeBlocked,
              if (hardwareVolume != null)
                'volume': {...hardwareVolume!, 'token': token},
            };
          case 'volume':
            expect((call.arguments as Map)['token'], token);
            return {
              ...hardwareVolume!,
              'token': token,
              'currentDb': (call.arguments as Map)['db'],
            };
          case 'position':
            return position;
          case 'seek':
            position = (call.arguments as Map)['position'] as int;
          case 'resume':
            if (failResume) throw PlatformException(code: 'route_changed');
          case 'pause':
            await pauseReply?.future;
          case 'stop':
            if (prepareReply != null && !prepareReply!.isCompleted) {
              prepareReply!.complete({'reason': 'cancelled'});
            }
        }
        return null;
      });
      deck = MusicPlaybackDeck(playerId: 'usb-test', nativeAvailable: true);
    });

    test('direct driver and DoP are explicit and passed to native', () async {
      await deck.setSource(
        DeviceFileSource('/one.dsf'),
        preferBitPerfect: true,
        directUsb: true,
        allowDop: true,
      );
      expect(prepareArguments['direct'], isTrue);
      expect(prepareArguments['allowDop'], isTrue);
    });

    test('hardware volume changes the DAC, never PCM gain', () async {
      hardwareVolume = {
        'available': true,
        'minDb': -90.0,
        'maxDb': 0.0,
        'currentDb': -40.0,
      };
      await deck.setSource(
        DeviceFileSource('/one.flac'),
        preferBitPerfect: true,
        directUsb: true,
      );
      expect(usbHardwareVolume.value?.currentDb, -40);
      await setUsbHardwareVolume(0.5);
      expect(usbHardwareVolume.value?.currentDb, -45);
      expect(usbCalls, ['prepare', 'volume']);
      expect(native.calls.where((call) => call.$2 == 'setVolume'), isEmpty);
      await deck.stop();
      expect(usbHardwareVolume.value, isNull);
    });

    test(
      'uncontrolled DAC is blocked without ordinary full-volume fallback',
      () async {
        volumeBlocked = true;
        hardwareVolume = {'available': false};
        await deck.setSource(
          DeviceFileSource('/one.flac'),
          preferBitPerfect: true,
          directUsb: true,
        );
        await expectLater(deck.resume(), throwsA(isA<UsbOutputUnavailable>()));
        expect(usbCalls, ['prepare']);
        expect(usbAudioStatus.value.reason, 'volume_unavailable');
        expect(native.sources['usb-test'], isNull);
        await setUsbHardwareVolume(1);
        expect(usbCalls, ['prepare']);
      },
    );

    test(
      'AAudio exclusive and fixed volume require explicit options',
      () async {
        await deck.setSource(
          DeviceFileSource('/one.wav'),
          preferBitPerfect: true,
          dapExclusive: true,
        );
        expect(prepareArguments['dapExclusive'], isTrue);
        expect(prepareArguments['allowFixedVolume'], isFalse);
        expect(prepareArguments['direct'], isFalse);
        fallbackReason = 'exclusive_unavailable';
        await deck.setSource(
          DeviceFileSource('/one.wav'),
          preferBitPerfect: true,
          dapExclusive: true,
        );
        expect(usbAudioStatus.value.reason, 'exclusive_unavailable');
        expect(deck.isDirect, isFalse);
        expect(native.sources['usb-test'], '/one.wav');
      },
    );

    test(
      'changing tracks cancels a pending USB permission without fallback',
      () async {
        prepareReply = Completer<Map<String, dynamic>>();
        final preparing = deck.setSource(
          DeviceFileSource('/one.flac'),
          preferBitPerfect: true,
          directUsb: true,
        );
        await _until(() => usbCalls.contains('prepare'));
        await deck.cancelPreparation();
        await preparing;
        expect(usbCalls, ['prepare', 'stop']);
        expect(native.sources['usb-test'], isNull);
        expect(deck.isDirect, isFalse);
      },
    );

    test(
      'unsupported DSD never falls back through ordinary PCM output',
      () async {
        fallbackReason = 'dsd_unsupported';
        fatal = true;
        await expectLater(
          deck.setSource(
            DeviceFileSource('/one.dsf'),
            preferBitPerfect: true,
            directUsb: true,
          ),
          throwsStateError,
        );
        expect(native.sources['usb-test'], isNull);
        expect(usbAudioStatus.value.reason, 'dsd_unsupported');
      },
    );

    test('failed first DSD start does not switch to normal playback', () async {
      transport = 'dop';
      await deck.setSource(
        DeviceFileSource('/one.dsf'),
        preferBitPerfect: true,
        directUsb: true,
      );
      failResume = true;
      await expectLater(deck.resume(), throwsA(isA<UsbOutputUnavailable>()));
      expect(native.sources['usb-test'], isNull);
      expect(deck.needsSourceReload, isTrue);
    });

    test('DSD without a DAC never loads a normal audio source', () async {
      fallbackReason = 'no_usb';
      await expectLater(
        deck.setSource(
          DeviceFileSource('/one.dsf'),
          preferBitPerfect: true,
          directUsb: true,
          requiresDsd: true,
        ),
        throwsA(isA<UsbDsdUnavailable>()),
      );
      expect(native.sources['usb-test'], isNull);
    });

    tearDown(() async {
      await deck.dispose();
      native.messenger.setMockMethodCallHandler(methods, null);
      native.messenger.setMockMethodCallHandler(events, null);
    });

    test(
      'verified route plays, pauses and seeks without software gain or rate changes',
      () async {
        await deck.setSource(
          DeviceFileSource('/one.flac'),
          preferBitPerfect: true,
        );
        expect(usbAudioStatus.value.reason, 'ready');
        await deck.resume();
        await deck.setVolume(0.4);
        await deck.setPlaybackRate(1.1);
        expect(native.playing, isEmpty);
        expect(usbAudioStatus.value.reason, 'active');
        expect(usbAudioStatus.value.sampleRate, 96000);
        await deck.seek(const Duration(seconds: 21));
        expect(await deck.getCurrentPosition(), const Duration(seconds: 21));
        await deck.pause();
        expect(deck.state, PlayerState.paused);
        expect(usbCalls, ['prepare', 'resume', 'seek', 'position', 'pause']);
        expect(
          native.calls.where(
            (c) =>
                c.$1 == 'usb-test' &&
                ['setVolume', 'setPlaybackRate'].contains(c.$2),
          ),
          isEmpty,
        );
      },
    );

    test('late pause reply does not pause a newly prepared source', () async {
      await deck.setSource(
        DeviceFileSource('/one.flac'),
        preferBitPerfect: true,
      );
      await deck.resume();
      pauseReply = Completer<void>();
      final pausing = deck.pause();
      await _until(() => usbCalls.contains('pause'));
      await deck.setSource(
        DeviceFileSource('/two.flac'),
        preferBitPerfect: true,
      );
      await deck.resume();
      pauseReply!.complete();
      await pausing;
      expect(deck.state, PlayerState.playing);
      expect(usbAudioStatus.value.reason, 'active');
    });

    test('missing support falls back without reporting bit-perfect', () async {
      fallbackReason = 'no_usb';
      await deck.setSource(
        DeviceFileSource('/one.flac'),
        preferBitPerfect: true,
      );
      await deck.resume();
      expect(deck.isDirect, isFalse);
      expect(native.playing, {'usb-test'});
      expect(usbAudioStatus.value.reason, 'no_usb');
    });

    test('unverified route falls back before starting USB audio', () async {
      failResume = true;
      await deck.setSource(
        DeviceFileSource('/one.flac'),
        preferBitPerfect: true,
      );
      await deck.resume();
      expect(deck.isDirect, isFalse);
      expect(native.sources['usb-test'], '/one.flac');
      expect(native.playing, {'usb-test'});
      expect(usbAudioStatus.value.reason, 'unsupported');
    });

    test(
      'direct USB failure before first sound never redirects to speaker',
      () async {
        failResume = true;
        await deck.setSource(
          DeviceFileSource('/one.flac'),
          preferBitPerfect: true,
          directUsb: true,
        );
        await expectLater(deck.resume(), throwsA(isA<UsbOutputUnavailable>()));
        expect(native.sources['usb-test'], isNull);
        expect(native.playing, isEmpty);
        expect(usbAudioStatus.value.reason, 'route_changed');
      },
    );

    test(
      'route loss pauses and never starts the speaker automatically',
      () async {
        await deck.setSource(
          DeviceFileSource('/one.flac'),
          preferBitPerfect: true,
        );
        await deck.resume();
        await event('paused');
        await _until(() => deck.state == PlayerState.paused);
        expect(native.playing, isEmpty);
        expect(usbAudioStatus.value.reason, 'route_changed');
        position = 19000;
        expect(deck.needsSourceReload, isTrue);
        await expectLater(deck.resume(), throwsA(isA<PlatformException>()));
        expect(native.playing, isEmpty);
        expect(await deck.getCurrentPosition(), const Duration(seconds: 19));
      },
    );

    test(
      'events from an old song cannot pause or complete the new song',
      () async {
        await deck.setSource(
          DeviceFileSource('/one.flac'),
          preferBitPerfect: true,
        );
        final oldToken = token;
        await deck.setSource(
          DeviceFileSource('/two.flac'),
          preferBitPerfect: true,
        );
        await deck.resume();
        var completed = 0;
        final subscription = deck.onPlayerComplete.listen((_) => completed++);
        await event('complete', withToken: oldToken);
        await event('paused', withToken: oldToken);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(deck.state, PlayerState.playing);
        expect(completed, 0);
        await event('complete');
        await _until(() => completed == 1);
        expect(deck.state, PlayerState.completed);
        await subscription.cancel();
      },
    );
  });

  test(
    'Autoplay fills a single-track queue and follows its visible order',
    () async {
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await _until(() => handler.queue.value.length == 3);
      final planned = handler.queue.value.toList();
      expect(planned.first.id, 'one');
      expect(
        planned.skip(1).every((item) => item.extras?['autoplay'] == true),
        isTrue,
      );
      await native.event('music-player', 'audio.onComplete');
      await _until(() => handler.mediaItem.value?.id == planned[1].id);
      expect(native.sources['music-player'], planned[1].extras?['source']);
      setAutoplayEnabled(false);
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        planned[1].id,
      ]);
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test(
    'manual additions precede Autoplay and survive disabling or repeat',
    () async {
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await _until(() => handler.queue.value.length == 3);
      const manual = PlayableMedia(
        id: 'manual',
        source: '/manual.flac',
        title: 'Manual',
        artist: 'Other',
      );
      await handler.enqueue(manual);
      expect(handler.queue.value[1].id, 'manual');
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      expect(handler.queue.value[1].id, 'manual');
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      expect(handler.queue.value[1].id, 'manual');
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      expect(handler.queue.value.map((item) => item.id), ['one', 'manual']);
      await handler.setRepeatMode(AudioServiceRepeatMode.none);
      await _until(() => handler.queue.value.length == 4);
      setAutoplayEnabled(false);
      expect(handler.queue.value.map((item) => item.id), ['one', 'manual']);
    },
  );

  test(
    'pending Autoplay is discarded after disabling or replacing the queue',
    () async {
      final pending = Completer<List<PlayableMedia>>();
      autoplayLoader = (_) => pending.future;
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      setAutoplayEnabled(false);
      await handler.setQueueAndPlay([_tracks.last]);
      pending.complete(_tracks);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.queue.value.map((item) => item.id), ['three']);
      expect(native.sources['music-player'], '/three.flac');
    },
  );

  test('pause during an Autoplay refill prevents automatic resume', () async {
    final pending = Completer<List<PlayableMedia>>();
    autoplayLoader = (_) => pending.future;
    setAutoplayEnabled(true);
    await handler.setQueueAndPlay([_tracks.first]);
    await native.event('music-player', 'audio.onComplete');
    await handler.pause();
    pending.complete(_tracks);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(handler.mediaItem.value?.id, 'one');
    expect(handler.playbackState.value.playing, isFalse);
    expect(native.resumedSources, ['/one.flac']);
  });

  test(
    'replacing a queue invalidates an in-flight recommendation batch',
    () async {
      final pending = Completer<List<PlayableMedia>>();
      autoplayLoader = (seed) =>
          seed.id == 'one' ? pending.future : Future.value([]);
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await handler.setQueueAndPlay([_tracks.last]);
      pending.complete(_tracks);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.queue.value.map((item) => item.id), ['three']);
      expect(native.sources['music-player'], '/three.flac');
    },
  );

  test(
    'duplicate completion while recommendations load advances only once',
    () async {
      final pending = Completer<List<PlayableMedia>>();
      autoplayLoader = (_) => pending.future;
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await native.event('music-player', 'audio.onComplete');
      await native.event('music-player', 'audio.onComplete');
      pending.complete(_tracks);
      await _until(() => handler.playbackState.value.queueIndex == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.playbackState.value.queueIndex, 1);
      expect(handler.mediaItem.value?.id, handler.queue.value[1].id);
    },
  );

  test(
    'Autoplay never adds a song dismissed from the current queue again',
    () async {
      setAutoplayEnabled(true);
      await handler.setQueueAndPlay([_tracks.first]);
      await _until(() => handler.queue.value.length == 3);
      final removed = handler.queue.value[1];
      handler.removeQueuedItem(removed);
      await handler.skipToNext();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(handler.queue.value.any((item) => item.id == removed.id), isFalse);
    },
  );

  test('empty Library ends playback and does not repeatedly refill', () async {
    var loads = 0;
    autoplayLoader = (_) async {
      loads++;
      return [];
    };
    setAutoplayEnabled(true);
    await handler.setQueueAndPlay([_tracks.first]);
    await native.event('music-player', 'audio.onComplete');
    await _until(
      () =>
          handler.playbackState.value.processingState ==
          AudioProcessingState.completed,
    );
    expect(handler.queue.value, hasLength(1));
    expect(loads, 1);
  });

  test(
    'rapid Next keeps the final audible source and displayed title together',
    () async {
      final gate = Completer<void>();
      native.sourceGates['/one.flac'] = gate;
      final first = handler.setQueueAndPlay(_tracks);
      await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
      final second = handler.skipToNext();
      final third = handler.skipToNext();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      gate.complete();
      await Future.wait([first, second, third]);
      expect(handler.mediaItem.value?.id, 'three');
      expect(native.sources['music-player'], '/three.flac');
      expect(native.resumedSources, ['/three.flac']);
    },
  );

  for (final shuffle in [false, true]) {
    test('Previous changes both title and audio (shuffle: $shuffle)', () async {
      if (shuffle) await handler.setShuffleMode(AudioServiceShuffleMode.all);
      await handler.setQueueAndPlay(_tracks);
      final ordered = handler.queue.value.map((item) => item.id).toList();
      await handler.skipToNext();
      await handler.skipToNext();
      expect(native.sources['music-player'], '/${ordered[2]}.flac');

      // Repeat-one affects automatic completion, not an explicit Previous.
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      for (final id in ordered.take(2).toList().reversed) {
        await handler.skipToPrevious();
        expect(handler.mediaItem.value?.id, id);
        expect(native.preparedContents['music-player'], '/$id.flac');
        expect(native.resumedSources.last, '/$id.flac');
        expect(native.playing, {'music-player'});
      }
    });
  }

  test('rapid Previous discards a later track still preparing', () async {
    final gate = Completer<void>();
    native.sourceGates['/three.flac'] = gate;
    final last = handler.setQueueAndPlay(_tracks, initialIndex: 2);
    await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
    final second = handler.skipToPrevious();
    final first = handler.skipToPrevious();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    gate.complete();
    await Future.wait([last, second, first]);
    expect(handler.mediaItem.value?.id, 'one');
    expect(native.preparedContents['music-player'], '/one.flac');
    expect(native.resumedSources, ['/one.flac']);
  });

  test('Next and Previous reload a recycled SAF descriptor', () async {
    const descriptor = '/proc/self/fd/42';
    native.sourceContents[descriptor] = 'first file';
    await handler.setQueueAndPlay([
      const PlayableMedia(
        id: 'first',
        source: descriptor,
        title: 'First',
        artist: 'Artist',
      ),
      const PlayableMedia(
        id: 'second',
        source: descriptor,
        title: 'Second',
        artist: 'Artist',
      ),
    ]);
    expect(native.preparedContents['music-player'], 'first file');
    native.sourceContents[descriptor] = 'second file';
    await handler.skipToNext();
    expect(handler.mediaItem.value?.title, 'Second');
    expect(native.preparedContents['music-player'], 'second file');
    expect(native.playing, contains('music-player'));

    native.sourceContents[descriptor] = 'first file';
    await handler.skipToPrevious();
    expect(handler.mediaItem.value?.title, 'First');
    expect(native.preparedContents['music-player'], 'first file');
    expect(native.playing, {'music-player'});
  });

  test('replacing a queue during preparation drops the old request', () async {
    final gate = Completer<void>();
    native.sourceGates['/one.flac'] = gate;
    final first = handler.setQueueAndPlay(_tracks);
    await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
    final replacement = handler.setQueueAndPlay([_tracks[1]]);
    gate.complete();
    await Future.wait([first, replacement]);
    expect(handler.mediaItem.value?.id, 'two');
    expect(native.sources['music-player'], '/two.flac');
    expect(native.resumedSources, ['/two.flac']);
  });

  for (final stop in [false, true]) {
    test(
      'a pending prepare cannot resume after ${stop ? 'stop' : 'pause'}',
      () async {
        final gate = Completer<void>();
        native.sourceGates['/one.flac'] = gate;
        final first = handler.setQueueAndPlay(_tracks);
        await _until(() => native.calls.any((c) => c.$2 == 'setSourceUrl'));
        final cancel = stop ? handler.stop() : handler.pause();
        gate.complete();
        await Future.wait([first, cancel]);
        expect(native.resumedSources, isEmpty);
        expect(native.playing, isEmpty);
        expect(handler.playbackState.value.playing, isFalse);
        if (stop) expect(handler.mediaItem.value, isNull);
      },
    );
  }

  test('Mornye notification follows theme and keeps transport state', () async {
    await handler.restoreSession(
      items: _tracks,
      index: 0,
      position: const Duration(seconds: 12),
      shuffle: false,
    );
    configurePlaybackNotification(
      presentation: const PlaybackNotification(
        mornye: true,
        mediaId: 'one',
        source: '/one.flac',
        loved: true,
      ),
      toggleFavorite: (_) async => false,
    );
    final state = handler.playbackState.value;
    expect(state.playing, isFalse);
    expect(state.updatePosition, const Duration(seconds: 12));
    expect(state.controls.map((control) => control.action), [
      MediaAction.custom,
      MediaAction.skipToPrevious,
      MediaAction.play,
      MediaAction.skipToNext,
      MediaAction.custom,
    ]);
    expect(state.controls.first.androidIcon, contains('star_filled'));
    expect(
      state.controls.last.customAction?.name,
      PlaybackNotification.shuffleAction,
    );
    expect(state.androidCompactActionIndices, [1, 2, 3]);

    configurePlaybackNotification(
      presentation: const PlaybackNotification(),
      toggleFavorite: (_) async => false,
    );
    expect(handler.playbackState.value.controls, [
      MediaControl.skipToPrevious,
      MediaControl.play,
      MediaControl.skipToNext,
    ]);
    expect(handler.playbackState.value.androidCompactActionIndices, [0, 1, 2]);
    expect(handler.playbackState.value.updatePosition, state.updatePosition);
    handler.playbackState.add(
      PlaybackState(
        playing: true,
        processingState: AudioProcessingState.ready,
        updatePosition: const Duration(seconds: 12),
        updateTime: DateTime.now().subtract(const Duration(seconds: 5)),
      ),
    );
    configurePlaybackNotification(
      presentation: const PlaybackNotification(mornye: true),
      toggleFavorite: (_) async => false,
    );
    expect(
      handler.playbackState.value.updatePosition.inMilliseconds,
      inInclusiveRange(17000, 17200),
      reason: 'Changing icons must not reset the live playback position',
    );
  });

  test(
    'notification shuffle toggles queue order without restarting audio',
    () async {
      configurePlaybackNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (_) async => false,
      );
      await handler.setQueueAndPlay(_tracks, initialIndex: 1);
      final resumed = List.of(native.resumedSources);

      await handler.customAction(PlaybackNotification.shuffleAction);
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      expect(handler.queue.value.first.id, 'two');
      expect(handler.queue.value.map((item) => item.id).toSet(), {
        'one',
        'two',
        'three',
      });
      expect(handler.mediaItem.value?.id, 'two');
      expect(
        handler.playbackState.value.controls.last.androidIcon,
        endsWith('shuffle_on'),
      );
      expect(handler.playbackState.value.controls.last.label, 'Shuffle on');

      await handler.customAction(PlaybackNotification.shuffleAction);
      expect(
        handler.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.none,
      );
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        'two',
        'three',
      ]);
      expect(handler.mediaItem.value?.id, 'two');
      expect(
        handler.playbackState.value.controls.last.androidIcon,
        endsWith('shuffle'),
      );
      expect(handler.playbackState.value.controls.last.label, 'Shuffle off');
      expect(handler.playbackState.value.playing, isTrue);
      expect(native.resumedSources, resumed);
    },
  );

  test(
    'shuffle plays the published queue and off restores the original order',
    () async {
      final tracks = [
        for (var i = 0; i < 8; i++)
          PlayableMedia(
            id: '$i',
            source: '/$i.flac',
            title: '$i',
            artist: 'Artist',
          ),
      ];
      await handler.setQueueAndPlay(tracks, initialIndex: 3);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      final planned = handler.queue.value.map((item) => item.id).toList();
      expect(planned.first, '3');
      expect(planned.toSet(), tracks.map((item) => item.id).toSet());
      for (var i = 1; i < planned.length; i++) {
        await handler.skipToNext();
        expect(handler.mediaItem.value?.id, planned[i]);
        expect(native.sources['music-player'], '/${planned[i]}.flac');
        expect(handler.queue.value.map((item) => item.id), planned);
      }
      final last = handler.mediaItem.value;
      final resumes = native.resumedSources.length;
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      expect(
        handler.queue.value.map((item) => item.id),
        tracks.map((item) => item.id),
      );
      expect(handler.mediaItem.value, last);
      expect(handler.playbackState.value.queueIndex, int.parse(planned.last));
      expect(native.resumedSources.length, resumes);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      expect(handler.queue.value.first.id, planned.last);
      expect(handler.mediaItem.value, last);
    },
  );

  test(
    'automatic completion follows shuffle order and respects repeat off',
    () async {
      await handler.setQueueAndPlay(_tracks);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      final planned = handler.queue.value.map((item) => item.id).toList();
      for (var i = 1; i < planned.length; i++) {
        await native.event('music-player', 'audio.onComplete');
        await _until(
          () =>
              handler.mediaItem.value?.id == planned[i] &&
              handler.playbackState.value.processingState ==
                  AudioProcessingState.ready,
        );
      }
      await native.event('music-player', 'audio.onComplete');
      await _until(
        () =>
            handler.playbackState.value.processingState ==
            AudioProcessingState.completed,
      );
      expect(handler.mediaItem.value?.id, planned.last);
      expect(handler.queue.value.map((item) => item.id), planned);
    },
  );

  test(
    'shuffle restoration retains duplicate entries and explicit queue edits',
    () async {
      await handler.setQueueAndPlay([
        _tracks[0],
        _tracks[0],
        _tracks[1],
        _tracks[2],
      ]);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      await handler.enqueue(
        const PlayableMedia(
          id: 'next',
          source: '/next.flac',
          title: 'Next',
          artist: '',
        ),
        playNext: true,
      );
      await handler.enqueueAll([
        const PlayableMedia(
          id: 'last',
          source: '/last.flac',
          title: 'Last',
          artist: '',
        ),
      ]);
      expect(handler.queue.value[1].id, 'next');
      await handler.onSourceDeleted('/two.flac');
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        'next',
        'one',
        'three',
        'last',
      ]);
      expect(handler.playbackState.value.queueIndex, 0);
    },
  );

  test(
    'queue removal preserves duplicates, current audio and unshuffled order',
    () async {
      await handler.setQueueAndPlay([
        _tracks[0],
        _tracks[0],
        _tracks[1],
        _tracks[2],
      ]);
      final original = List.of(handler.queue.value);
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      handler.removeQueuedItem(original[1]);
      handler.removeQueuedItem(original[1]); // A stale swipe is harmless.
      handler.removeQueuedItem(
        original[0],
      ); // The playing occurrence is protected.
      await handler.setShuffleMode(AudioServiceShuffleMode.none);
      expect(handler.queue.value.map((item) => item.id), [
        'one',
        'two',
        'three',
      ]);
      expect(native.resumedSources, ['/one.flac']);
      await handler.skipToNext();
      handler.removeQueuedItem(original[0]);
      expect(handler.playbackState.value.queueIndex, 0);
      expect(handler.mediaItem.value?.id, 'two');
      expect(native.sources['music-player'], '/two.flac');
    },
  );

  test(
    'removing an earlier row during preparation preserves duration probing',
    () async {
      native.emitsDuration = false;
      final gate = Completer<void>();
      native.sourceGates['/three.flac'] = gate;
      final loading = handler.setQueueAndPlay(_tracks, initialIndex: 2);
      await _until(() => native.calls.any((call) => call.$2 == 'setSourceUrl'));
      handler.removeQueuedItem(handler.queue.value.first);
      gate.complete();
      await loading;
      await _until(
        () => handler.mediaItem.value?.duration == const Duration(seconds: 60),
      );
      expect(handler.playbackState.value.queueIndex, 1);
      expect(handler.mediaItem.value?.id, 'three');
      expect(native.resumedSources, ['/three.flac']);
    },
  );

  test('restored shuffle can return to the saved original order', () async {
    await handler.restoreSession(
      items: [_tracks[1], _tracks[2], _tracks[0]],
      index: 1,
      position: const Duration(seconds: 12),
      shuffle: true,
      originalOrder: [1, 2, 0],
    );
    await handler.setShuffleMode(AudioServiceShuffleMode.none);
    expect(handler.queue.value.map((item) => item.id), ['one', 'two', 'three']);
    expect(handler.mediaItem.value?.id, 'three');
    expect(handler.playbackState.value.queueIndex, 2);
    expect(handler.playbackState.value.position.inSeconds, 12);
    expect(native.resumedSources, isEmpty);
  });

  test(
    'notification favorite retains clicked track and ignores double taps',
    () async {
      final save = Completer<void>();
      final selected = <String>[];
      configurePlaybackNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (item) async {
          selected.add(item.id);
          await save.future;
          return true;
        },
      );
      handler.mediaItem.add(_tracks.first.toMediaItem());
      final first = handler.customAction(PlaybackNotification.favoriteAction);
      handler.mediaItem.add(_tracks.last.toMediaItem());
      await handler.customAction(PlaybackNotification.favoriteAction);
      expect(selected, ['one']);
      save.complete();
      await first;
      expect(
        handler.playbackState.value.controls.first.androidIcon,
        endsWith('ic_notification_star'),
        reason:
            'Completing a favorite for the old track must not star the next one',
      );
      await handler.customAction(PlaybackNotification.favoriteAction);
      expect(selected, ['one', 'three']);
      expect(
        handler.playbackState.value.controls.first.androidIcon,
        endsWith('ic_notification_star_filled'),
      );
    },
  );

  test('notification favorite refreshes without a UI rebuild', () async {
    var loved = false;
    configurePlaybackNotification(
      presentation: const PlaybackNotification(
        mornye: true,
        favoriteLabel: 'Add to Loved',
        unfavoriteLabel: 'Remove from Loved',
      ),
      toggleFavorite: (_) async => loved = !loved,
    );
    await handler.restoreSession(
      items: _tracks,
      index: 0,
      position: const Duration(seconds: 12),
      shuffle: false,
    );
    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(
      handler.playbackState.value.controls.first.androidIcon,
      endsWith('ic_notification_star_filled'),
    );
    expect(
      handler.playbackState.value.controls.first.label,
      'Remove from Loved',
    );
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 12),
    );

    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(
      handler.playbackState.value.controls.first.androidIcon,
      endsWith('ic_notification_star'),
    );
    expect(handler.playbackState.value.controls.first.label, 'Add to Loved');
    expect(native.resumedSources, isEmpty);
  });

  test('failed favorite save leaves the notification icon unchanged', () async {
    configurePlaybackNotification(
      presentation: const PlaybackNotification(mornye: true),
      toggleFavorite: (_) async => throw StateError('Save failed'),
    );
    handler.mediaItem.add(_tracks.first.toMediaItem());
    await handler.customAction(PlaybackNotification.favoriteAction);
    expect(
      handler.playbackState.value.controls.first.androidIcon,
      endsWith('ic_notification_star'),
    );
  });

  Future<void> prepare() async {
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await _until(() => analyzer.calls.length == 2);
    await _until(
      () => native.calls.any((call) => call.$2 == 'setPlaybackRate'),
    );
  }

  Future<String> startMix({int startPosition = 55000}) async {
    await prepare();
    final incoming = native.prepared;
    native.positions['music-player'] = startPosition;
    await _until(() => handler.mediaItem.value?.id == 'two');
    await _until(() => (native.lastVolume(incoming) ?? 0) > 0);
    return incoming;
  }

  test('Previous after AutoMix handoff reloads the preceding audio', () async {
    final active = await startMix();
    await handler.seek(Duration.zero);
    await handler.skipToPrevious();
    expect(handler.mediaItem.value?.id, 'one');
    expect(native.preparedContents[active], '/one.flac');
    expect(native.resumedSources.last, '/one.flac');
    expect(native.playing, {active});
  });

  test(
    'AutoMix prepares and plays the next entry in the shuffled queue',
    () async {
      await handler.setShuffleMode(AudioServiceShuffleMode.all);
      await prepare();
      final planned = handler.queue.value.map((item) => item.id).toList();
      final incoming = native.prepared;
      expect(native.sources[incoming], '/${planned[1]}.flac');
      native.positions['music-player'] = 55000;
      await _until(() => handler.mediaItem.value?.id == planned[1]);
      expect(handler.queue.value.map((item) => item.id), planned);
      expect(handler.playbackState.value.queueIndex, 1);
    },
  );

  test(
    'disabled AutoMix uses only the ordinary player and no analysis',
    () async {
      await handler.setQueueAndPlay(_tracks);
      native.positions['music-player'] = 56000;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(analyzer.calls, isEmpty);
      expect(native.live, {'music-player'});
      expect(handler.mediaItem.value?.id, 'one');
    },
  );

  test(
    'handoff publishes native duration and ignores outgoing completion',
    () async {
      final incoming = await startMix();
      expect(native.playing, {'music-player', incoming});
      expect(handler.mediaItem.value?.duration, const Duration(minutes: 1));
      expect(handler.playbackState.value.queueIndex, 1);
      await native.event('music-player', 'audio.onComplete');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(handler.mediaItem.value?.id, 'two');
      expect(handler.playbackState.value.playing, isTrue);
    },
  );

  test(
    'pause during overlap stops both decks and restores incoming gain',
    () async {
      final incoming = await startMix();
      expect(autoMixStatus.value, AutoMixStatus.crossfading);
      await handler.pause();
      expect(native.live, {incoming});
      expect(native.playing, isEmpty);
      expect(native.lastVolume(incoming), 1);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test(
    'matched transition releases outgoing and restores tempo after the fade',
    () async {
      analyzer.matchBeats = true;
      final incoming = await startMix(startPosition: 55670);
      expect(autoMixStatus.value, AutoMixStatus.mixing);
      expect(handler.playbackState.value.speed, closeTo(120 / 124, 0.0001));
      await Future<void>.delayed(const Duration(milliseconds: 4200));
      expect(autoMixStatus.value, AutoMixStatus.idle);
      expect(native.live, {incoming});
      expect(native.lastVolume(incoming), closeTo(1, 0.0001));
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(handler.playbackState.value.speed, 1);
      expect(native.playing, {incoming});
      expect(
        native.calls.where(
          (call) => call.$1 == 'music-player' && call.$2 == 'dispose',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'seek during overlap cancels fade and seeks only the active deck',
    () async {
      final incoming = await startMix();
      await handler.seek(const Duration(seconds: 12));
      expect(native.live, {incoming});
      expect(native.positions[incoming], 12000);
      expect(native.lastVolume(incoming), 1);
    },
  );

  test(
    'rendered effect replaces outgoing deck and pause removes its temporary tail',
    () async {
      setAutoMixOptions(const AutoMixOptions(effect: AutoMixEffect.echo));
      await prepare();
      await _until(() => native.live.length == 3);
      final incoming = native.sources.entries
          .singleWhere((entry) => entry.value == '/two.flac')
          .key;
      final effect = native.sources.entries
          .singleWhere((entry) => entry.value.endsWith('/tail.wav'))
          .key;
      native.positions['music-player'] = 55000;
      await _until(() => handler.mediaItem.value?.id == 'two');
      await _until(() => !native.live.contains('music-player'));
      expect(native.playing, {incoming, effect});
      expect(autoMixStatus.value, AutoMixStatus.crossfading);
      await handler.pause();
      expect(native.live, {incoming});
      expect(await effectRenderer.tails.single.directory.exists(), isFalse);
    },
  );

  test('effect rendering failure retains ordinary crossfade', () async {
    effectRenderer.fail = true;
    setAutoMixOptions(
      const AutoMixOptions(effect: AutoMixEffect.pitch, pitchSemitones: 2),
    );
    final incoming = await startMix();
    expect(native.playing, {'music-player', incoming});
    expect(effectRenderer.tails, isEmpty);
  });

  test(
    'effect startup keeps dry audio audible and blends before disposal',
    () async {
      setAutoMixOptions(const AutoMixOptions(effect: AutoMixEffect.muffled));
      await prepare();
      await _until(
        () => native.sources.values.any((path) => path.endsWith('/tail.wav')),
      );
      final effect = native.sources.entries
          .singleWhere((entry) => entry.value.endsWith('/tail.wav'))
          .key;
      final ready = Completer<void>();
      native.resumeGates[effect] = ready;
      native.positions['music-player'] = 55000;
      await _until(
        () => native.calls.any(
          (call) => call.$1 == effect && call.$2 == 'resume',
        ),
      );
      expect(native.lastVolume('music-player'), 1);
      expect(native.lastVolume(effect), 0);
      expect(native.playing, contains('music-player'));
      ready.complete();
      await _until(() => (native.lastVolume(effect) ?? 0) > 0);
      expect(native.lastVolume('music-player'), inExclusiveRange(0, 1));
      expect(native.lastVolume(effect), inExclusiveRange(0, 1));
      // Pausing during the handover must clean up both the dry and wet decks.
      await handler.pause();
      expect(native.live, hasLength(1));
      expect(native.playing, isEmpty);
      expect(await effectRenderer.tails.single.directory.exists(), isFalse);
    },
  );

  test(
    'turning AutoMix off releases the standby player without changing song',
    () async {
      await prepare();
      setAutoMixEnabled(false);
      await _until(() => native.live.length == 1);
      expect(native.live, {'music-player'});
      expect(handler.mediaItem.value?.id, 'one');
      expect(native.playing, {'music-player'});
    },
  );

  test('queue edit never starts the previously prepared next song', () async {
    await prepare();
    await handler.enqueue(_tracks[2], playNext: true);
    native.positions['music-player'] = 55000;
    await _until(() => analyzer.calls.length >= 4);
    await _until(() => handler.mediaItem.value?.id == 'three');
    expect(handler.mediaItem.value?.id, 'three');
  });

  test('manual skip invalidates an analysis still in flight', () async {
    analyzer.pending = Completer<AutoMixBeatGrid?>();
    setAutoMixEnabled(true);
    await handler.setQueueAndPlay(_tracks);
    await _until(() => analyzer.calls.isNotEmpty);
    await handler.skipToNext();
    await handler.pause();
    analyzer.pending!.complete(null);
    analyzer.pending = null;
    await _until(() => native.live.length == 1);
    expect(handler.mediaItem.value?.id, 'two');
    expect(native.playing, isEmpty);
  });

  test(
    'network playback uses URL transport and does not analyze remote files',
    () async {
      setAutoMixEnabled(true);
      const remote = PlayableMedia(
        id: 'remote',
        source: 'https://music.test/song.mp3',
        title: 'Remote',
        artist: 'Server',
      );
      await handler.setQueueAndPlay([remote, _tracks.first]);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        native.calls.lastWhere((c) => c.$2 == 'setSourceUrl').$3['isLocal'],
        false,
      );
      expect(native.playing, {'music-player'});
      expect(analyzer.calls, isEmpty);
      await handler.skipToNext();
      expect(
        native.calls.lastWhere((c) => c.$2 == 'setSourceUrl').$3['isLocal'],
        true,
      );
      await handler.skipToPrevious();
      expect(handler.mediaItem.value?.id, remote.id);
      expect(native.preparedContents['music-player'], remote.source);
      expect(native.resumedSources.last, remote.source);
      expect(
        native.calls.lastWhere((c) => c.$2 == 'setSourceUrl').$3['isLocal'],
        false,
      );
    },
  );

  test('repeat one never prepares another deck', () async {
    setAutoMixEnabled(true);
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    await handler.setQueueAndPlay(_tracks);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(native.live, {'music-player'});
    expect(analyzer.calls, isEmpty);
  });
}
