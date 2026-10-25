import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mosix/utils/logger.dart';

final _log = AppLogger('AudioOutput');

/// Only verified native playback reports active. File metadata alone never does.
final usbAudioStatus = ValueNotifier<UsbAudioStatus>(const UsbAudioStatus());

class UsbOutputUnavailable extends StateError {
  UsbOutputUnavailable(super.message);
}

class UsbDsdUnavailable extends UsbOutputUnavailable {
  UsbDsdUnavailable() : super('DSD requires a compatible direct USB output');
}

/// Null outside direct USB; an unavailable control must not change phone volume.
final usbHardwareVolume = ValueNotifier<UsbVolumeState?>(null);

class UsbVolumeState {
  UsbVolumeState(Map<dynamic, dynamic> data)
    : available = data['available'] == true,
      minDb = (data['minDb'] as num?)?.toDouble() ?? -90,
      maxDb = (data['maxDb'] as num?)?.toDouble() ?? 0,
      currentDb = (data['currentDb'] as num?)?.toDouble() ?? 0,
      token = (data['token'] as num?)?.toInt() ?? 0;
  final bool available;
  final double minDb, maxDb, currentDb;
  final int token;
  double get fraction => available && maxDb > minDb
      ? ((currentDb - minDb) / (maxDb - minDb)).clamp(0, 1)
      : 0;
}

Future<void> setUsbHardwareVolume(double fraction) async {
  final state = usbHardwareVolume.value;
  if (state == null || !state.available) return;
  final result = await MusicPlaybackDeck._channel
      .invokeMapMethod<String, dynamic>('volume', {
        'token': state.token,
        'db': state.minDb + fraction.clamp(0, 1) * (state.maxDb - state.minDb),
      });
  if (result != null && usbHardwareVolume.value?.token == state.token) {
    usbHardwareVolume.value = UsbVolumeState(result);
  }
}

class UsbAudioStatus {
  const UsbAudioStatus({
    this.reason = 'idle',
    this.device,
    this.sampleRate,
    this.bitDepth,
    this.transport = 'pcm',
    this.driver = 'android',
  });

  final String reason;
  final String? device;
  final int? sampleRate;
  final int? bitDepth;
  final String transport;
  final String driver;
}

/// Keeps the existing transport and AutoMix API while adding a local USB path.
/// Each prepare owns a token so delayed native events cannot affect a new song.
class MusicPlaybackDeck {
  MusicPlaybackDeck({required String playerId, bool? nativeAvailable})
    : _ordinary = AudioPlayer(playerId: playerId),
      _nativeAvailable = nativeAvailable ?? Platform.isAndroid {
    _subscriptions.addAll([
      _ordinary.onPlayerStateChanged.listen((value) {
        if (!_direct) _states.add(value);
      }),
      _ordinary.onDurationChanged.listen((value) {
        if (!_direct) _durations.add(value);
      }),
      _ordinary.onPlayerComplete.listen((_) {
        if (!_direct) _completions.add(null);
      }),
    ]);
  }

  static const _channel = MethodChannel('com.zuancrisp.mosix/usb_pcm');
  static const _events = EventChannel('com.zuancrisp.mosix/usb_pcm/events');
  static Stream<dynamic>? _nativeEvents;
  static int _nextToken = 0;
  final AudioPlayer _ordinary;
  final bool _nativeAvailable;
  final _states = StreamController<PlayerState>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _completions = StreamController<void>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  StreamSubscription<dynamic>? _nativeSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _timer;
  bool _polling = false;
  bool _direct = false;
  bool _preparing = false;
  bool _disposed = false;
  int _token = 0;
  Duration? _duration;
  DeviceFileSource? _source;
  bool _routeLost = false;
  bool _nativeStarted = false;
  bool _volumeBlocked = false;
  PlayerState _directState = PlayerState.stopped;
  UsbAudioStatus _preparedStatus = const UsbAudioStatus();

  bool get isDirect => _direct;
  bool get needsSourceReload => _direct && _routeLost;
  Future<void> cancelPreparation() async {
    if (_preparing) await stop();
  }

  PlayerState get state => _direct ? _directState : _ordinary.state;
  Stream<PlayerState> get onPlayerStateChanged => _states.stream;
  Stream<Duration> get onDurationChanged => _durations.stream;
  Stream<Duration> get onPositionChanged => _positions.stream;
  Stream<void> get onPlayerComplete => _completions.stream;

