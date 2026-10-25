import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/discord_artwork_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final item = MediaItem(
    id: 'local:1',
    title: 'Song',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(seconds: 240),
    artUri: Uri.file('/private/cover.jpg'),
  );
  Track candidate({
    String name = 'Song',
    String artist = 'Artist',
    String album = 'Album',
    int duration = 240,
  }) => Track(
    id: 'catalog:1',
    name: name,
    artistName: artist,
    albumName: album,
    duration: duration,
    coverUrl: 'https://example.com/cover.jpg',
  );

  test('accepts public CDN sizing but excludes private and signed URLs', () {
    expect(
      discordPublicArtwork('https://example.com/a.jpg?w=512&format=jpg'),
      'https://example.com/a.jpg?w=512&format=jpg',
    );
    for (final url in [
      'file:///private/cover.jpg',
      'content://media/1',
      'https://localhost/a.jpg',
      'https://127.0.0.1/a.jpg',
      'https://192.168.0.2/a.jpg',
      'https://nas.local/a.jpg',
      'https://user:password@example.com/a.jpg',
      'https://example.com/a.jpg?token=secret',
      'https://example.com/a.jpg?signature=secret',
    ]) {
      expect(discordPublicArtwork(url), isNull, reason: url);
    }
  });

  test('rejects a different remix, artist, album or recording length', () {
    expect(
      discordMatchedArtwork(item, [
        candidate(name: 'Song (Remix)'),
        candidate(artist: 'Other Artist'),
        candidate(album: 'Other Album'),
        candidate(duration: 300),
      ]),
      isNull,
    );
    expect(
      discordMatchedArtwork(item, [candidate(name: ' song ')]),
      'https://example.com/cover.jpg',
    );
  });

  test('uses original public history cover without catalog requests', () async {
    final resolver = DiscordArtworkResolver(
      historyCover: (_) async => 'https://example.com/original.jpg',
      search: (_) async => throw StateError('Should not search'),
    );
    expect(await resolver.resolve(item), 'https://example.com/original.jpg');
  });

  test('default catalog searches enabled metadata extensions', () async {
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'searchTracksWithMetadataProviders');
      expect((call.arguments as Map)['include_extensions'], isTrue);
      return [
        {
          'id': 'catalog:1',
          'name': 'Song',
          'artists': 'Artist',
          'album_name': 'Album',
          'duration_ms': 240000,
          'cover_url': 'https://example.com/cover.jpg',
        },
      ];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final resolver = DiscordArtworkResolver(historyCover: (_) async => null);
    expect(await resolver.resolve(item), 'https://example.com/cover.jpg');
  });

  test('deduplicates local-cover lookups and caches catalog matches', () async {
    var lookups = 0;
    final response = Completer<List<Track>>();
    final resolver = DiscordArtworkResolver(
      historyCover: (_) async => null,
      search: (query) {
        lookups++;
        expect(query, 'Song Artist');
        return response.future;
      },
    );
    final first = resolver.resolve(item);
    final second = resolver.resolve(item);
    response.complete([candidate()]);
    expect(await first, 'https://example.com/cover.jpg');
    expect(await second, 'https://example.com/cover.jpg');
    expect(await resolver.resolve(item), 'https://example.com/cover.jpg');
    expect(lookups, 1);
  });

  test('offline lookup is optional and negatively cached', () async {
    var lookups = 0;
    final resolver = DiscordArtworkResolver(
      historyCover: (_) async => throw StateError('Storage offline'),
      search: (_) async {
        lookups++;
        throw StateError('Network offline');
      },
    );
    expect(await resolver.resolve(item), isNull);
    expect(await resolver.resolve(item), isNull);
    expect(lookups, 1);
  });
}
