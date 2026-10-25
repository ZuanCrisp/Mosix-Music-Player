import 'dart:convert';
import 'dart:isolate';

import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';

Future<List<Track>> playlistBatchFixture(int count) => Isolate.run(
  () => List.generate(
    count,
    (index) => Track(
      id: '$index',
      source: 'example',
      name: 'Track $index — 音楽 🎵',
      artistName: 'Artist ${index % 100}',
      albumName: 'Album ${index ~/ 12}',
      albumArtist: 'Album artist ${index % 100}',
      duration: 180,
      coverUrl: 'https://example.test/cover/${index ~/ 12}.jpg',
      trackNumber: index % 12 + 1,
      discNumber: 1,
      genre: 'Rock',
      comment: List.filled(12, 'Metadata $index').join(' '),
    ),
    growable: false,
  ),
);

// Production preparation before the batch-write optimization. Keep the same
// identity precedence, duplicate counting, ordering and serialization here.
({
  List<CollectionTrackEntry> entries,
  List<Map<String, String>> rows,
  int duplicates,
})
inlinePlaylistBatch(
  List<Track> tracks,
  Set<String> existingKeys,
  DateTime now,
) {
  final knownKeys = {...existingKeys};
  final entries = <CollectionTrackEntry>[];
  var duplicates = 0;
  for (final track in tracks) {
    final key = trackCollectionKey(track);
    if (!knownKeys.add(key)) {
      duplicates++;
      continue;
    }
    entries.add(CollectionTrackEntry(key: key, track: track, addedAt: now));
  }
  final rows = entries
      .map(
        (entry) => <String, String>{
          'track_key': entry.key,
          'track_json': jsonEncode(entry.track.toJson()),
          'added_at': entry.addedAt.toIso8601String(),
        },
      )
      .toList(growable: false);
  return (entries: entries, rows: rows, duplicates: duplicates);
}
