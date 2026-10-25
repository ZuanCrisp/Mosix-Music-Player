import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/services/download_album_metadata.dart';
import 'package:mornye/services/download_track_metadata.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

class DownloadMetadataLookup {
  final Track track;
  final String? deezerTrackId;

  const DownloadMetadataLookup({required this.track, this.deezerTrackId});
}

class DownloadExtendedMetadata {
  final String? genre;
  final String? label;
  final String? copyright;

  const DownloadExtendedMetadata({this.genre, this.label, this.copyright});
}

/// Resolves download tags and identifiers from explicit provider snapshots.
/// Callers retain stage ordering, cancellation and queue state ownership.
class DownloadMetadataResolver {
  static final _log = AppLogger('DownloadMetadata');
  static final _isrcPattern = RegExp(r'^[A-Z]{2}[A-Z0-9]{3}\d{7}$');
  static final _featuredArtistPattern = RegExp(
    r'\s*[,;]\s*|\s+(?:feat\.?|ft\.?|featuring|with|x)\s+',
    caseSensitive: false,
  );
  final Future<Map<String, dynamic>> Function(String, String, String)
  loadMetadata;

  DownloadMetadataResolver({
    this.loadMetadata = PlatformBridge.getProviderMetadata,
  });

  static bool isValidIsrc(String value) =>
      _isrcPattern.hasMatch(value.toUpperCase());

  Future<Track> prepareSourceTrack(Track track) async {
    if (!track.id.startsWith('deezer:')) return track;
    final id = track.id.substring('deezer:'.length);
    final enriched = await enrichIncompleteDownloadTrack(
      track,
      'deezer',
      id,
      loadMetadata: loadMetadata,
    );
    return identical(enriched, track) ? track : enriched.copyWith(deezerId: id);
  }

  Future<Track> resolveAlbumCredit(
    Track track,
    AppSettings settings,
    ExtensionState extensionState,
  ) async {
    if (!settings.embedMetadata ||
        normalizeOptionalString(track.albumId) == null) {
      return track;
    }
    final source =
        normalizeOptionalString(track.source)?.toLowerCase() ??
        (track.id.contains(':') ? track.id.split(':').first.toLowerCase() : '');
    if (source.isEmpty) return track;
    final providers = extensionState.extensions.where(
      (extension) => extension.enabled && extension.hasMetadataProvider,
    );
    final provider =
        providers
            .where((extension) => extension.id.toLowerCase() == source)
            .firstOrNull ??
        providers
            .where(
              (extension) =>
                  extension.replacesBuiltInProviders.contains(source),
            )
            .firstOrNull;
    // Album IDs belong to the source release, even when supplemental
    // cross-provider enrichment is disabled. Never use an unrelated fallback.
    return provider == null
        ? track
        : resolveDownloadAlbumArtist(
            track,
            provider.id,
            loadMetadata: loadMetadata,
          );
  }

  static String? albumArtistForMetadata(Track track, AppSettings settings) {
    final artist = normalizeOptionalString(track.albumArtist);
    if (artist == null || !settings.filterContributingArtistsInAlbumArtist) {
      return artist;
    }
    final match = _featuredArtistPattern.firstMatch(artist);
    return match != null && match.start > 0
        ? normalizeOptionalString(artist.substring(0, match.start))
        : artist;
  }

  static bool _providerFlag(
    ExtensionState state,
    String? source,
    String? service,
    bool Function(Extension) matches,
  ) {
    final candidates = {
      for (final value in [source, service])
        if (normalizeOptionalString(value) case final String candidate)
          candidate.toLowerCase(),
    };
    return state.extensions.any(
      (extension) =>
          extension.enabled &&
          candidates.contains(extension.id.toLowerCase()) &&
          matches(extension),
    );
  }

  static bool shouldSkipLyrics(
    ExtensionState state,
    String? source,
    String? service,
  ) => _providerFlag(
    state,
    source,
    service,
    (extension) => extension.skipLyrics,
  );

