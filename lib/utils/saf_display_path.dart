class SafDocumentLocation {
  final String treeUri;
  final String relativeDir;
  final String fileName;

  const SafDocumentLocation({
    required this.treeUri,
    required this.relativeDir,
    required this.fileName,
  });
}

/// Resolves the writable tree and relative destination of a SAF document URI.
///
/// [Uri.pathSegments] already percent-decodes every segment. Decoding those
/// values again rejects ordinary Unicode filenames and corrupts literal `%`
/// characters, so all values below are used directly.
SafDocumentLocation? resolveSafDocumentLocation(String pathOrUri) {
  try {
    final uri = Uri.parse(pathOrUri.trim());
    if (uri.scheme != 'content' || uri.authority.isEmpty) return null;

    final segments = uri.pathSegments;
    final treeIndex = segments.indexOf('tree');
    final documentIndex = segments.indexOf('document');
    if (treeIndex < 0 ||
        treeIndex + 1 >= segments.length ||
        documentIndex < 0 ||
        documentIndex + 1 >= segments.length) {
      return null;
    }

    final treeId = segments[treeIndex + 1];
    final documentId = segments[documentIndex + 1];
    if (treeId.isEmpty || documentId.isEmpty) return null;

    final lastSlash = documentId.lastIndexOf('/');
    final fileName = lastSlash >= 0
        ? documentId.substring(lastSlash + 1)
        : documentId;
    if (fileName.isEmpty) return null;

    var relativeDir = '';
    final belongsToTree =
        documentId == treeId || documentId.startsWith('$treeId/');
    if (belongsToTree) {
      var relativePath = documentId.substring(treeId.length);
      if (relativePath.startsWith('/')) {
        relativePath = relativePath.substring(1);
      }
      final relativeSlash = relativePath.lastIndexOf('/');
      if (relativeSlash >= 0) {
        relativeDir = relativePath.substring(0, relativeSlash);
      }
    }

    return SafDocumentLocation(
      treeUri:
          '${uri.scheme}://${uri.authority}/tree/${Uri.encodeComponent(treeId)}',
      relativeDir: relativeDir,
      fileName: fileName,
    );
  } catch (_) {
    return null;
  }
}

String formatSafUriForDisplay(String pathOrUri) {
  if (pathOrUri.isEmpty || !pathOrUri.startsWith('content://')) {
    return pathOrUri;
  }

  try {
    final uri = Uri.parse(pathOrUri);
    final documentId = _safDocumentId(uri);
    if (documentId == null || documentId.isEmpty) return pathOrUri;

    final separatorIndex = documentId.indexOf(':');
    if (separatorIndex <= 0) return pathOrUri;

    final volumeId = documentId.substring(0, separatorIndex);
    final relativePath = documentId
        .substring(separatorIndex + 1)
        .replaceAll('\\', '/');

    if (volumeId.toLowerCase() == 'primary') {
      return relativePath.isEmpty
          ? '/storage/emulated/0'
          : '/storage/emulated/0/$relativePath';
    }

    // Media/document providers use opaque IDs such as audio:12345 or
    // msf:100001. Presenting those as an SD-card path is misleading.
    if (!_looksLikeStorageVolumeId(volumeId)) return pathOrUri;
    return relativePath.isEmpty ? 'SD Card' : 'SD Card/$relativePath';
  } catch (_) {
    return pathOrUri;
  }
}

String buildSafFileDisplayPath({
  required String pathOrUri,
  String? treeUri,
  String? treeDisplayPath,
  String? relativeDir,
  String? fileName,
}) {
  if (!pathOrUri.startsWith('content://')) return pathOrUri;

  final displayRoot =
      _friendlyDisplayRoot(treeDisplayPath) ??
      _friendlyDisplayRoot(formatSafUriForDisplay(treeUri?.trim() ?? ''));
  final cleanRelativeDir = _cleanDisplaySegment(relativeDir);
  final cleanFileName = _cleanDisplaySegment(fileName);

  if (displayRoot != null) {
    return [
      displayRoot.replaceAll(RegExp(r'/+$'), ''),
      ?cleanRelativeDir,
      ?cleanFileName,
    ].join('/');
  }

  return formatSafUriForDisplay(pathOrUri);
}

String? _safDocumentId(Uri uri) {
  final segments = uri.pathSegments;
  for (final marker in const ['document', 'tree']) {
    final index = segments.indexOf(marker);
    if (index != -1 && index + 1 < segments.length) {
      final raw = segments[index + 1];
      try {
        return Uri.decodeComponent(raw);
      } catch (_) {
        return raw;
      }
    }
  }
  return null;
}

bool _looksLikeStorageVolumeId(String value) {
  return RegExp(
    r'^[0-9a-f]{4}-[0-9a-f]{4}$',
    caseSensitive: false,
  ).hasMatch(value);
}

String? _friendlyDisplayRoot(String? value) {
  final normalized = value?.trim().replaceAll('\\', '/');
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.startsWith('content://')) {
    return null;
  }
  return normalized;
}

String? _cleanDisplaySegment(String? value) {
  final normalized = value?.trim().replaceAll('\\', '/');
  if (normalized == null || normalized.isEmpty) return null;
  final withoutEdges = normalized.replaceAll(RegExp(r'^/+|/+$'), '');
  return withoutEdges.isEmpty ? null : withoutEdges;
}
