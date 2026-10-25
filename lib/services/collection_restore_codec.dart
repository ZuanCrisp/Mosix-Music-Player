import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Keeps the existing collection JSON/date codec in Dart, away from frames.
/// Native receives only a path and streams these ordered database commands.
Iterable<Map<String, dynamic>> collectionRestoreCommands(
  Map<String, dynamic> collections,
  String nowIso,
) sync* {
  Iterable<Map<String, dynamic>> entries(Object? value) sync* {
    if (value is! List) return;
    for (final entry in value.whereType<Map<Object?, Object?>>()) {
      yield Map<String, dynamic>.from(entry);
    }
  }

  Map<String, dynamic>? trackCommand(
    String kind,
    Map<String, dynamic> entry, {
    String? playlistId,
  }) {
    final key = entry['key'] as String?;
    final track = entry['track'];
    if (key == null || key.isEmpty || track is! Map) return null;
    return {
      'kind': kind,
      'values': {
        'playlist_id': ?playlistId,
        'track_key': key,
        'track_json': jsonEncode(track),
        'added_at': (entry['addedAt'] as String?) ?? nowIso,
      },
    };
  }

  for (final kind in ['wishlist', 'loved']) {
    for (final entry in entries(collections[kind])) {
      final command = trackCommand(kind, entry);
      if (command != null) yield command;
    }
  }
  for (final entry in entries(collections['favoriteArtists'])) {
    final key = entry['key'] as String?;
    if (key == null || key.isEmpty) continue;
    yield {
      'kind': 'artist',
      'values': {
        'artist_key': key,
        'artist_json': jsonEncode(entry),
        'added_at': (entry['addedAt'] as String?) ?? nowIso,
      },
    };
  }
  for (final playlist in entries(collections['playlists'])) {
    final id = playlist['id'] as String?;
    if (id == null || id.isEmpty) continue;
    final createdAt = (playlist['createdAt'] as String?) ?? nowIso;
    yield {
      'kind': 'playlist',
      'values': {
        'id': id,
        'name': (playlist['name'] as String?) ?? '',
        'cover_image_path': playlist['coverImagePath'] as String?,
        'created_at': createdAt,
        'updated_at': (playlist['updatedAt'] as String?) ?? createdAt,
      },
    };
    for (final entry in entries(playlist['tracks'])) {
      final command = trackCommand('playlist_track', entry, playlistId: id);
      if (command != null) yield command;
    }
  }
}

Future<List<Map<String, dynamic>>> prepareCollectionRestoreCommands(
  Map<String, dynamic> collections,
  String nowIso,
) => Isolate.run(
  () => collectionRestoreCommands(collections, nowIso).toList(growable: false),
);

Future<int> writeCollectionRestoreCommands(
  String path,
  Map<String, dynamic> collections,
  String nowIso,
) => Isolate.run(() {
  final output = File(path).openSync(mode: FileMode.write);
  try {
    var count = 0;
    var buffer = StringBuffer();
    for (final command in collectionRestoreCommands(collections, nowIso)) {
      buffer.writeln(jsonEncode(command));
      count++;
      if (buffer.length >= 64 * 1024) {
        output.writeStringSync(buffer.toString());
        buffer = StringBuffer();
      }
    }
    if (buffer.isNotEmpty) output.writeStringSync(buffer.toString());
    return count;
  } finally {
    output.closeSync();
  }
});
