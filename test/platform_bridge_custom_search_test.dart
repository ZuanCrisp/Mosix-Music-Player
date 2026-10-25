import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'oversized custom-search lists are displayed without accumulating',
    () async {
      final rows = [
        {'id': 'large', 'name': 'x' * (3 * 1024 * 1024)},
      ];
      final payload = jsonEncode(rows);
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return payload;
      });
      for (var index = 0; index < 2; index++) {
        final result = await PlatformBridge.customSearchWithExtension(
          'oversized-search-test',
          'large',
        );
        expect(result, rows);
      }
      expect(calls, 2);
    },
  );

  for (final format in ['small-json', 'large-json', 'native-list']) {
    test('custom search decodes and caches $format results', () async {
      final rows = List.generate(
        format == 'large-json' ? 3000 : 2,
        (index) => {
          'id': '$index',
          'name': 'Lagu $index — 日本語',
          'artist_name': 'Artist',
          'album_name': 'Album',
          'duration': 123000,
          'external_links': {'example': 'https://example.invalid/track/$index'},
        },
      );
      final json = jsonEncode(rows);
      if (format == 'large-json') {
        expect(json.length, greaterThan(128 * 1024));
      }
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'customSearchWithExtension');
        calls++;
        return format == 'native-list' ? rows : json;
      });

      final result = await PlatformBridge.customSearchWithExtension(
        'decode-test-$format',
        'query',
      );
      expect(result, rows);
      result.first['name'] = 'Changed by caller';
      (result.first['external_links'] as Map<String, dynamic>)['example'] =
          'Changed by caller';
      final cached = await PlatformBridge.customSearchWithExtension(
        'decode-test-$format',
        'query',
      );
      expect(cached, rows);
      expect(calls, 1);
    });
  }

  test(
    'large cancelled response cannot replace the latest cached search',
    () async {
      final pending = <Completer<String>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancelExtensionRequest') return null;
        expect(call.method, 'customSearchWithExtension');
        final completer = Completer<String>();
        pending.add(completer);
        return completer.future;
      });
      Future<List<Map<String, dynamic>>> search(String query) =>
          PlatformBridge.customSearchWithExtension(
            'large-cancel-test',
            query,
            cancelPrevious: true,
          );
      final oldA = search('A');
      await Future<void>.delayed(Duration.zero);
      final b = search('B');
      await Future<void>.delayed(Duration.zero);
      final latestA = search('A');
      await Future<void>.delayed(Duration.zero);
      expect(pending, hasLength(3));

      pending[2].complete('[{"id":"latest"}]');
      expect((await latestA).single['id'], 'latest');
      final oldRows = List.generate(
        3000,
        (index) => {
          'id': 'old-$index',
          'name': 'Previous search result that must not replace the new cache',
        },
      );
      final oldJson = jsonEncode(oldRows);
      expect(oldJson.length, greaterThan(128 * 1024));
      pending[0].complete(oldJson);
      pending[1].complete('[]');
      await Future.wait([oldA, b]);

      expect((await search('A')).single['id'], 'latest');
      expect(pending, hasLength(3));
    },
  );

  test('invalid results fail without poisoning the retry cache', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      return ++calls == 1 ? '[42]' : '[{"id":"valid"}]';
    });
    Future<List<Map<String, dynamic>>> search() =>
        PlatformBridge.customSearchWithExtension(
          'invalid-decode-test',
          'query',
        );
    await expectLater(search(), throwsFormatException);
    expect((await search()).single['id'], 'valid');
    expect(calls, 2);
  });
}
