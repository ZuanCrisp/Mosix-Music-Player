// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _DownloadQueueEmbedding on DownloadQueueNotifier {
  Future<Track> _resolveDownloadAlbumCredit(
    Track track,
    AppSettings settings,
  ) => _metadataResolver.resolveAlbumCredit(
    track,
    settings,
    ref.read(extensionProvider),
  );

  Future<String?> _embedMetadataToFile(
    String filePath,
    Track track, {
    required String format,
    String? genre,
    String? label,
    String? copyright,
    String? comment,
    String? lyricsLrc,
    String? downloadService,
    bool writeExternalLrc = true,
  }) => _metadataEmbedding.embed(
    filePath,
    track,
    settings: ref.read(settingsProvider),
    extensionState: ref.read(extensionProvider),
    format: format,
    genre: genre,
    label: label,
    copyright: copyright,
    comment: comment,
    lyricsLrc: lyricsLrc,
    downloadService: downloadService,
    writeExternalLrc: writeExternalLrc,
  );
}

bool _isUsableIndex(int? number, int? total) {
  if (number == null || number <= 0) return false;
  return total == null || total <= 0 || number <= total;
}

int? _resolvePositiveMetadataInt(int? sourceValue, int? backendValue) {
  if (sourceValue != null && sourceValue > 0) return sourceValue;
  return backendValue;
}

int? _resolveMetadataIndex({
  required int? sourceValue,
  required int? backendValue,
  required int? total,
}) {
  if (_isUsableIndex(sourceValue, total)) return sourceValue;
  if (_isUsableIndex(backendValue, total)) return backendValue;
  return sourceValue != null && sourceValue > 0 ? sourceValue : backendValue;
}

String? _resolveMetadataText(String? sourceValue, String? backendValue) {
  return normalizeOptionalString(sourceValue) ??
      normalizeOptionalString(backendValue);
}

