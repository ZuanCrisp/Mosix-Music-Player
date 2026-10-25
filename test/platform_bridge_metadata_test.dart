import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, null);
  });

  test(
    'iOS folder picker distinguishes cancellation from invalid replies',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(backendChannel, (_) async => null);
      expect(await PlatformBridge.pickIosDirectory(), isNull);

      for (final reply in [
        <String, String>{},
        {'path': '/external/Music'},
        {'path': 'relative/Music', 'bookmark': 'grant'},
        {'path': '/external/Music', 'bookmark': '   '},
      ]) {
        messenger.setMockMethodCallHandler(backendChannel, (_) async => reply);
        await expectLater(
          PlatformBridge.pickIosDirectory(),
          throwsA(isA<FormatException>()),
        );
      }

      messenger.setMockMethodCallHandler(backendChannel, (call) async {
        expect(call.method, 'pickIosDirectory');
        return {'path': '/external/Music', 'bookmark': 'grant'};
      });
      final selected = await PlatformBridge.pickIosDirectory();
      expect(selected?.path, '/external/Music');
      expect(selected?.bookmark, 'grant');
    },
  );

  test('complete metadata forwards descriptor format hint', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          expect(call.method, 'readFileMetadata');
          expect(call.arguments, {
            'file_path': '/proc/self/fd/42',
            'display_name': 'Song.opus',
          });
          return jsonEncode({'replaygain_track_gain': '-6.00 dB'});
        });
    final result = await PlatformBridge.readFileMetadata(
      '/proc/self/fd/42',
      displayName: 'Song.opus',
    );
    expect(result['replaygain_track_gain'], '-6.00 dB');
  });

  test('display metadata uses the lightweight scan result directly', () async {
    final invokedMethods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          invokedMethods.add(call.method);
          if (call.method == 'readAudioMetadata') {
            return jsonEncode({
              'trackName': 'Song',
              'artistName': 'Artist',
              'bitDepth': 24,
              'sampleRate': 96000,
              'bitrate': 1800,
              'format': 'flac',
              'replaygain_track_gain': '-6.20 dB',
              'replaygain_track_peak': '0.000000',
              'replaygain_album_gain': '0.00 dB',
              'replaygain_album_peak': '1.234567',
            });
          }
          fail('Unexpected full metadata read: ${call.method}');
        });

    final result = await PlatformBridge.readDisplayAudioMetadata(
      'content://downloads/song.flac',
    );

    expect(invokedMethods, ['readAudioMetadata']);
    expect(result['title'], 'Song');
    expect(result['artist'], 'Artist');
    expect(result['bit_depth'], 24);
    expect(result['sample_rate'], 96000);
    expect(result['audio_codec'], 'flac');
    expect(result['replaygain_track_gain'], '-6.20 dB');
    expect(result['replaygain_track_peak'], '0.000000');
    expect(result['replaygain_album_gain'], '0.00 dB');
    expect(result['replaygain_album_peak'], '1.234567');
  });

  test(
    'display metadata falls back when scan only parsed the filename',
    () async {
      final invokedMethods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backendChannel, (call) async {
            invokedMethods.add(call.method);
            if (call.method == 'readAudioMetadata') {
              return jsonEncode({
                'trackName': 'Filename fallback',
                'metadataFromFilename': true,
                'format': 'flac',
              });
            }
            if (call.method == 'readFileMetadata') {
              return jsonEncode({
                'title': 'Embedded title',
                'audio_codec': 'opus',
              });
            }
            fail('Unexpected method: ${call.method}');
          });

      final result = await PlatformBridge.readDisplayAudioMetadata(
        'content://downloads/misnamed.flac',
      );

      expect(invokedMethods, ['readAudioMetadata', 'readFileMetadata']);
      expect(result['title'], 'Embedded title');
      expect(result['audio_codec'], 'opus');
    },
  );

  test('metadata search sends the explicitly selected extension', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          capturedCall = call;
          return jsonEncode([
            {
              'id': 'track-1',
              'name': 'Song',
              'provider_id': 'selected-metadata',
            },
          ]);
        });

    final results = await PlatformBridge.searchTracksWithMetadataProvider(
      'selected-metadata',
      'Song Artist',
      limit: 5,
    );

    expect(capturedCall?.method, 'searchTracksWithMetadataProvider');
    expect(capturedCall?.arguments, {
      'extension_id': 'selected-metadata',
      'query': 'Song Artist',
      'limit': 5,
    });
    expect(results.single['provider_id'], 'selected-metadata');
  });

  test('metadata custom search sends the manifest track filter', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          capturedCall = call;
          return jsonEncode([
            {'id': 'track-1', 'name': 'Song', 'provider_id': 'custom-metadata'},
          ]);
        });

    final results = await PlatformBridge.customSearchWithExtension(
      'custom-metadata',
      'Song Artist',
      options: {'limit': 5, 'filter': 'songs'},
    );

    expect(capturedCall?.method, 'customSearchWithExtension');
    final arguments = capturedCall?.arguments as Map<Object?, Object?>?;
    expect(arguments, isNotNull);
    expect(arguments?['extension_id'], 'custom-metadata');
    expect(arguments?['query'], 'Song Artist');
    expect(arguments?['options'], jsonEncode({'limit': 5, 'filter': 'songs'}));
    expect(arguments?['request_id'], isA<String>());
    expect(results.single['provider_id'], 'custom-metadata');
  });

  test('SAF inspection sends one batch and decodes repair results', () async {
    MethodCall? capturedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          capturedCall = call;
          return jsonEncode({
            'results': [
              {
                'key': 'history-1',
                'status': 'found',
                'uri': 'content://tree/repaired.flac',
                'file_name': 'repaired.flac',
                'relative_dir': 'Artist/Album',
              },
            ],
          });
        });

    final results = await PlatformBridge.inspectSafFiles([
      {
        'key': 'history-1',
        'tree_uri': 'content://tree/root',
        'current_uri': 'content://tree/stale.flac',
        'relative_dir': 'Artist/Album',
        'file_names': ['song.flac', 'song_converted.flac'],
      },
    ]);

    expect(capturedCall?.method, 'inspectSafFiles');
    final arguments = capturedCall?.arguments as Map<Object?, Object?>;
    final requests = jsonDecode(arguments['requests_json'] as String) as List;
    expect(requests, hasLength(1));
    expect((requests.single as Map)['file_names'], hasLength(2));
    expect(results.single['status'], 'found');
    expect(results.single['relative_dir'], 'Artist/Album');
  });

  test('iOS bookmark access releases the matching native lease', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backendChannel, (call) async {
          calls.add(call);
          if (call.method == 'startAccessingIosBookmark') {
            return {'path': '/music', 'token': 'lease-1'};
          }
          if (call.method == 'stopAccessingIosBookmark') return null;
          fail('Unexpected method: ${call.method}');
        });

    final access = await PlatformBridge.startAccessingIosBookmark('bookmark');
    expect(access?.path, '/music');
    expect(access?.token, 'lease-1');
    await PlatformBridge.stopAccessingIosBookmark(access!);

    expect(calls[1].method, 'stopAccessingIosBookmark');
    expect(calls[1].arguments, {'token': 'lease-1'});
  });
}
