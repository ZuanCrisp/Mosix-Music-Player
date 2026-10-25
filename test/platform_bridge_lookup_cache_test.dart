import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // The waits below keep the original margin after the debounce fires (50 to
  // 250 ms for the background encode) while skipping the 500 ms default.
  const debounce = Duration(milliseconds: 10);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await PlatformBridge.clearTrackCache();
    PlatformBridge.lookupCachePersistDebounceForTesting = debounce;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    await PlatformBridge.clearTrackCache();
    messenger.setMockMethodCallHandler(channel, null);
    PlatformBridge.lookupCachePersistDebounceForTesting = null;
  });

  Map<String, dynamic> collection([int count = 2]) => {
    'type': 'album',
    'album_info': {'name': 'Album 音楽'},
    'track_list': List.generate(
      count,
      (index) => {
        'id': 'track-$index',
        'name': 'Lagu $index — 日本語',
        'external_links': {'example': 'https://example.invalid/track/$index'},
      },
    ),
  };

  Future<Map<String, dynamic>> load() =>
      PlatformBridge.getProviderMetadata('example', 'album', 'collection');

  test(
    'oversized responses are returned and coalesced but not retained',
    () async {
      final payload = jsonEncode({'text': 'x' * (3 * 1024 * 1024)});
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        return payload;
      });
      final results = await Future.wait([load(), load()]);
      expect(calls, 1);
      expect((results.first['text'] as String).length, 3 * 1024 * 1024);
      results.first['text'] = 'changed';
      expect(results.last['text'], isNot('changed'));
      expect((await load())['text'], isNot('changed'));
      expect(calls, 2);
      await Future<void>.delayed(debounce + const Duration(milliseconds: 50));
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('bridge_metadata_lookup_cache_v1');
      expect(stored == null || jsonDecode(stored) is Map, true);
      expect(stored ?? '', isNot(contains('collection')));
    },
  );

  test('byte budget evicts old collections before the count limit', () async {
    var calls = 0;
    final payload = jsonEncode({'text': 'x' * (700 * 1024)});
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return payload;
    });
    Future<Map<String, dynamic>> collectionAt(int index) =>
        PlatformBridge.getProviderMetadata('example', 'album', 'album-$index');
    for (var index = 0; index < 8; index++) {
      await collectionAt(index);
    }
    expect(calls, 8);
    await collectionAt(7);
    expect(calls, 8);
    await collectionAt(0);
    expect(calls, 9);
  });

  test(
    'persistence keeps small metadata and skips a large collection',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        final id = (call.arguments as Map)['resource_id'];
        return jsonEncode({
          'text': id == 'large' ? 'x' * (600 * 1024) : 'small',
        });
      });
      await PlatformBridge.getProviderMetadata('example', 'album', 'large');
      await PlatformBridge.getProviderMetadata('example', 'track', 'small');
      await Future<void>.delayed(debounce + const Duration(milliseconds: 150));
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('bridge_metadata_lookup_cache_v1')!;
      expect(utf8.encode(stored).length, lessThanOrEqualTo(2 * 1024 * 1024));
      expect(jsonDecode(stored), contains('example:track:small'));
      expect(jsonDecode(stored), isNot(contains('example:album:large')));
    },
  );

  test(
    'persistence skips entries oversized after JSON escaping or UTF-8',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        final id = (call.arguments as Map)['resource_id'];
        return jsonEncode({
          'text': switch (id) {
            'escaped' => '\u0000' * 250000,
            'multibyte' => '音' * 380000,
            _ => 'small',
          },
        });
      });
      for (final id in ['escaped', 'multibyte', 'small']) {
        await PlatformBridge.getProviderMetadata('example', 'album', id);
      }
      await Future<void>.delayed(debounce + const Duration(milliseconds: 250));
      final prefs = await SharedPreferences.getInstance();
      final stored =
          jsonDecode(prefs.getString('bridge_metadata_lookup_cache_v1')!)
              as Map;
      expect(stored.keys, ['example:album:small']);
    },
  );

  test('persistence bounds the total encoded multibyte payload', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => jsonEncode({'text': '音' * 250000}),
    );
    for (var index = 0; index < 3; index++) {
      await PlatformBridge.getProviderMetadata('example', 'album', '$index');
    }
    await Future<void>.delayed(debounce + const Duration(milliseconds: 250));
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bridge_metadata_lookup_cache_v1')!;
    expect(utf8.encode(raw).length, lessThanOrEqualTo(2 * 1024 * 1024));
    final stored = jsonDecode(raw) as Map;
    expect(stored.keys, ['example:album:2', 'example:album:1']);
    for (final entry in stored.entries) {
      expect(
        utf8
            .encode('${jsonEncode(entry.key)}:${jsonEncode(entry.value)}')
            .length,
        lessThanOrEqualTo(1024 * 1024),
      );
    }
  });

  void mutate(Map<String, dynamic> value) {
    (value['album_info'] as Map<String, dynamic>)['name'] = 'Changed';
    final first = (value['track_list'] as List).first as Map<String, dynamic>;
    (first['external_links'] as Map<String, dynamic>)['example'] = 'Changed';
  }

  for (final count in [2, 3000]) {
    test(
      'coalesced and cached metadata isolate nested mutations ($count)',
      () async {
        final value = collection(count);
        final response = Completer<String>();
        final started = Completer<void>();
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getProviderMetadata');
          calls++;
          if (!started.isCompleted) started.complete();
          return response.future;
        });
        final first = load();
        await started.future;
        final second = load();
        await Future<void>.delayed(Duration.zero);
        response.complete(jsonEncode(value));
        final results = await Future.wait([first, second]);
        expect(results[0], value);
        mutate(results[0]);
        expect(results[1], value);
        mutate(results[1]);
        final cached = await load();
        expect(cached, value);
        mutate(cached);
        expect(await load(), value);
        expect(calls, 1);
      },
    );
  }

  test(
    'a cleared request cannot remove a replacement in-flight lookup',
    () async {
      final requests = <Completer<String>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'clearTrackCache') return null;
        expect(call.method, 'getProviderMetadata');
        final pending = Completer<String>();
        requests.add(pending);
        return pending.future;
      });
      final old = load();
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(1));
      await PlatformBridge.clearTrackCache();
      final replacement = load();
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(2));
      requests[0].complete('{"version":"old"}');
      expect(await old, {'version': 'old'});
      final joined = load();
      await Future<void>.delayed(Duration.zero);
      // Complete unexpected calls too, so a failed assertion leaves no waiters.
      for (final request in requests.skip(1)) {
        request.complete('{"version":"new"}');
      }
      expect(await replacement, {'version': 'new'});
      expect(await joined, {'version': 'new'});
      expect(requests, hasLength(2));
      expect(await load(), {'version': 'new'});
    },
  );

  test(
    'large persisted metadata restores without exposing its stored objects',
    () async {
      final value = collection(3000);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'bridge_metadata_lookup_cache_v1',
        jsonEncode({
          'example:album:collection': {
            'expires_at': DateTime.now()
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
            'value': value,
          },
        }),
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        fail('Restored metadata must not query native: ${call.method}');
      });
      final restored = await load();
      expect(restored, value);
      mutate(restored);
      expect(await load(), value);
    },
  );

  for (final nullable in [false, true]) {
    test(
      'large spill file is decoded and deleted (nullable=$nullable)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'bridge-decode-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/response.json');
        final value = collection(3000);
        await file.writeAsString(jsonEncode(value));
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'__json_file': file.path},
        );
        final result = nullable
            ? await PlatformBridge.handleURLWithExtension(
                'https://example.invalid/album',
              )
            : await load();
        expect(result, value);
        expect(await file.exists(), isFalse);
        mutate(result!);
        final cached = nullable
            ? await PlatformBridge.handleURLWithExtension(
                'https://example.invalid/album',
              )
            : await load();
        expect(cached, value);
      },
    );
  }

  test('invalid spill file is deleted and does not poison retry', () async {
    final directory = await Directory.systemTemp.createTemp('bridge-invalid-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/response.json');
    await file.writeAsString('{broken');
    var calls = 0;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async =>
          ++calls == 1 ? {'__json_file': file.path} : jsonEncode(collection()),
    );
    await expectLater(load(), throwsFormatException);
    expect(await file.exists(), isFalse);
    expect(await load(), collection());
    expect(calls, 2);
  });

  test(
    'nullable URL responses preserve null and reject encoded scalar strings',
    () async {
      for (final raw in ['null', jsonEncode(jsonEncode(collection()))]) {
        messenger.setMockMethodCallHandler(channel, (_) async => raw);
        expect(
          await PlatformBridge.handleURLWithExtension(
            'https://example.invalid/value',
          ),
          isNull,
        );
      }
    },
  );
}
