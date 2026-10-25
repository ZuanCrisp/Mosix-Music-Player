import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:mosix/services/playback_metadata.dart';
import 'package:mosix/utils/int_utils.dart';
import 'package:mosix/utils/logger.dart';
import 'package:mosix/utils/lyrics_parser.dart';

final _log = AppLogger('PlayerMetadata');

/// Owns file metadata and lyrics for the full player. Requests are scoped to
/// the current queue item so a late probe cannot replace another track's data.
class PlayerMetadataController extends ChangeNotifier {
  PlayerMetadataController({
    PlaybackMetadataReader? readMetadata,
    Future<ParsedLyrics> Function(String?)? parseLyrics,
  }) : _readMetadata = readMetadata ?? readPlaybackFileMetadataWithRetry,
       _parseLyrics = parseLyrics ?? LyricsParser.parseAsyncNative;

  final PlaybackMetadataReader _readMetadata;
  final Future<ParsedLyrics> Function(String?) _parseLyrics;
  (String, String, String?)? _requestKey;
  String? _loadedPath;
  Map<String, dynamic> _fallback = const {};
  int _generation = 0;
  int _metadataRevision = 0;
  String _lyricsRaw = '';
  bool _probePending = false;
  bool _disposed = false;

  String? get source => _requestKey?.$2;
  Map<String, dynamic>? _metadata;
  ParsedLyrics _lyrics = ParsedLyrics.empty;
  bool _loading = false;
  Map<String, dynamic>? get metadata => _metadata;
  ParsedLyrics get lyrics => _lyrics;
  bool get loading => _loading;