  set positionUpdater(PositionUpdater updater) {
    _ordinary.positionUpdater = updater;
    unawaited(_positionSubscription?.cancel());
    _positionSubscription = _ordinary.onPositionChanged.listen((value) {
      if (!_direct) _positions.add(value);
    });
  }

  Future<void> setReleaseMode(ReleaseMode mode) =>
      _ordinary.setReleaseMode(mode);
  Future<void> setAudioContext(AudioContext context) =>
      _ordinary.setAudioContext(context);
  Future<void> setVolume(double volume) async {
    if (!_direct) await _ordinary.setVolume(volume);
  }

  Future<void> setPlaybackRate(double rate) async {
    if (!_direct) await _ordinary.setPlaybackRate(rate);
  }

  Future<void> setNetworkSource(String url) async {
    await stop();
    _source = null;
    _routeLost = false;
    _nativeStarted = false;
    await _setOrdinarySource(UrlSource(url));
  }

  Future<void> setSource(
    DeviceFileSource source, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) async {
    await stop();
    _source = source;
    _routeLost = false;
    _nativeStarted = false;
    if (preferBitPerfect && _nativeAvailable) {
      _token = ++_nextToken;
      final preparingToken = _token;
      _preparing = true;
      _nativeSubscription ??=
          (_nativeEvents ??= _events.receiveBroadcastStream()).listen(
            _onNativeEvent,
            onError: (Object error) {
              if (_direct && !_disposed) {
                _routeLost = true;
                unawaited(pause().catchError((Object _) {}));
                usbAudioStatus.value = const UsbAudioStatus(
                  reason: 'route_changed',
                );
              }
            },
          );
      try {
        final response = await _channel
            .invokeMapMethod<String, dynamic>('prepare', {
              'path': source.path,
              'token': _token,
              'direct': directUsb,
              'allowDop': allowDop,
              'allowFixedVolume': allowFixedVolume,
              'dapExclusive': dapExclusive,
              'requiresDsd': requiresDsd,
            });
        if (_disposed || preparingToken != _token) return;
        if (response?['ready'] == true) {
          _volumeBlocked = response?['volumeBlocked'] == true;
          final volume = response?['volume'];
          usbHardwareVolume.value = volume is Map
              ? UsbVolumeState(volume)
              : null;
          _direct = true;
          _directState = PlayerState.stopped;
          _duration = Duration(
            milliseconds: (response?['duration'] as num?)?.toInt() ?? 0,
          );
          _preparedStatus = UsbAudioStatus(
            reason: 'active',
            device: response?['device'] as String?,
            sampleRate: (response?['sampleRate'] as num?)?.toInt(),
            bitDepth: (response?['bitDepth'] as num?)?.toInt(),
            transport: response?['transport'] as String? ?? 'pcm',
            driver: response?['driver'] as String? ?? 'android',
          );
          usbAudioStatus.value = UsbAudioStatus(
            reason: _volumeBlocked ? 'volume_unavailable' : 'ready',
          );
          _durations.add(_duration!);
          return;
        }
        usbAudioStatus.value = UsbAudioStatus(
          reason: response?['reason'] as String? ?? 'unsupported',
        );
        final detail = response?['detail'] as String?;
        if (detail != null && detail.isNotEmpty) {
          _log.w('Native output ${usbAudioStatus.value.reason}: $detail');
        }
        if (response?['fatal'] == true) {
          throw UsbDsdUnavailable();
        }
      } on PlatformException {
        if (_disposed || preparingToken != _token) return;
        usbAudioStatus.value = const UsbAudioStatus(reason: 'unsupported');
      } on MissingPluginException {
        if (_disposed || preparingToken != _token) return;
        usbAudioStatus.value = const UsbAudioStatus(reason: 'unsupported');
      } finally {
        if (preparingToken == _token) _preparing = false;
      }
    }
    if (requiresDsd) {
      usbAudioStatus.value = const UsbAudioStatus(reason: 'dsd_unsupported');
      throw UsbDsdUnavailable();
    }
    await _setOrdinarySource(source);
  }

  Future<void> _setOrdinarySource(Source source) async {
    // stop mode retains the native source. Android can reuse the same
    // /proc/self/fd number for a different SAF file, so URL equality must not
    // reuse the previous MediaPlayer or its pending preparation callbacks.
    await _ordinary.release();
    await _ordinary.setSource(source);
  }