  static bool shouldSkipMetadataEnrichment(
    ExtensionState state,
    String? source,
    String? service,
  ) => _providerFlag(
    state,
    source,
    service,
    (extension) => extension.skipMetadataEnrichment,
  );

  static String? knownDeezerTrackId(Track track) =>
      normalizeOptionalString(track.deezerId) ??
      (track.id.startsWith('deezer:')
          ? normalizeOptionalString(track.id.substring('deezer:'.length))
          : null) ??
      normalizeOptionalString(track.availability?.deezerId);

  Future<String?> _searchByIsrc(
    String? isrc, {
    required String lookupContext,
    required String itemId,
  }) async {
    final normalized = normalizeOptionalString(isrc);
    if (normalized == null || !isValidIsrc(normalized)) return null;
    try {
      _log.d('No Deezer ID, searching by $lookupContext: $normalized');
      final result = await PlatformBridge.searchDeezerByISRC(
        normalized,
        itemId: itemId,
      );
      if (result['success'] == true && result['track_id'] != null) {
        return result['track_id'].toString();
      }
    } catch (error) {
      _log.w('Failed to search Deezer by $lookupContext: $error');
    }
    return null;
  }

  Future<String?> resolveDeezerIdFromKnownOrIsrc(
    Track track,
    String itemId, {
    required String lookupContext,
  }) async {
    final known = knownDeezerTrackId(track);
    if (known != null || !isValidIsrc(track.isrc ?? '')) return known;
    return _searchByIsrc(
      track.isrc,
      lookupContext: lookupContext,
      itemId: itemId,
    );
  }

  Future<DownloadMetadataLookup> resolveDeezerIdViaProviderIfNeeded(
    Track track,
    String? deezerTrackId,
    String itemId, {
    required ExtensionState extensionState,
  }) async {
    if (deezerTrackId != null ||
        isValidIsrc(track.isrc ?? '') ||
        !(track.id.startsWith('tidal:') || track.id.startsWith('qobuz:'))) {
      return DownloadMetadataLookup(track: track, deezerTrackId: deezerTrackId);
    }
    try {
      final colon = track.id.indexOf(':');
      final provider = track.id.substring(0, colon);
      final effective = resolveEffectiveMetadataProvider(
        provider,
        extensionState,
      );
      final response = await loadMetadata(
        effective.isEmpty ? provider : effective,
        'track',
        track.id.substring(colon + 1),
      );
      final data = response['track'];
      if (data is Map<String, dynamic>) {
        final isrc = normalizeOptionalString(data['isrc'] as String?);
        if (isrc != null && isValidIsrc(isrc)) {
          track = _copyResolvedMetadata(track, data);
          deezerTrackId = await _searchByIsrc(
            isrc,
            lookupContext: '${effective.isEmpty ? provider : effective} ISRC',
            itemId: itemId,
          );
          if (deezerTrackId != null) {
            track = copyTrackWithResolvedMetadata(
              track,
              deezerId: deezerTrackId,
            );
          }
        }
      }
    } catch (error) {
      _log.w('Failed to resolve ISRC from provider: $error');
    }
    return DownloadMetadataLookup(
      track: track,
      deezerTrackId: deezerTrackId ?? knownDeezerTrackId(track),
    );
  }

