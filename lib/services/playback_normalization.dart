import 'dart:math';

/// Caches successful tag reads by stable media identity. Descriptor paths are
/// short-lived and require their display-name hint to select the audio parser.
class PlaybackNormalizationCache {
  final Future<Map<String, dynamic>> Function(String, {String? displayName})
  readMetadata;
  final void Function(Object)? onReadError;
  final Map<String, double> _volumes = {};
  int _generation = 0;
  static final _gainNumber = RegExp(r'-?\d+(\.\d+)?');

  PlaybackNormalizationCache({required this.readMetadata, this.onReadError});

  void invalidate(String source) {
    _volumes.remove(source);
    _generation++;
  }

  Future<double> volumeFor(
    String path, {
    String? cacheKey,
    String? displayName,
  }) async {
    final key = cacheKey ?? path;
    final cached = _volumes[key];
    if (cached != null) return cached;
    final generation = _generation;
    try {
      final metadata = await readMetadata(path, displayName: displayName);
      if (metadata['error'] != null) {
        onReadError?.call(metadata['error'] as Object);
        return 1.0;
      }
      final gain =
          _gain(metadata['replaygain_track_gain']) ??
          _gain(metadata['replaygain_album_gain']);
      final volume = gain == null
          ? 1.0
          : pow(10.0, gain / 20.0).toDouble().clamp(0.0, 1.0);
      if (generation == _generation) {
        if (_volumes.length >= 128) _volumes.remove(_volumes.keys.first);
        _volumes[key] = volume;
      }
      return volume;
    } catch (error) {
      onReadError?.call(error);
      return 1.0;
    }
  }

  static double? _gain(Object? value) {
    final match = _gainNumber.firstMatch(value?.toString() ?? '');
    return match == null ? null : double.tryParse(match.group(0)!);
  }
}
