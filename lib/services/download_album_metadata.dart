import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

final _log = AppLogger('DownloadAlbumMetadata');

/// Resolve the release credit independently of which tracks were selected.
/// The bridge caches album responses and coalesces concurrent album lookups.
Future<Track> resolveDownloadAlbumArtist(
  Track track,
  String providerId, {
  Future<Map<String, dynamic>> Function(String, String, String)? loadMetadata,
}) async {
  final albumId = normalizeOptionalString(track.albumId);
  if (albumId == null || providerId.isEmpty) return track;
  try {
    final response = await (loadMetadata ?? PlatformBridge.getProviderMetadata)(
      providerId,
      'album',
      albumId,
    ).timeout(const Duration(seconds: 8));
    final info = response['album_info'] ?? response['album'] ?? response;
    if (info is! Map<String, dynamic>) return track;
    final returnedId = normalizeOptionalString(info['id']?.toString());
    if (returnedId != null && returnedId != albumId) return track;
    // Only album-level credits are authoritative. Track artists may include
    // guests, and compilations/joint albums must retain their complete credit.
    String? artist;
    for (final key in ['album_artist', 'artists', 'artist']) {
      final value = info[key];
      if (value is String) artist = normalizeOptionalString(value);
      if (artist != null) break;
    }
    return artist == null || artist == track.albumArtist
        ? track
        : track.copyWith(albumArtist: artist);
  } catch (error) {
    _log.w('Album credit lookup failed; keeping track metadata: $error');
    return track;
  }
}
