import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/artist_utils.dart';

class CrossExtensionShareResult {
  final String extensionId;
  final String displayName;
  final bool found;
  final String? url;
  final String? itemName;
  final String? itemArtists;
  final String? error;

  const CrossExtensionShareResult({
    required this.extensionId,
    required this.displayName,
    required this.found,
    this.url,
    this.itemName,
    this.itemArtists,
    this.error,
  });

  factory CrossExtensionShareResult.fromJson(Map<String, dynamic> json) {
    return CrossExtensionShareResult(
      extensionId: json['extension_id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      found: json['found'] as bool? ?? false,
      url: json['url'] as String?,
      itemName: json['item_name'] as String?,
      itemArtists: json['item_artists'] as String?,
      error: json['error'] as String?,
    );
  }
}

class CrossExtensionShareService {
  const CrossExtensionShareService();

  Future<List<CrossExtensionShareResult>> findAcrossExtensions({
    required String name,
    required String artists,
    required String type,
    required String sourceExtensionId,
  }) async {
    final queryArtist = primaryArtistName(artists);
    final results = await PlatformBridge.findCollectionAcrossExtensions(
      name: name,
      artists: queryArtist,
      type: type,
      sourceExtensionId: sourceExtensionId,
    );
    return results.map(CrossExtensionShareResult.fromJson).toList();
  }
}
