import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/download_motion_artwork_source.dart';
import 'package:mornye/services/motion_artwork_store.dart';

void main() {
  const track = Track(
    id: 'catalog:track-1',
    source: 'catalog',
    albumId: 'catalog:album-1',
    name: 'Song',
    albumName: 'Album',
    artistName: 'Artist',
    duration: 180,
  );
  const url = 'https://example.test/artwork.m3u8';
  late List<(String, String, String)> calls;
  late Map<String, dynamic> albumResponse;
  late Map<String, dynamic> trackResponse;

  Future<Map<String, dynamic>> metadata(
    String provider,
    String type,
    String id,
  ) async {
    calls.add((provider, type, id));
    return type == 'album' ? albumResponse : trackResponse;
  }

  Future<String?> resolve({
    Track original = track,
    Track downloaded = track,
    Map<String, dynamic> result = const {},
  }) => resolveDownloadMotionArtworkSource(
    original: original,
    downloaded: downloaded,
    result: result,
    getMetadata: metadata,
  );

  setUp(() {
    calls = [];
    albumResponse = {
      'album_info': {'header_video': url},
    };
    trackResponse = {
      'track': {'album_id': 'album-1'},
    };
  });

  test(
    'search download gets artwork from its own metadata extension',
    () async {
      expect(
        await resolve(downloaded: track.copyWith(source: 'audio-provider')),
        url,
      );
      expect(calls, [('catalog', 'album', 'album-1')]);
    },
  );

  test('direct artwork does not fetch metadata', () async {
    expect(await resolve(original: track.copyWith(headerVideoUrl: url)), url);
    expect(await resolve(result: {'header_video': url}), url);
    expect(calls, isEmpty);
  });

  test('invalid direct artwork does not hide valid download artwork', () async {
    expect(
      await resolve(
        original: track.copyWith(headerVideoUrl: 'file:///private/cover.mp4'),
        result: {'header_video': url},
      ),
      url,
    );
    expect(calls, isEmpty);
  });

  test('missing album ID is hydrated from the same source track', () async {
    final original = Track.fromJson({...track.toJson(), 'albumId': null});
    expect(await resolve(original: original), url);
    expect(calls, [
      ('catalog', 'track', 'track-1'),
      ('catalog', 'album', 'album-1'),
    ]);
  });

  test(
    'missing source never selects the downloader or another extension',
    () async {
      final original = Track.fromJson({
        ...track.toJson(),
        'id': 'track-1',
        'source': null,
      });
      expect(await resolve(original: original), isNull);
      expect(calls, isEmpty);
    },
  );

  test('missing artwork never falls back to a different source', () async {
    albumResponse = {'album_info': <String, dynamic>{}};
    expect(await resolve(), isNull);
    expect(calls, [('catalog', 'album', 'album-1')]);
  });

  test('URL-handler album payload is accepted', () async {
    albumResponse = {
      'album': {'header_video': url},
    };
    expect(await resolve(), url);
  });

  test('source-only download is saved and reused offline', () async {
    final root = await Directory.systemTemp.createTemp('download-motion-');
    addTearDown(() => root.delete(recursive: true));
    var downloads = 0;
    final store = MotionArtworkStore(
      directory: () async => root,
      validate: (_) async => true,
      download: (source, output) async {
        expect(source, url);
        downloads++;
        await File(output).writeAsBytes([1, 2, 3]);
        return 0.75;
      },
    );
    const album = (album: 'Album', artist: 'Artist');
    final saved = await store.save(album, resolveSource: resolve);
    expect(saved, isNotNull);
    expect(await File.fromUri(Uri.parse(saved!.source)).exists(), isTrue);
    calls.clear();
    expect((await store.find(album))?.source, saved.source);
    expect(
      (await store.save(album, resolveSource: resolve))?.source,
      saved.source,
    );
    expect(calls, isEmpty);
    expect(downloads, 1);
  });
}