  Future<DownloadMetadataLookup> resolveSpotifyTrackViaDeezer(
    Track track,
  ) async {
    final original = track;
    String? deezerTrackId;
    try {
      final spotifyId = track.id.startsWith('spotify:track:')
          ? track.id.split(':').last
          : track.id;
      final response = await PlatformBridge.convertSpotifyToDeezer(
        'track',
        spotifyId,
      );
      final data = response['track'];
      if (data is Map<String, dynamic>) {
        final rawId = data['spotify_id'] as String?;
        deezerTrackId = rawId != null && rawId.startsWith('deezer:')
            ? rawId.split(':')[1]
            : response['id']?.toString();
        final isrc = normalizeOptionalString(data['isrc'] as String?);
        final needsEnrich =
            (track.releaseDate == null &&
                normalizeOptionalString(data['release_date'] as String?) !=
                    null) ||
            (!isValidIsrc(track.isrc ?? '') && isrc != null) ||
            [
              (track.trackNumber, data['track_number'] as int?),
              (track.totalTracks, data['total_tracks'] as int?),
              (track.discNumber, data['disc_number'] as int?),
              (track.totalDiscs, data['total_discs'] as int?),
            ].any((pair) => (pair.$1 ?? 0) <= 0 && (pair.$2 ?? 0) > 0) ||
            ((track.composer == null || track.composer!.isEmpty) &&
                normalizeOptionalString(data['composer'] as String?) != null) ||
            deezerTrackId != null;
        if (needsEnrich) {
          track = _copyResolvedMetadata(track, data, deezerId: deezerTrackId);
        }
      } else if (response['id'] != null) {
        deezerTrackId = response['id'].toString();
        track = copyTrackWithResolvedMetadata(track, deezerId: deezerTrackId);
      }
    } catch (error) {
      _log.w('Failed to convert Spotify to Deezer via SongLink: $error');
      track = original;
      deezerTrackId = null;
    }
    return DownloadMetadataLookup(
      track: track,
      deezerTrackId: deezerTrackId ?? knownDeezerTrackId(track),
    );
  }

  Future<DownloadExtendedMetadata?> loadExtendedMetadataForDeezerId(
    String? id,
  ) async {
    if (id == null || id.isEmpty) return null;
    try {
      final data = await PlatformBridge.getDeezerExtendedMetadata(id);
      return DownloadExtendedMetadata(
        genre: normalizeOptionalString(data?['genre']),
        label: normalizeOptionalString(data?['label']),
        copyright: normalizeOptionalString(data?['copyright']),
      );
    } catch (error) {
      _log.w('Failed to fetch extended metadata from Deezer: $error');
      return const DownloadExtendedMetadata();
    }
  }

  Track _copyResolvedMetadata(
    Track track,
    Map<String, dynamic> data, {
    String? deezerId,
  }) => copyTrackWithResolvedMetadata(
    track,
    resolvedIsrc: data['isrc'] as String?,
    releaseDate: data['release_date'] as String?,
    trackNumber: data['track_number'] as int?,
    totalTracks: data['total_tracks'] as int?,
    discNumber: data['disc_number'] as int?,
    totalDiscs: data['total_discs'] as int?,
    composer: data['composer'] as String?,
    deezerId: deezerId,
  );
}

/// Fills resolved identifiers and missing metadata without dropping other tags.
Track copyTrackWithResolvedMetadata(
  Track track, {
  String? resolvedIsrc,
  int? trackNumber,
  int? totalTracks,
  int? discNumber,
  int? totalDiscs,
  String? releaseDate,
  String? deezerId,
  String? composer,
}) {
  final normalizedIsrc = normalizeOptionalString(resolvedIsrc);
  return track.copyWith(
    coverUrl: normalizeCoverReference(track.coverUrl),
    isrc:
        normalizedIsrc != null &&
            DownloadMetadataResolver.isValidIsrc(normalizedIsrc)
        ? normalizedIsrc
        : track.isrc,
    trackNumber: (track.trackNumber ?? 0) > 0 ? track.trackNumber : trackNumber,
    discNumber: (track.discNumber ?? 0) > 0 ? track.discNumber : discNumber,
    totalDiscs: (track.totalDiscs ?? 0) > 0 ? track.totalDiscs : totalDiscs,
    releaseDate: track.releaseDate ?? normalizeOptionalString(releaseDate),
    deezerId: deezerId ?? track.deezerId,
    totalTracks: (track.totalTracks ?? 0) > 0 ? track.totalTracks : totalTracks,
    composer: (track.composer?.isNotEmpty ?? false)
        ? track.composer
        : normalizeOptionalString(composer),
  );
}
