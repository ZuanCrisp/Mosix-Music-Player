import 'dart:io';

/// Use a local file's embedded cover when its thumbnail is missing or only an
/// online cover is known, so playback offline still shows the file's own art.
/// Callers run this separately from preparing audio and discard stale results.
Future<String?> resolveEmbeddedArtworkUri(
  String source,
  String? artwork, {
  required Future<String?> Function(String) extract,
}) async {
  if (!source.startsWith('content://') && !source.startsWith('/')) {
    return null;
  }
  try {
    if (artwork != null && artwork.isNotEmpty) {
      final uri = Uri.parse(artwork);
      final remote = uri.scheme == 'http' || uri.scheme == 'https';
      if (uri.hasScheme && uri.scheme != 'file' && !remote) return null;
      if (!remote) {
        final path = uri.scheme == 'file' ? uri.toFilePath() : artwork;
        if (await File(path).exists()) return null;
      }
    }
    final cover = await extract(source);
    return cover == null ? null : Uri.file(cover).toString();
  } catch (_) {
    return null;
  }
}

/// A saved queue may outlive the scan directory that supplied its artwork.
/// Consult the Library only when the saved local image is missing.
Future<String?> resolveRestoredArtworkUri(
  String? artwork, {
  required Future<String?> Function() loadLibraryCoverPath,
  Future<bool> Function(String)? fileExists,
}) async {
  Future<bool> exists(String path) =>
      fileExists?.call(path) ?? File(path).exists();
  try {
    if (artwork != null && artwork.isNotEmpty) {
      final uri = Uri.parse(artwork);
      if (uri.hasScheme && uri.scheme != 'file') return artwork;
      final path = uri.scheme == 'file' ? uri.toFilePath() : artwork;
      if (await exists(path)) return artwork;
    }
    final cover = await loadLibraryCoverPath();
    if (cover == null || cover.isEmpty) return artwork;
    final path = cover.startsWith('file://')
        ? Uri.parse(cover).toFilePath()
        : cover;
    if (await exists(path)) return Uri.file(path).toString();
  } catch (_) {
    // Missing artwork or an unavailable Library must not discard playback.
  }
  return artwork;
}
