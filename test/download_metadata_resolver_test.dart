import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/services/download_metadata_resolver.dart';

Extension provider(
  String id, {
  bool enabled = true,
  bool skipLyrics = false,
  bool skipMetadataEnrichment = false,
  List<String> replaces = const [],
}) => Extension(
  id: id,
  name: id,
  displayName: 'Example Provider',
  version: '1.0.0',
  description: '',
  enabled: enabled,
  status: 'ready',
  hasMetadataProvider: true,
  skipLyrics: skipLyrics,
  skipMetadataEnrichment: skipMetadataEnrichment,
  capabilities: {'replacesBuiltInProviders': replaces},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const track = Track(
    id: 'example:recording',
    source: 'example',
    name: 'Song (Remix)',
    artistName: 'Artist, Guest',
    albumName: 'Album',
    albumId: 'album-1',
    albumArtist: 'Artist, Guest',
    duration: 180,
    previewUrl: 'https://example.test/preview',
  );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('manifest flags use enabled source or service with normalized case', () {
    final state = ExtensionState(
      extensions: [
        provider('Example', skipLyrics: true),
        provider('downloader', skipMetadataEnrichment: true),
        provider(
          'disabled',
          enabled: false,
          skipLyrics: true,
          skipMetadataEnrichment: true,
        ),
      ],
    );
    expect(
      DownloadMetadataResolver.shouldSkipLyrics(state, ' example ', null),
      isTrue,
    );
    expect(
      DownloadMetadataResolver.shouldSkipMetadataEnrichment(
        state,
        null,
        ' DOWNLOADER ',
      ),
      isTrue,
    );
    expect(
      DownloadMetadataResolver.shouldSkipLyrics(state, 'disabled', ''),
      isFalse,
    );
    expect(
      DownloadMetadataResolver.shouldSkipMetadataEnrichment(
        state,
        'disabled',
        'unknown',
      ),
      isFalse,
    );
    expect(
      DownloadMetadataResolver.shouldSkipLyrics(state, null, '  '),
      isFalse,
    );
  });

  test(
    'album credits only use the source or its declared replacement',
    () async {
      final calls = <(String, String, String)>[];
      final resolver = DownloadMetadataResolver(
        loadMetadata: (provider, kind, id) async {
          calls.add((provider, kind, id));
          return {
            'album_info': {'id': id, 'artists': 'Artist'},
          };
        },
      );
      final unrelated = ExtensionState(extensions: [provider('unrelated')]);
      expect(
        await resolver.resolveAlbumCredit(
          track,
          const AppSettings(),
          unrelated,
        ),
        same(track),
      );
      expect(
        await resolver.resolveAlbumCredit(
          track,
          const AppSettings(embedMetadata: false),
          ExtensionState(extensions: [provider('example')]),
        ),
        same(track),
      );
      expect(calls, isEmpty);
      final direct = await resolver.resolveAlbumCredit(
        track,
        const AppSettings(),
        ExtensionState(
          extensions: [provider('Example', skipMetadataEnrichment: true)],
        ),
      );
      expect(direct.albumArtist, 'Artist');
      expect(direct.artistName, track.artistName);
      final replaced = await resolver.resolveAlbumCredit(
        track,
        const AppSettings(),
        ExtensionState(
          extensions: [
            provider('replacement', replaces: ['example']),
          ],
        ),
      );
      expect(replaced.albumArtist, 'Artist');
      expect(calls, [
        ('Example', 'album', 'album-1'),
        ('replacement', 'album', 'album-1'),
      ]);
    },
  );

  test(
    'album filtering keeps joint credits and applies existing guest separators',
    () {
      const settings = AppSettings(
        filterContributingArtistsInAlbumArtist: true,
      );
      expect(
        DownloadMetadataResolver.albumArtistForMetadata(
          track,
          const AppSettings(),
        ),
        'Artist, Guest',
      );
      expect(
        DownloadMetadataResolver.albumArtistForMetadata(track, settings),
        'Artist',
      );
      expect(
        DownloadMetadataResolver.albumArtistForMetadata(
          track.copyWith(albumArtist: 'Band & Partner'),
          settings,
        ),
        'Band & Partner',
      );
      expect(
        DownloadMetadataResolver.albumArtistForMetadata(
          track.copyWith(albumArtist: ' Artist with Guest '),
          settings,
        ),
        'Artist',
      );
    },
  );

  test(
    'legacy identifiers retain explicit, source and availability precedence',
    () {
      final legacy = track.copyWith(
        id: 'deezer: source-id ',
        deezerId: ' explicit-id ',
        availability: const ServiceAvailability(deezerId: 'available-id'),
      );
      expect(
        DownloadMetadataResolver.knownDeezerTrackId(legacy),
        'explicit-id',
      );
      expect(
        DownloadMetadataResolver.knownDeezerTrackId(
          legacy.copyWith(deezerId: ' '),
        ),
        'source-id',
      );
      expect(
        DownloadMetadataResolver.knownDeezerTrackId(
          legacy.copyWith(id: 'example:recording', deezerId: ' '),
        ),
        'available-id',
      );
    },
  );

  test(
    'source preparation enriches before naming and preserves selected recording',
    () async {
      final resolver = DownloadMetadataResolver(
        loadMetadata: (provider, kind, id) async {
          expect((provider, kind, id), ('deezer', 'track', 'source-id'));
          return {
            'track': {
              'name': 'Other recording',
              'album_artist': 'Artist',
              'composer': 'Composer',
              'track_number': 2,
              'total_tracks': 8,
              'isrc': 'USAAA2400001',
            },
          };
        },
      );
      expect(await resolver.prepareSourceTrack(track), same(track));
      final prepared = await resolver.prepareSourceTrack(
        track.copyWith(id: 'deezer:source-id'),
      );
      expect(prepared.name, track.name);
      expect(prepared.albumArtist, 'Artist');
      expect(prepared.deezerId, 'source-id');
      expect(prepared.trackNumber, 2);
    },
  );

  test(
    'legacy provider lookup resolves through an enabled metadata replacement',
    () async {
      final selected = track.copyWith(
        id: 'tidal:recording',
        isrc: 'invalid',
        trackNumber: 4,
        totalTracks: 8,
      );
      final resolver = DownloadMetadataResolver(
        loadMetadata: (provider, kind, id) async {
          expect(
            (provider, kind, id),
            ('example-metadata', 'track', 'recording'),
          );
          return {
            'track': {
              'isrc': 'USAAA2400001',
              'track_number': 2,
              'total_tracks': 10,
              'composer': 'Composer',
              'disc_number': 1,
            },
          };
        },
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'searchDeezerByISRC');
        expect(call.arguments, {
          'isrc': 'USAAA2400001',
          'item_id': 'queue-item',
        });
        return jsonEncode({'success': true, 'track_id': 'resolved-id'});
      });
      final resolved = await resolver.resolveDeezerIdViaProviderIfNeeded(
        selected,
        null,
        'queue-item',
        extensionState: ExtensionState(
          extensions: [
            provider('example-metadata', replaces: ['tidal']),
          ],
        ),
      );
      expect(resolved.deezerTrackId, 'resolved-id');
      expect(resolved.track.toJson(), {
        ...selected.toJson(),
        'isrc': 'USAAA2400001',
        'composer': 'Composer',
        'discNumber': 1,
        'deezerId': 'resolved-id',
      });
    },
  );

  test(
    'known identifiers and valid ISRC avoid supplemental provider lookups',
    () async {
      final resolver = DownloadMetadataResolver(
        loadMetadata: (_, _, _) async =>
            throw StateError('unexpected provider lookup'),
      );
      final known = track.copyWith(deezerId: 'known-id');
      expect(
        await resolver.resolveDeezerIdFromKnownOrIsrc(
          known,
          'item',
          lookupContext: 'ISRC',
        ),
        'known-id',
      );
      final selected = track.copyWith(
        id: 'qobuz:recording',
        isrc: 'USAAA2400001',
      );
      final resolved = await resolver.resolveDeezerIdViaProviderIfNeeded(
        selected,
        null,
        'item',
        extensionState: const ExtensionState(),
      );
      expect(resolved.track, same(selected));
      expect(resolved.deezerTrackId, isNull);
      expect(
        await resolver.resolveDeezerIdFromKnownOrIsrc(
          track.copyWith(isrc: ' USAAA2400001 '),
          'item',
          lookupContext: 'ISRC',
        ),
        isNull,
      );
    },
  );

  test('failed provider resolution keeps every original field', () async {
    final selected = track.copyWith(id: 'qobuz:failed', isrc: 'invalid');
    final resolver = DownloadMetadataResolver(
      loadMetadata: (_, _, _) async => throw StateError('unavailable'),
    );
    final resolved = await resolver.resolveDeezerIdViaProviderIfNeeded(
      selected,
      null,
      'item',
      extensionState: const ExtensionState(),
    );
    expect(resolved.track, same(selected));
    expect(resolved.deezerTrackId, isNull);
  });

  test(
    'legacy conversion fills missing tags without replacing existing credits',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'convertSpotifyToDeezer');
        return jsonEncode({
          'track': {
            'spotify_id': 'deezer:resolved-id',
            'isrc': 'USAAA2400001',
            'release_date': '2026-01-01',
            'track_number': 3,
            'total_tracks': 12,
            'composer': 'Composer',
          },
        });
      });
      final selected = track.copyWith(trackNumber: 5);
      final result = await DownloadMetadataResolver()
          .resolveSpotifyTrackViaDeezer(selected);
      expect(result.deezerTrackId, 'resolved-id');
      expect(result.track.toJson(), {
        ...selected.toJson(),
        'deezerId': 'resolved-id',
        'isrc': 'USAAA2400001',
        'releaseDate': '2026-01-01',
        'totalTracks': 12,
        'composer': 'Composer',
      });
    },
  );

  test(
    'extended metadata skips absent IDs and normalizes empty fields',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        expect(call.method, 'getDeezerExtendedMetadata');
        return jsonEncode({'genre': ' Rock ', 'label': '', 'copyright': '  '});
      });
      final resolver = DownloadMetadataResolver();
      expect(await resolver.loadExtendedMetadataForDeezerId(null), isNull);
      expect(await resolver.loadExtendedMetadataForDeezerId(''), isNull);
      final metadata = await resolver.loadExtendedMetadataForDeezerId(
        'track-id',
      );
      expect(calls, 1);
      expect(metadata?.genre, 'Rock');
      expect(metadata?.label, isNull);
      expect(metadata?.copyright, isNull);
    },
  );

  test(
    'malformed legacy conversion keeps the original track and known ID',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => jsonEncode({
          'track': {
            'spotify_id': 'deezer:new-id',
            'isrc': 'USAAA2400001',
            'track_number': 'invalid',
          },
        }),
      );
      final selected = track.copyWith(
        id: 'example:malformed',
        deezerId: 'known-id',
      );
      final result = await DownloadMetadataResolver()
          .resolveSpotifyTrackViaDeezer(selected);
      expect(result.track, same(selected));
      expect(result.deezerTrackId, 'known-id');
    },
  );
}
