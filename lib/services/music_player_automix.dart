part of 'music_player_service.dart';

/// Owns only the extra deck and transition work. The ordinary player remains
/// the sole transport when AutoMix is disabled or a transition cannot be made.
class _MusicAutoMix {
  _MusicAutoMix(this.handler, this.analyzer, this.renderer);

  final MusicPlayerHandler handler;
  final AutoMixAnalyzer analyzer;
  final AutoMixEffectRenderer renderer;
  final _preparationPins = <int, Set<String>>{};
  final _mixPins = <String>{};
  MusicPlaybackDeck? _prepared;
  MusicPlaybackDeck? _outgoing;
  MusicPlaybackDeck? _effectDry;
  MusicPlaybackDeck? _effectPrepared;
  RenderedMixTail? _effectTail;
  AutoMixPlan? _plan;
  PlayableMedia? _next;
  String? _nextPath;
  Duration? _nextDuration;
  String? _attempt;
  int _nextIndex = -1;
  int _queueRevision = -1;
  int _playGeneration = -1;
  int _generation = 0;
  int _cancelling = 0;
  bool _preparing = false;
  bool _starting = false;
  double _incomingVolume = 1;
  double rate = 1;
  Timer? _startTimer;
  Timer? _fadeTimer;
  Future<void> _fadeWrite = Future<void>.value();
  bool _writing = false;

  void _setStatus(AutoMixStatus status) {
    if (identical(musicPlayerRuntime.handler, handler)) {
      autoMixStatus.value = status;
    }
  }

  String _beatSummary(AutoMixBeatGrid? grid) => grid == null
      ? 'unavailable'
      : '${grid.bpm.toStringAsFixed(2)} BPM/${grid.confidence.toStringAsFixed(3)} confidence';

  Set<String> get pinnedPaths => {
    ..._mixPins,
    for (final paths in _preparationPins.values) ...paths,
  };

  bool get _canMix =>
      handler._settings.autoMix &&
      !handler._settings.usbBitPerfect &&
      !handler._player.isDirect &&
      !handler._disposed &&
      handler._sourceReady &&
      !handler._userPaused &&
      !handler._interruptionActive &&
      handler._player.state == PlayerState.playing &&
      handler._repeatMode != AudioServiceRepeatMode.one &&
      handler._media.length > 1;

  bool _current(int generation) =>
      generation == _generation &&
      _canMix &&
      _playGeneration == handler._playRequestGeneration &&
      _queueRevision == handler._sessionQueueRevision;