  Future<void> load(
    MediaItem? item, {
    bool inspectUnresolvedContentUri = false,
  }) async {
    if (_disposed) return;
    final source = item?.extras?['source']?.toString() ?? '';
    if (item == null || source.isEmpty) {
      if (_requestKey == null) return;
      _generation++;
      _probePending = false;
      _requestKey = null;
      _loadedPath = null;
      final pending = _replaceMetadata(const {});
      if (pending != null) await pending;
      return;
    }
    final resolvedSource = item.extras?['resolvedSource']?.toString().trim();
    final key = (item.id, source, resolvedSource);
    final sameItem = key == _requestKey;
    _fallback = Map.unmodifiable(playbackAudioMetadataFromMediaItem(item));
    if (!sameItem) {
      _generation++;
      _probePending = false;
      _requestKey = key;
      _loadedPath = null;
    }
    if (const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme)) {
      _loadedPath = source;
      final pending = _replaceMetadata(_fallback);
      if (pending != null) await pending;
      return;
    }
    final path = _metadataPath(source, resolvedSource);
    final unresolved = path == source && source.startsWith('content://');
    if (sameItem) {
      if (metadata == null && _fallback.isNotEmpty) {
        _metadata = _fallback;
        notifyListeners();
      }
      if (loading || _loadedPath == path) return;
    } else {
      final pending = _replaceMetadata(_fallback);
      // A fallback parse must never postpone the file probe. Its revision
      // guard discards it as soon as richer metadata supersedes it.
      if (pending != null) unawaited(pending);
    }
    // Opening the player must not copy an unresolved SAF document. Lyrics
    // requests may inspect it until playback publishes its resolved source.
    if (unresolved && !inspectUnresolvedContentUri) return;
    _probePending = true;
    _loading = true;
    notifyListeners();
    final generation = _generation;
    try {
      final probed = await _readMetadata(path);
      if (_disposed || generation != _generation) return;
      _probePending = false;
      _loadedPath = path;
      final pending = _replaceMetadata(
        mergePlaybackFileMetadata(_fallback, probed),
      );
      if (pending != null) await pending;
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _probePending = false;
      _log.w('Failed to read metadata: $error');
      final pending = _replaceMetadata(_fallback);
      if (pending != null) await pending;
    }
  }

  Future<void>? _replaceMetadata(Map<String, dynamic> value) {
    final revision = ++_metadataRevision;
    final raw = (value['lyrics'] ?? '').toString();
    // Empty fallback metadata stays synchronous, so file probes start at the
    // same point and changing tracks clears the previous lyrics immediately.
    if (raw.isEmpty) {
      _publishMetadata(value, ParsedLyrics.empty);
      return null;
    }
    _metadata = value.isEmpty ? null : Map.unmodifiable(value);
    if (raw != _lyricsRaw) _lyrics = ParsedLyrics.empty;
    _loading = true;
    notifyListeners();
    return _parseAndReplaceMetadata(value, raw, _generation, revision);
  }

  Future<void> _parseAndReplaceMetadata(
    Map<String, dynamic> value,
    String raw,
    int generation,
    int revision,
  ) async {
    try {
      final parsed = await _parseLyrics(raw);
      if (_disposed ||
          generation != _generation ||
          revision != _metadataRevision) {
        return;
      }
      _publishMetadata(value, parsed, raw: raw);
    } catch (error) {
      if (_disposed ||
          generation != _generation ||
          revision != _metadataRevision) {
        return;
      }
      _log.w('Failed to parse lyrics: $error');
      _publishMetadata(value, ParsedLyrics.empty);
    }
  }

  void _publishMetadata(
    Map<String, dynamic> value,
    ParsedLyrics parsed, {
    String raw = '',
  }) {
    _metadata = value.isEmpty ? null : Map.unmodifiable(value);
    _lyrics = parsed;
    _lyricsRaw = raw;
    _loading = _probePending;
    notifyListeners();
  }

  String _metadataPath(String source, String? resolved) =>
      !source.startsWith('network://') && resolved?.isNotEmpty == true
      ? resolved!
      : source;

  Map<String, dynamic> detailsSnapshot(MediaItem? item) {
    if (item == null) return const {};
    final source = item.extras?['source']?.toString() ?? '';
    final resolved = item.extras?['resolvedSource']?.toString().trim();
    final sameItem = _requestKey == (item.id, source, resolved);
    return {
      'title': item.title,
      'artist': item.artist ?? '',
      'album': item.album ?? '',
      ...playbackAudioMetadataFromMediaItem(item),
      if (sameItem) ...?metadata,
    };
  }

  /// A details sheet owns this snapshot, independently of later track changes.
  /// Probing an unresolved document here does not alter the lyrics lifecycle.
  Future<Map<String, dynamic>> readDetails(MediaItem? item) async {
    final fallback = detailsSnapshot(item);
    final source = item?.extras?['source']?.toString() ?? '';
    final resolved = item?.extras?['resolvedSource']?.toString().trim();
    final path = _metadataPath(source, resolved);
    if (_disposed ||
        path.isEmpty ||
        const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme) ||
        (_requestKey == (item?.id, source, resolved) && _loadedPath == path)) {
      return fallback;
    }
    try {
      return mergePlaybackFileMetadata(fallback, await _readMetadata(path));
    } catch (error) {
      _log.w('Failed to read details metadata: $error');
      return fallback;
    }
  }

  ({String? writers, String? provider}) get credits {
    String? field(String key) {
      final value = metadata?[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    return (
      writers: lyrics.writers ?? field('lyricist') ?? field('composer'),
      provider: lyrics.provider ?? field('lyrics_provider'),
    );
  }

  String? get qualityLabel {
    final meta = metadata;
    if (meta == null) return null;
    final parts = <String>[];
    final format = (meta['format'] ?? meta['audio_codec'] ?? '')
        .toString()
        .trim()
        .toUpperCase();
    if (format.isNotEmpty) parts.add(format);
    final bitDepth = readPositiveInt(meta['bit_depth']) ?? 0;
    if (bitDepth > 0) parts.add('$bitDepth-bit');
    final sampleRate = readPositiveInt(meta['sample_rate']) ?? 0;
    if (sampleRate > 0) {
      final khz = sampleRate / 1000;
      parts.add(
        '${khz.toStringAsFixed(khz == khz.roundToDouble() ? 0 : 1)} kHz',
      );
    }
    final bitrate = readPositiveInt(meta['bitrate']) ?? 0;
    if (bitDepth == 0 && bitrate > 0) parts.add('$bitrate kbps');
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
