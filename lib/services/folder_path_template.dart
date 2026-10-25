import 'dart:convert';

import 'package:mornye/services/platform_bridge.dart';

/// Expands each folder separately so metadata cannot introduce path separators.
abstract final class FolderPathTemplate {
  static const defaultTemplate = '{artist}/{album}';
  static const basicTags = [
    '{artist}',
    '{album_artist}',
    '{album}',
    '{year}',
    '{date}',
    '{title}',
    '{track}',
    '{disc}',
    '{playlist}',
    '{playlist_position}',
  ];
  static const advancedTags = [
    '{isrc}',
    '{provider}',
    '{provider_id}',
    '{quality}',
    '{track_raw}',
    '{track:02}',
    '{disc:02}',
    '{playlist_position:02}',
    '{date:%Y}',
    '{date:%Y-%m-%d}',
  ];
  static final _token = RegExp(
    r'^(artist|album_artist|album|year|date|title|track|disc|playlist|'
    r'playlist_position|playlist position|playlistPosition|position|'
    r'isrc|provider|platform|provider_id|id|quality|quality_variant|'
    r'track_raw|disc_raw|playlist_position_raw|'
    r'(track|disc|playlist_position|playlistPosition|position):0?[1-9]|'
    r'date:[^{}]+)$',
  );

  /// Accepts relative folders only, including Windows-style separators.
  static List<String> segments(String template) {
    final value = template.trim();
    if (value.isEmpty ||
        value.length > 1024 ||
        RegExp(r'^[\\/]|^[a-zA-Z]:|[\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid folder template');
    }
    final result = <String>[];
    var start = 0;
    var tokenStart = -1;
    for (var i = 0; i < value.length; i++) {
      final char = value[i];
      if (char == '{') {
        if (tokenStart >= 0) throw const FormatException('Nested placeholder');
        tokenStart = i;
      } else if (char == '}') {
        if (tokenStart < 0 ||
            !_token.hasMatch(value.substring(tokenStart + 1, i))) {
          throw const FormatException('Unknown placeholder');
        }
        tokenStart = -1;
      } else if ((char == '/' || char == r'\') && tokenStart < 0) {
        result.add(value.substring(start, i).trim());
        start = i + 1;
      }
    }
    if (tokenStart >= 0) throw const FormatException('Unclosed placeholder');
    result.add(value.substring(start).trim());
    if (result.length > 16 ||
        result.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('Invalid folder component');
    }
    return result;
  }

  static bool isValid(String template) {
    try {
      segments(template);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Uses the same native formatter as audio filenames, including date formats.
  static Future<String> expand(
    String template,
    Map<String, dynamic> metadata, {
    Future<String> Function(String, Map<String, dynamic>) buildFilename =
        PlatformBridge.buildFilename,
  }) async {
    final parts = await Future.wait(
      segments(template).map((part) async {
        final expanded = await buildFilename(part, metadata);
        final withFolderTags = expanded.replaceAllMapped(
          RegExp(r'\{(album_artist|playlist)\}'),
          (match) => metadata[match[1]]?.toString() ?? '',
        );
        return sanitizeComponent(withFolderTags);
      }),
    );
    return parts.join('/');
  }

  /// Use one portable name for local, SAF and network destinations.
  static String sanitizeComponent(String name) {
    var result = name
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    if (result.isEmpty) return 'Unknown';
    // Leave room for providers that append suffixes to directory names.
    final buffer = StringBuffer();
    var bytes = 0;
    for (final rune in result.runes) {
      final char = String.fromCharCode(rune);
      bytes += utf8.encode(char).length;
      if (bytes > 120) break;
      buffer.write(char);
    }
    result = buffer.toString().replaceAll(RegExp(r'[. ]+$'), '');
    if (RegExp(
      r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(result)) {
      result = '_$result';
    }
    return result.isEmpty ? 'Unknown' : result;
  }
}
