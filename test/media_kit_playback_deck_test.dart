import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/equalizer_settings.dart';
import 'package:mornye/services/media_kit_playback_deck.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/services/playback_equalizer.dart';

import 'support/fake_mpv_engine.dart';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 150));

void main() {
  late FakeMpvEngine engine;
  late MediaKitPlaybackDeck deck;

  setUp(() {
    MediaKitPlaybackDeck.debugResetMissingFilters();
    playbackEqualizer.value = const EqualizerSettings();
    playbackEqualizerError.value = null;
    playbackOutputVolume.value = 1;
    engine = FakeMpvEngine();
    deck = MediaKitPlaybackDeck(playerId: 'mpv-test', engine: engine);
  });

  tearDown(() async {
    await deck.dispose();
    playbackEqualizer.value = const EqualizerSettings();
    playbackOutputVolume.value = 1;
  });

  test('loads a file paused and reports its duration', () async {
    final durations = <Duration>[];
    deck.onDurationChanged.listen(durations.add);
    await deck.setFileSource('/music/song.flac');
    expect(
      engine.calls,
      containsAllInOrder([
        ['stop'],
        ['open', '/music/song.flac'],
      ]),
    );
    expect(await deck.getDuration(), const Duration(seconds: 90));
    expect(durations, [const Duration(seconds: 90)]);
    expect(engine.calls, isNot(contains(['play'])));
  });

  test('transport changes the reported state', () async {
    final states = <PlaybackDeckState>[];
    deck.onPlayerStateChanged.listen(states.add);
    await deck.setFileSource('/song.flac');
    await deck.resume();
    expect(deck.state, PlaybackDeckState.playing);
    await deck.pause();
    expect(deck.state, PlaybackDeckState.paused);
    await deck.resume();
    engine.completedEvents.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(deck.state, PlaybackDeckState.completed);
    expect(states, [
      PlaybackDeckState.stopped,
      PlaybackDeckState.playing,
      PlaybackDeckState.paused,
      PlaybackDeckState.playing,
      PlaybackDeckState.completed,
    ]);
  });

  test('positions are published on a timer while playing', () async {
    final positions = <Duration>[];
    deck.onPositionChanged.listen(positions.add);
    deck.startPositionUpdates(const Duration(milliseconds: 10));
    await deck.setFileSource('/song.flac');
    engine.position = const Duration(seconds: 3);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(positions, isEmpty);
    await deck.resume();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(positions, isNotEmpty);
    expect(positions.last, const Duration(seconds: 3));
  });

  test(
    'a source that fails to open throws, DSD as UsbDsdUnavailable',
    () async {
      engine.openError = (prefix: 'cplayer', text: 'Failed to recognize file');
      await expectLater(
        deck.setFileSource('/broken.flac'),
        throwsA(isA<MediaKitSourceException>()),
      );
      await expectLater(
        deck.setFileSource('/song.dsf', requiresDsd: true),
        throwsA(isA<UsbDsdUnavailable>()),
      );
      engine.openError = null;
      await deck.setFileSource('/song.dsf', requiresDsd: true);
      expect(await deck.getDuration(), const Duration(seconds: 90));
    },
  );

  test('a runtime source error fails the next resume', () async {
    final errors = <Object>[];
    deck.onPlayerStateChanged.listen((_) {}, onError: errors.add);
    await deck.setFileSource('/song.flac');
    await deck.resume();
    engine.errorEvents.add((prefix: 'ad', text: 'Error decoding frame'));
    await Future<void>.delayed(Duration.zero);
    expect(errors, isEmpty);
    engine.errorEvents.add((prefix: 'stream', text: 'Read error'));
    await Future<void>.delayed(Duration.zero);
    expect(errors.single, isA<MediaKitSourceException>());
    await expectLater(deck.resume(), throwsA(isA<MediaKitSourceException>()));
  });

  for (final diagnostic in [
    (prefix: 'ffmpeg', text: 'Incorrect BOM value'),
    (prefix: 'ffmpeg/demuxer', text: 'Error reading frame TIT2, skipped'),
    (prefix: 'ad', text: 'Error decoding frame'),
  ]) {
    test(
      'recoverable ${diagnostic.prefix} error does not abort opening',
      () async {
        engine.openError = diagnostic;
        final errors = <Object>[];
        final subscription = deck.onPlayerStateChanged.listen(
          (_) {},
          onError: errors.add,
        );
        addTearDown(subscription.cancel);
        final loaded = expectLater(
          deck.setFileSource('/tagged.mp3'),
          completes,
        );
        await Future<void>.delayed(Duration.zero);
        engine.durationEvents.add(const Duration(seconds: 90));
        await loaded;
        expect(await deck.getDuration(), const Duration(seconds: 90));
        await deck.resume();
        expect(deck.state, PlaybackDeckState.playing);
        expect(errors, isEmpty);
        expect(
          engine.calls.where((call) => call.first == 'stop'),
          hasLength(1),
        );
      },
    );
  }

  test(
    'a fatal opening error after a tag diagnostic still rejects the source',
    () async {
      engine.openError = (prefix: 'ffmpeg', text: 'Incorrect BOM value');
      final failed = expectLater(
        deck.setFileSource('/broken.mp3'),
        throwsA(
          isA<MediaKitSourceException>().having(
            (error) => error.message,
            'fatal error',
            contains('Failed to recognize file'),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      engine.errorEvents.add((
        prefix: 'cplayer',
        text: 'Failed to recognize file',
      ));
      await failed;
    },
  );

  test(
    'volume is scaled by the in-app output volume on a cubic curve',
    () async {
      await deck.setVolume(0.8);
      expect(engine.volume, closeTo(100 * 0.9283, 0.01));
      playbackOutputVolume.value = 0.5;
      await Future<void>.delayed(Duration.zero);
      // 0.8 * 0.5 = 0.4 linear gain; mpv's volume is cubic.
      expect(engine.volume, closeTo(100 * 0.7368, 0.01));
      await deck.setVolume(0);
      expect(engine.volume, 0);
    },
  );

  test('equalizer changes set the chain while playing', () async {
    await _settle();
    expect(engine.filterWrites.single, ['set', 'af', '']);

    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    await _settle();
    expect(
      engine.properties['af'],
      contains('@mornye_dsp:lavfi=[volume@pre=precision=float:volume=0dB,'),
    );

    await deck.setFileSource('/song.flac');
    await deck.resume();
    playbackEqualizer.value = playbackEqualizer.value.copyWith(preamp: -2);
    await _settle();
    expect(engine.properties['af'], contains('volume=-2dB'));

    var writes = engine.filterWrites.length;
    for (final gain in [-1.0, -1.5, -2.0]) {
      playbackEqualizer.value = playbackEqualizer.value.copyWith(
        gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, gain],
      );
    }
    await _settle();
    expect(engine.filterWrites.length, writes + 1);
    expect(
      engine.properties['af'],
      contains('equalizer@band9=f=16000:t=q:w=1.4142:g=-2,'),
    );

    // An identical chain, here from a new rate below every band, is not set
    // again.
    writes = engine.filterWrites.length;
    engine.sampleRateEvents.add(48000);
    await _settle();
    expect(engine.filterWrites.length, writes);
    expect(playbackEqualizerError.value, isNull);

    playbackEqualizer.value = const EqualizerSettings();
    await _settle();
    expect(engine.properties['af'], '');
  });

  test('filters libmpv lacks are probed once and left out', () async {
    MediaKitPlaybackDeck.debugResetMissingFilters();
    addTearDown(MediaKitPlaybackDeck.debugResetMissingFilters);
    engine.missingFilters = {'volume', 'stereotools', 'alimiter'};
    await deck.setVolume(1);
    playbackEqualizer.value = const EqualizerSettings(
      enabled: true,
    ).copyWith(gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0], balance: 0.5);
    await _settle();
    final af = engine.properties['af']!;
    expect(af, contains('equalizer@band0'));
    expect(af, isNot(contains('volume@pre')));
    expect(af, isNot(contains('stereotools')));
    // The -6 dB headroom moves to mpv's cubic volume.
    expect(engine.volume, closeTo(100 * 0.7943, 0.01));
    expect(playbackEqualizerError.value, contains('balance'));

    final probes = engine.filterWrites
        .where((call) => call[2].startsWith('@mornye_probe'))
        .length;
    expect(probes, 4);
    final other = FakeMpvEngine()..missingFilters = engine.missingFilters;
    final second = MediaKitPlaybackDeck(playerId: 'mpv-other', engine: other);
    await _settle();
    expect(
      other.filterWrites.where((call) => call[2].startsWith('@mornye_probe')),
      isEmpty,
    );
    await second.dispose();
  });

  test('a chain mpv disabled is set again on the next change', () async {
    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    await _settle();
    engine.errorEvents.add((
      prefix: 'af',
      text: 'Disabling filter mornye_dsp because it has failed.',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(playbackEqualizerError.value, contains('mornye_dsp'));
    final writes = engine.filterWrites.length;
    // Same chain as before: a rate change that leaves every band in place.
    engine.sampleRateEvents.add(48000);
    await _settle();
    expect(engine.filterWrites.length, writes + 1);
    expect(playbackEqualizerError.value, isNull);
  });

  test('a new sample rate rebuilds the bands', () async {
    playbackEqualizer.value = const EqualizerSettings(
      enabled: true,
    ).withBandCount(31);
    await _settle();
    expect(engine.properties['af'], contains('f=19845'));
    engine.sampleRateEvents.add(96000);
    await _settle();
    expect(engine.properties['af'], contains('f=20000'));
  });

  test('filter failures are reported for this player only', () async {
    engine.rejectFilters = true;
    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    await _settle();
    expect(playbackEqualizerError.value, contains('mpv error -7'));
    engine.rejectFilters = false;
    playbackEqualizer.value = const EqualizerSettings();
    await _settle();
    expect(playbackEqualizerError.value, isNull);

    playbackEqualizer.value = const EqualizerSettings(enabled: true);
    await _settle();
    engine.errorEvents.add((
      prefix: 'ffmpeg/Parsed_equalizer_0',
      text: 'Invalid frequency',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(playbackEqualizerError.value, contains('Invalid frequency'));
    await deck.dispose();
    expect(playbackEqualizerError.value, isNull);
    expect(engine.disposed, isTrue);
  });
}
