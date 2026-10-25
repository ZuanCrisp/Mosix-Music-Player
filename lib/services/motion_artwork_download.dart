import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mornye/utils/string_utils.dart';

/// Fetch a single-file HLS cover as one complete HTTP response. Passing its
/// byte-range playlist straight to FFmpeg can splice truncated segments into
/// an MP4 that still reports a successful remux.
Future<File?> downloadMotionArtworkSource(String source, String output) async {
  final uri = Uri.parse(source);
  if (!uri.path.toLowerCase().endsWith('.m3u8')) return null;
  const maxBytes = 24 << 20;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final deadline = Timer(
    const Duration(seconds: 30),
    () => client.close(force: true),
  );
  final file = File(output);
  var complete = false;
  try {
    Future<({Uri uri, String text})> playlist(Uri url) async {
      final response = await _get(client, url);
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        if (bytes.length + chunk.length > 512 << 10) {
          throw const FormatException('Artwork playlist exceeds size limit');
        }
        bytes.addAll(chunk);
      }
      for (final redirect in response.redirects) {
        url = url.resolveUri(redirect.location);
      }
      return (uri: url, text: utf8.decode(bytes));
    }

    var media = await playlist(uri);
    final variant = _videoVariant(media.text, media.uri);
    if (variant != null) media = await playlist(variant);
    final video = _singleFileVideo(media.text, media.uri);
    if (video == null || video.length > maxBytes) return null;
    final response = await _get(client, video.uri);
    if (response.contentLength > maxBytes) {
      throw const FormatException('Artwork video exceeds size limit');
    }
    final sink = await file.open(mode: FileMode.write);
    var length = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        length += chunk.length;
        if (length > maxBytes) {
          throw const FormatException('Artwork video exceeds size limit');
        }
        await sink.writeFrom(chunk);
      }
    } finally {
      await sink.close();
    }
    if (length < video.length ||
        (response.contentLength >= 0 && length != response.contentLength)) {
      throw const FormatException('Incomplete artwork video');
    }
    complete = true;
    return file;
  } finally {
    deadline.cancel();
    client.close(force: true);
    if (!complete && await file.exists()) await file.delete();
  }
}

Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 8));
  final response = await request.close().timeout(const Duration(seconds: 8));
  if (response.statusCode != HttpStatus.ok) {
    throw HttpException('Artwork HTTP ${response.statusCode}');
  }
  return response;
}

Uri? _remoteUri(Uri base, String? value) {
  if (value == null) return null;
  final normalized = normalizeRemoteHttpUrl(base.resolve(value).toString());
  return normalized == null ? null : Uri.parse(normalized);
}

Uri? _videoVariant(String playlist, Uri base) {
  var video = false;
  for (final raw in const LineSplitter().convert(playlist)) {
    final line = raw.trim();
    if (line.startsWith('#EXT-X-STREAM-INF:')) {
      // Prefer broadly supported H.264, never an I-frame preview playlist.
      video = line.contains('avc1.') || line.contains('avc3.');
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      if (video) return _remoteUri(base, line);
      video = false;
    }
  }
  return null;
}

({Uri uri, int length})? _singleFileVideo(String playlist, Uri base) {
  final lines = const LineSplitter()
      .convert(playlist)
      .map((line) => line.trim());
  if (!lines.contains('#EXTM3U') || !lines.contains('#EXT-X-ENDLIST')) {
    return null;
  }
  Uri? video;
  var offset = 0;
  var segments = 0;
  String? range;
  for (final line in lines) {
    if (line.startsWith('#EXT-X-KEY:') &&
        !RegExp(r'(?:[:,])METHOD=NONE(?:,|$)').hasMatch(line)) {
      return null;
    }
    if (line.startsWith('#EXT-X-DISCONTINUITY') ||
        line.startsWith('#EXT-X-STREAM-INF:')) {
      return null;
    }
    if (line.startsWith('#EXT-X-MAP:')) {
      if (video != null || segments != 0) return null;
      video = _remoteUri(
        base,
        RegExp(r'(?:[:,])URI="([^"]+)"').firstMatch(line)?.group(1),
      );
      final initial = RegExp(r'(?:[:,])BYTERANGE="(\d+)@0"').firstMatch(line);
      offset = int.tryParse(initial?.group(1) ?? '') ?? 0;
      if (video == null || offset <= 0) return null;
    } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
      if (range != null) return null;
      range = line.substring('#EXT-X-BYTERANGE:'.length);
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      if (video == null || _remoteUri(base, line) != video || range == null) {
        return null;
      }
      final match = RegExp(r'^(\d+)(?:@(\d+))?$').firstMatch(range);
      final length = int.tryParse(match?.group(1) ?? '') ?? 0;
      final start = match?.group(2);
      if (length <= 0 || (start != null && int.tryParse(start) != offset)) {
        return null;
      }
      offset += length;
      range = null;
      segments++;
    }
  }
  return video == null || segments == 0 || range != null
      ? null
      : (uri: video, length: offset);
}
