import 'package:mornye/models/track.dart';
import 'package:mornye/utils/provider_resource_ids.dart';
import 'package:mornye/utils/string_utils.dart';

/// Resolve optional artwork while downloading, using only the original
/// metadata extension. Search results may omit artwork held by the album.
Future<String?> resolveDownloadMotionArtworkSource({
  required Track original,
  required Track downloaded,
  required Map<String, dynamic> result,
  required Future<Map<String, dynamic>> Function(
    String provider,
    String type,
    String id,
  )
  getMetadata,
}) async {
  String? video(Map<dynamic, dynamic> data) =>
      normalizeRemoteHttpUrl(data['header_video']?.toString());

  for (final candidate in [
    original.headerVideoUrl,
    downloaded.headerVideoUrl,
    result['header_video']?.toString(),
  ]) {
    final url = normalizeRemoteHttpUrl(candidate);
    if (url != null) return url;
  }

  final provider = resolvePreferredMetadataProviderId(
    original.source,
    original.id,
  );
  if (provider == null) return null;

  String resourceId(String id) =>
      id.startsWith('$provider:') ? id.substring(provider.length + 1) : id;
  Future<Map<String, dynamic>> metadata(String type, String id) => getMetadata(
    provider,
    type,
    resourceId(id),
  ).timeout(const Duration(seconds: 15));

  var albumId = normalizeOptionalString(original.albumId);
  if (albumId == null) {
    final trackId = normalizeOptionalString(original.id);
    if (trackId == null) return null;
    final response = await metadata('track', trackId);
    final track = response['track'];
    if (track is! Map) return null;
    final url = video(track);
    if (url != null) return url;
    albumId = normalizeOptionalString(track['album_id']?.toString());
  }
  if (albumId == null) return null;
  final response = await metadata('album', albumId);
  final album = response['album_info'] ?? response['album'];
  return (album is Map ? video(album) : null) ?? video(response);
}
