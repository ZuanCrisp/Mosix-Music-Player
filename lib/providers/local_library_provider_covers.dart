part of 'local_library_provider.dart';

class LocalLibraryCoverRequest {
  final String? isrc;
  final String trackName;
  final String artistName;

  const LocalLibraryCoverRequest({
    this.isrc,
    required this.trackName,
    required this.artistName,
  });

  @override
  bool operator ==(Object other) {
    return other is LocalLibraryCoverRequest &&
        other.isrc == isrc &&
        other.trackName == trackName &&
        other.artistName == artistName;
  }

  @override
  int get hashCode => Object.hash(isrc, trackName, artistName);
}

class LocalLibraryCoverBatchRequest {
  final List<LocalLibraryCoverRequest> tracks;

  const LocalLibraryCoverBatchRequest(this.tracks);

  @override
  bool operator ==(Object other) {
    if (other is! LocalLibraryCoverBatchRequest) return false;
    if (other.tracks.length != tracks.length) return false;
    for (var i = 0; i < tracks.length; i++) {
      if (other.tracks[i] != tracks[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(tracks);
}

String? _nonEmptyCoverPath(Map<String, dynamic>? json) {
  final coverPath = json?['coverPath'] as String?;
  final trimmed = coverPath?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

final localLibraryCoverProvider = FutureProvider.autoDispose
    .family<String?, LocalLibraryCoverRequest>((ref, request) {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      return LibraryDatabase.instance
          .findExisting(
            isrc: request.isrc,
            trackName: request.trackName,
            artistName: request.artistName,
          )
          .then(_nonEmptyCoverPath);
    });

final localLibraryFirstCoverProvider = FutureProvider.autoDispose
    .family<String?, LocalLibraryCoverBatchRequest>((ref, request) async {
      ref.watch(
        localLibraryProvider.select((state) => state.loadedIndexVersion),
      );
      final rows = await LibraryDatabase.instance.findExistingBatch([
        for (final track in request.tracks)
          LocalLibraryBatchLookupRequest(
            isrc: track.isrc,
            trackName: track.trackName,
            artistName: track.artistName,
          ),
      ]);
      for (final row in rows) {
        final cover = _nonEmptyCoverPath(row);
        if (cover != null) return cover;
      }
      return null;
    });