  void _onNativeEvent(dynamic event) {
    if (_disposed || !_direct || event is! Map || event['token'] != _token) {
      return;
    }
    switch (event['event']) {
      case 'active':
        usbAudioStatus.value = _preparedStatus;
      case 'paused':
        _routeLost = true;
        _timer?.cancel();
        _setState(PlayerState.paused);
        usbAudioStatus.value = const UsbAudioStatus(reason: 'route_changed');
      case 'complete':
        _timer?.cancel();
        _setState(PlayerState.completed);
        _completions.add(null);
    }
  }

  void _setState(PlayerState value) {
    _directState = value;
    if (!_disposed) _states.add(value);
  }

  Future<void> resume() async {
    if (!_direct) return _ordinary.resume();
    if (_volumeBlocked) {
      usbAudioStatus.value = const UsbAudioStatus(reason: 'volume_unavailable');
      throw UsbOutputUnavailable(
        'DAC hardware volume unavailable; check audio output settings',
      );
    }
    final token = _token;
    // Before first playback the SAF lease is still open. After playback starts,
    // reconnect through the handler to obtain a fresh lease for the same song.
    try {
      if (_routeLost) throw PlatformException(code: 'route_changed');
      await _channel.invokeMethod<void>('resume');
    } on PlatformException {
      if (token != _token || !_direct || _disposed) return;
      if (_preparedStatus.driver == 'usb_direct') {
        _routeLost = true;
        _setState(PlayerState.paused);
        usbAudioStatus.value = const UsbAudioStatus(reason: 'route_changed');
        throw UsbOutputUnavailable(
          'Direct USB output changed; reconnect before playing',
        );
      }
      if (_nativeStarted) {
        _routeLost = true;
        _setState(PlayerState.paused);
        usbAudioStatus.value = const UsbAudioStatus(reason: 'route_changed');
        rethrow;
      }
      if (_preparedStatus.transport != 'pcm') {
        _routeLost = true;
        _setState(PlayerState.paused);
        usbAudioStatus.value = const UsbAudioStatus(reason: 'dsd_unsupported');
        throw UsbDsdUnavailable();
      }
      final source = _source;
      final position = await getCurrentPosition() ?? Duration.zero;
      await stop();
      usbAudioStatus.value = const UsbAudioStatus(reason: 'unsupported');
      if (source == null || _disposed) return;
      await _ordinary.setVolume(1);
      await _ordinary.setSource(source);
      if (position > Duration.zero) await _ordinary.seek(position);
      return _ordinary.resume();
    }
    if (_disposed || token != _token || !_direct) return;
    _nativeStarted = true;
    _setState(PlayerState.playing);
    usbAudioStatus.value = _preparedStatus;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (_polling || _disposed) return;
      _polling = true;
      final token = _token;
      try {
        final position = await getCurrentPosition();
        if (!_disposed && _direct && token == _token && position != null) {
          _positions.add(position);
        }
      } on PlatformException {
        // Route failures arrive through the native event stream.
      } finally {
        _polling = false;
      }
    });
  }

  Future<void> pause() async {
    if (!_direct) return _ordinary.pause();
    final token = _token;
    _timer?.cancel();
    await _channel.invokeMethod<void>('pause');
    if (token == _token && _direct) _setState(PlayerState.paused);
  }

  Future<void> seek(Duration position) async {
    if (!_direct) return _ordinary.seek(position);
    final token = _token;
    await _channel.invokeMethod<void>('seek', {
      'position': position.inMilliseconds,
    });
    if (!_disposed && token == _token && _direct) _positions.add(position);
  }

  Future<Duration?> getCurrentPosition() async {
    if (!_direct) return _ordinary.getCurrentPosition();
    final milliseconds = await _channel.invokeMethod<int>('position');
    return milliseconds == null ? null : Duration(milliseconds: milliseconds);
  }

  Future<Duration?> getDuration() =>
      _direct ? Future.value(_duration) : _ordinary.getDuration();

  Future<void> stop() async {
    _timer?.cancel();
    if (_direct || _preparing) {
      _token = ++_nextToken;
      _preparing = false;
      await _channel.invokeMethod<void>('stop');
      _setState(PlayerState.stopped);
      _direct = false;
      _volumeBlocked = false;
      usbHardwareVolume.value = null;
      usbAudioStatus.value = const UsbAudioStatus();
    }
    await _ordinary.stop();
  }

  Future<void> dispose() async {
    await stop();
    _disposed = true;
    await _nativeSubscription?.cancel();
    await _positionSubscription?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _ordinary.dispose();
    await _states.close();
    await _durations.close();
    await _positions.close();
    await _completions.close();
  }
}