  void onPosition(Duration position) {
    if (!_canMix || _cancelling > 0 || _starting || _fadeTimer != null) return;
    final plan = _plan;
    if (plan != null) {
      if (!_current(_generation)) {
        unawaited(cancel());
        return;
      }
      final delay = plan.start - position;
      _startTimer?.cancel();
      if (delay < const Duration(milliseconds: -350)) return;
      final generation = _generation;
      _startTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
        if (_current(generation)) unawaited(_start(generation));
      });
      return;
    }
    if (_preparing) return;
    final duration = handler.mediaItem.value?.duration;
    if (duration == null || duration < const Duration(seconds: 20)) return;
    final key =
        '${handler._playRequestGeneration}:${handler._sessionQueueRevision}';
    if (_attempt == key) return;
    _attempt = key;
    unawaited(_prepare(duration));
  }

  Future<void> _prepare(Duration duration) async {
    _preparing = true;
    final generation = ++_generation;
    _playGeneration = handler._playRequestGeneration;
    _queueRevision = handler._sessionQueueRevision;
    final index = handler._index;
    final nextIndex = index + 1 < handler._media.length
        ? index + 1
        : handler._repeatMode == AudioServiceRepeatMode.all
        ? 0
        : -1;
    final pins = <String>{};
    _preparationPins[generation] = pins;
    MusicPlaybackDeck? deck;
    MusicPlaybackDeck? effectDeck;
    RenderedMixTail? effectTail;
    final options = handler._settings.autoMixOptions;
    try {
      if (nextIndex < 0 || nextIndex == index || index < 0) return;
      final current = handler._media[index];
      final next = handler._media[nextIndex];
      if (current.isNetwork || next.isNetwork) return;
      final currentPath = await handler._resolveSource(current);
      if (currentPath == null || !_current(generation)) return;
      pins.add(currentPath);
      final nextPath = await handler._resolveSource(next);
      if (nextPath == null || !_current(generation)) return;
      pins.add(nextPath);
      deck = handler._dependencies.createDeck(
        'music-mix-$generation-${DateTime.now().microsecondsSinceEpoch}',
      );
      handler._listenToPlayer(deck);
      await deck.setReleaseMode(ReleaseMode.stop);
      await deck.setAudioContext(_musicAudioContext);
      await deck.setVolume(0);
      if (!_current(generation)) return;
      await deck.setSource(DeviceFileSource(nextPath));
      if (!_current(generation)) return;
      final nextDuration =
          await deck.getDuration() ?? next.duration ?? Duration.zero;
      final offset = options.outroWindowOffset(
        duration,
        AutoMixAnalyzer.windowSeconds,
      );
      final outro = await analyzer.analyze(currentPath, offset: offset);
      if (!_current(generation)) return;
      final intro = await analyzer.analyze(nextPath);
      if (!_current(generation)) return;
      final plan = AutoMixPlan.create(
        outgoingDuration: duration,
        incomingDuration: nextDuration,
        outro: outro,
        intro: intro,
        outroOffset: offset,
        options: options,
      );
      if (plan == null) return;
      await deck.seek(plan.incomingStart);
      await deck.setPlaybackRate(plan.rate);
      final volume = await handler._normalizationVolumeFor(
        nextPath,
        cacheKey: next.isContentUri ? next.source : null,
      );
      if (!_current(generation)) return;
      if (options.hasEffects) {
        effectTail = await renderer.render(
          currentPath,
          start: plan.start,
          duration: plan.duration,
          options: options,
        );
        if (!_current(generation)) return;
        if (effectTail != null) {
          effectDeck = handler._dependencies.createDeck(
            'music-effect-$generation-${DateTime.now().microsecondsSinceEpoch}',
          );
          handler._listenToPlayer(effectDeck);
          try {
            await effectDeck.setReleaseMode(ReleaseMode.stop);
            await effectDeck.setAudioContext(_musicAudioContext);
            await effectDeck.setVolume(0);
            await effectDeck.setSource(DeviceFileSource(effectTail.path));
          } catch (error) {
            _log.w('AutoMix effect preparation fallback: $error');
            await handler._disposeDeck(effectDeck);
            await effectTail.dispose();
            effectDeck = null;
            effectTail = null;
          }
          if (!_current(generation)) return;
        }
      }
      _effectPrepared = effectDeck;
      _effectTail = effectTail;
      effectDeck = null;
      effectTail = null;
      _prepared = deck;
      deck = null;
      _next = next;
      _nextIndex = nextIndex;
      _nextPath = nextPath;
      _nextDuration = nextDuration;
      _incomingVolume = volume;
      _mixPins.addAll(pins);
      _plan = plan;
      _log.d(
        'AutoMix prepared (${plan.beatMatched ? 'beat matched' : 'crossfade'}, '
        'rate=${plan.rate.toStringAsFixed(3)}, '
        'fallback=${plan.fallbackReason?.name ?? 'none'}, '
        'outro=${_beatSummary(outro)}, intro=${_beatSummary(intro)})',
      );
      final position = await handler._player.getCurrentPosition();
      if (position != null && _current(generation)) onPosition(position);
    } catch (error) {
      _log.w('AutoMix preparation skipped: $error');
    } finally {
      if (deck != null) await handler._disposeDeck(deck);
      if (effectDeck != null) await handler._disposeDeck(effectDeck);
      if (effectTail != null) await effectTail.dispose();
      _preparationPins.remove(generation);
      if (generation == _generation) _preparing = false;
      await handler._cleanupPendingResolvedPaths();
    }
  }

  Future<void> _start(int generation) async {
    final incoming = _prepared;
    final next = _next;
    final plan = _plan;
    if (incoming == null ||
        next == null ||
        plan == null ||
        !_current(generation)) {
      return;
    }
    if (_nextIndex >= handler._media.length ||
        !identical(handler._media[_nextIndex], next)) {
      return;
    }
    _starting = true;
    try {
      final position = await handler._player.getCurrentPosition();
      if (!_current(generation) || position == null) return;
      final delta = position - plan.start;
      if (delta < const Duration(milliseconds: -40)) {
        _starting = false;
        onPosition(position);
        return;
      }
      if (delta > const Duration(milliseconds: 350)) return;
      await incoming.resume();
      if (!_current(generation)) return;
      final original = handler._player;
      final outgoingVolume = handler._normalizationVolume;
      var outgoing = original;
      final effectDeck = _effectPrepared;
      if (effectDeck != null) {
        try {
          await effectDeck.seek(delta.isNegative ? Duration.zero : delta);
          if (!_current(generation)) return;
          await effectDeck.resume();
          if (!_current(generation)) return;
          outgoing = effectDeck;
          _effectDry = original;
        } catch (error) {
          if (!_current(generation)) return;
          _log.w('AutoMix effect fallback: $error');
          await handler._disposeDeck(effectDeck);
          await _effectTail?.dispose();
          _effectTail = null;
        }
        _effectPrepared = null;
      }
      _outgoing = outgoing;
      _prepared = null;
      _plan = null;
      handler._player = incoming;
      _setStatus(
        plan.beatMatched ? AutoMixStatus.mixing : AutoMixStatus.crossfading,
      );
      handler._index = _nextIndex;
      handler._playRequestGeneration++;
      handler._recordPlayHistory(_nextIndex);
      handler._normalizationVolume = _incomingVolume;
      handler._activeResolvedPath = next.isContentUri ? _nextPath : null;
      handler._pendingRestorePosition = null;
      rate = plan.rate;
      handler._runtime.personalization.begin(_learningTrack(next));
      handler.mediaItem.add(
        handler
            ._toMediaItem(
              next,
              resolvedSource: next.isContentUri ? _nextPath : null,
            )
            .copyWith(duration: _nextDuration),
      );
      handler._broadcastPosition(plan.incomingStart, force: true);
      handler._broadcastState(playerState: PlayerState.playing);
      unawaited(handler._persistSession(position: plan.incomingStart));
      final clock = Stopwatch()..start();
      _fadeTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        if (_writing || generation != _generation) return;
        _writing = true;
        _fadeWrite = () async {
          try {
            final levels = autoMixEnvelope(clock.elapsed, plan);
            final dry = _effectDry;
            final progress = (clock.elapsedMicroseconds / 240000).clamp(
              0.0,
              1.0,
            );
            final handover = progress * progress * (3 - 2 * progress);
            if (dry != null) {
              await dry.setVolume(
                outgoingVolume * levels.outgoing * (1 - handover),
              );
              if (generation != _generation) return;
            }
            if (_outgoing != null) {
              await outgoing.setVolume(
                outgoingVolume * levels.outgoing * (dry == null ? 1 : handover),
              );
            }
            if (generation != _generation) return;
            if (dry != null && progress >= 1) {
              _effectDry = null;
              await handler._disposeDeck(dry);
              if (generation != _generation) return;
            }
            await incoming.setVolume(_incomingVolume * levels.incoming);
            if (generation != _generation) return;
            if ((levels.rate - rate).abs() > 0.001 || levels.complete) {
              await incoming.setPlaybackRate(levels.rate);
              rate = levels.rate;
            }
            if (generation != _generation) return;
            if (clock.elapsed >= plan.duration && _outgoing != null) {
              _outgoing = null;
              await handler._disposeDeck(outgoing);
              final tail = _effectTail;
              _effectTail = null;
              await tail?.dispose();
              _setStatus(AutoMixStatus.idle);
            }
            if (levels.complete) {
              _fadeTimer?.cancel();
              _fadeTimer = null;
              rate = 1;
              _mixPins.clear();
              await handler._cleanupPendingResolvedPaths();
              handler._broadcastState();
            }
          } catch (error) {
            _log.w('AutoMix transition ended early: $error');
            // Defer cancellation until this volume write has unwound.
            scheduleMicrotask(() => unawaited(cancel()));
          } finally {
            _writing = false;
          }
        }();
      });
    } catch (error) {
      _log.w('AutoMix start skipped: $error');
    } finally {
      if (generation == _generation) _starting = false;
    }
  }

  Future<void> cancel() async {
    _generation++;
    _cancelling++;
    analyzer.cancel();
    renderer.cancel();
    _setStatus(AutoMixStatus.idle);
    _startTimer?.cancel();
    _startTimer = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final prepared = _prepared;
    final outgoing = _outgoing;
    final effectDry = _effectDry;
    final effectPrepared = _effectPrepared;
    final effectTail = _effectTail;
    final restore = outgoing != null || rate != 1;
    _prepared = null;
    _outgoing = null;
    _effectDry = null;
    _effectPrepared = null;
    _effectTail = null;
    _plan = null;
    _next = null;
    _nextPath = null;
    _nextDuration = null;
    _preparing = false;
    _starting = false;
    _attempt = null;
    try {
      await _fadeWrite;
      if (prepared != null) await handler._disposeDeck(prepared);
      if (outgoing != null) await handler._disposeDeck(outgoing);
      if (effectDry != null) await handler._disposeDeck(effectDry);
      if (effectPrepared != null) await handler._disposeDeck(effectPrepared);
      await effectTail?.dispose();
      if (restore && !handler._disposed) {
        await handler._player.setPlaybackRate(1);
        await handler._player.setVolume(handler._normalizationVolume);
      }
      rate = 1;
      _mixPins.clear();
      await handler._cleanupPendingResolvedPaths();
    } catch (error) {
      _log.w('AutoMix cleanup: $error');
    } finally {
      _cancelling--;
    }
  }

  Future<void> dispose() async {
    await cancel();
    analyzer.dispose();
    renderer.dispose();
  }
}
