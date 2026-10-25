/// Download-only formatting preferences. Empty values preserve provider tags.
class MetadataSeparators {
  static const fields = ['artist', 'album_artist', 'composer', 'genre'];
  final String artist;
  final String albumArtist;
  final String composer;
  final String genre;

  const MetadataSeparators({
    this.artist = '',
    this.albumArtist = '',
    this.composer = '',
    this.genre = '',
  });

  factory MetadataSeparators.fromJson(Map<String, dynamic> json) =>
      MetadataSeparators(
        artist: validSeparator(json['artist']),
        albumArtist: validSeparator(json['album_artist']),
        composer: validSeparator(json['composer']),
        genre: validSeparator(json['genre']),
      );

  static String validSeparator(Object? value) {
    if (value is! String ||
        value.length > 16 ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return '';
    }
    return value;
  }

  Map<String, String> toJson() => {
    'artist': artist,
    'album_artist': albumArtist,
    'composer': composer,
    'genre': genre,
  };

  bool get isDefault => toJson().values.every((value) => value.isEmpty);

  MetadataSeparators withField(String field, String separator) =>
      MetadataSeparators.fromJson({...toJson(), field: separator});

  Map<String, String> get writerFields => {
    for (final entry in toJson().entries)
      if (entry.value.isNotEmpty) '${entry.key}_separator': entry.value,
  };
}

// Commas and semicolons delimit provider lists. Never split band-name words,
// ampersands, or slashes (AC/DC, R&B, Florence and the Machine).
final _metadataListSeparator = RegExp(r'\s*[,;]\s*');

String formatMetadataTagValue(String value, String separator) {
  if (MetadataSeparators.validSeparator(separator).isEmpty) return value;
  return value
      .split(_metadataListSeparator)
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .join(separator);
}

Map<String, String> formatDownloadTagFields(
  Map<String, String> fields,
  MetadataSeparators separators,
) {
  final selected = separators.toJson();
  return {
    for (final entry in fields.entries)
      entry.key: formatMetadataTagValue(entry.value, selected[entry.key] ?? ''),
  };
}