/// Applies backend metadata fallbacks while preserving source-only fields.
Track buildTrackForMetadataEmbedding(
  Track baseTrack,
  Map<String, dynamic> backendResult,
  String? resolvedAlbumArtist,
) {
  final backendTrackNum = readPositiveInt(backendResult['track_number']);
  final backendDiscNum = readPositiveInt(backendResult['disc_number']);
  final backendTotalTracks = readPositiveInt(backendResult['total_tracks']);
  final backendTotalDiscs = readPositiveInt(backendResult['total_discs']);
  final backendYear = normalizeOptionalString(
    backendResult['release_date'] as String?,
  );
  final backendAlbum = normalizeOptionalString(
    backendResult['album'] as String?,
  );
  final backendIsrc = normalizeOptionalString(backendResult['isrc'] as String?);
  final backendCoverUrl = normalizeCoverReference(
    backendResult['cover_url']?.toString(),
  );
  final baseCoverUrl = normalizeCoverReference(baseTrack.coverUrl);
  final resolvedCoverUrl = baseCoverUrl ?? backendCoverUrl;
  final backendAlbumArtist = normalizeOptionalString(
    backendResult['album_artist'] as String?,
  );
  final backendComposer = normalizeOptionalString(
    backendResult['composer']?.toString(),
  );
  final sourceAlbumName = normalizeOptionalString(baseTrack.albumName);
  final sourceAlbumArtist = normalizeOptionalString(baseTrack.albumArtist);
  final sourceIsrc = normalizeOptionalString(baseTrack.isrc);
  final sourceReleaseDate = normalizeOptionalString(baseTrack.releaseDate);
  final sourceComposer = normalizeOptionalString(baseTrack.composer);
  final sourceAlbumType = normalizeOptionalString(baseTrack.albumType);
  final sourceGenre = normalizeOptionalString(baseTrack.genre);
  final sourceLabel = normalizeOptionalString(baseTrack.label);
  final sourceCopyright = normalizeOptionalString(baseTrack.copyright);
  final sourceComment = normalizeOptionalString(baseTrack.comment);
  final sourceUpc = normalizeOptionalString(baseTrack.upc);
  final backendGenre = normalizeOptionalString(
    backendResult['genre']?.toString(),
  );
  final backendLabel = normalizeOptionalString(
    backendResult['label']?.toString(),
  );
  final backendCopyright = normalizeOptionalString(
    backendResult['copyright']?.toString(),
  );
  final backendComment = normalizeOptionalString(
    backendResult['comment']?.toString(),
  );
  final resolvedComment = backendComment ?? sourceComment;
  final backendAlbumType = normalizeOptionalString(
    backendResult['album_type']?.toString(),
  );
  final backendUpc = normalizeOptionalString(
    (backendResult['upc'] ?? backendResult['barcode'])?.toString(),
  );
  final backendExplicit = backendResult['explicit'] == true;
  final resolvedTotalTracks = _resolvePositiveMetadataInt(
    baseTrack.totalTracks,
    backendTotalTracks,
  );
  final resolvedTotalDiscs = _resolvePositiveMetadataInt(
    baseTrack.totalDiscs,
    backendTotalDiscs,
  );
  final resolvedTrackNumber = _resolveMetadataIndex(
    sourceValue: baseTrack.trackNumber,
    backendValue: backendTrackNum,
    total: resolvedTotalTracks,
  );
  final resolvedDiscNumber = _resolveMetadataIndex(
    sourceValue: baseTrack.discNumber,
    backendValue: backendDiscNum,
    total: resolvedTotalDiscs,
  );

  final hasOverrides =
      resolvedTrackNumber != baseTrack.trackNumber ||
      resolvedDiscNumber != baseTrack.discNumber ||
      resolvedTotalTracks != baseTrack.totalTracks ||
      resolvedTotalDiscs != baseTrack.totalDiscs ||
      resolvedAlbumArtist != sourceAlbumArtist ||
      (sourceReleaseDate == null && backendYear != null) ||
      (sourceAlbumName == null && backendAlbum != null) ||
      (sourceIsrc == null && backendIsrc != null) ||
      (baseCoverUrl == null && backendCoverUrl != null) ||
      (sourceAlbumArtist == null &&
          resolvedAlbumArtist == null &&
          backendAlbumArtist != null) ||
      (sourceComposer == null && backendComposer != null) ||
      (sourceAlbumType == null && backendAlbumType != null) ||
      (sourceGenre == null && backendGenre != null) ||
      (sourceLabel == null && backendLabel != null) ||
      (sourceCopyright == null && backendCopyright != null) ||
      resolvedComment != sourceComment ||
      (baseTrack.explicit != true && backendExplicit) ||
      (sourceUpc == null && backendUpc != null);

  if (!hasOverrides) {
    return baseTrack;
  }

  return baseTrack.copyWith(
    albumName: sourceAlbumName ?? backendAlbum ?? baseTrack.albumName,
    albumArtist: resolvedAlbumArtist ?? sourceAlbumArtist ?? backendAlbumArtist,
    coverUrl: resolvedCoverUrl,
    isrc: sourceIsrc ?? backendIsrc,
    trackNumber: resolvedTrackNumber,
    discNumber: resolvedDiscNumber,
    totalDiscs: resolvedTotalDiscs,
    releaseDate: sourceReleaseDate ?? backendYear,
    albumType: sourceAlbumType ?? backendAlbumType,
    totalTracks: resolvedTotalTracks,
    composer: sourceComposer ?? backendComposer,
    genre: sourceGenre ?? backendGenre,
    label: sourceLabel ?? backendLabel,
    copyright: sourceCopyright ?? backendCopyright,
    comment: resolvedComment,
    explicit: baseTrack.explicit == true || backendExplicit
        ? true
        : baseTrack.explicit,
    upc: sourceUpc ?? backendUpc,
  );
}
