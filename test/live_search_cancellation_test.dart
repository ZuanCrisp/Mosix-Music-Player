import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'latest search wins and A-B-A never reuses a cancelled request',
    () async {
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final requests = <(String, String, Completer<String>)>[];
      final cancellations = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final arguments = call.arguments as Map;
        if (call.method == 'cancelExtensionRequest') {
          cancellations.add(arguments['request_id'] as String);
          return null;
        }
        if (call.method == 'customSearchWithExtension') {
          final result = Completer<String>();
          requests.add((
            arguments['query'] as String,
            arguments['request_id'] as String,
            result,
          ));
          return result.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(trackProvider.notifier);
      final first = notifier.customSearch('regression-search-provider', 'A');
      await Future<void>.delayed(Duration.zero);
      final second = notifier.customSearch('regression-search-provider', 'B');
      await Future<void>.delayed(Duration.zero);
      final third = notifier.customSearch('regression-search-provider', 'A');
      await Future<void>.delayed(Duration.zero);
      expect(requests.map((r) => r.$1), ['A', 'B', 'A']);
      expect(cancellations, containsAll([requests[0].$2, requests[1].$2]));
      String response(String id) => jsonEncode([
        {
          'id': id,
          'name': id,
          'artist_name': 'Artist',
          'album_name': 'Album',
          'duration': 1000,
        },
      ]);
      requests[2].$3.complete(response('latest'));
      await third;
      requests[0].$3.complete(response('old-A'));
      requests[1].$3.complete(response('old-B'));
      await Future.wait([first, second]);
      expect(container.read(trackProvider).tracks.single.id, 'latest');
      expect(container.read(trackProvider).isLoading, isFalse);
    },
  );

  for (final fails in [false, true]) {
    test(
      'clear rejects a pending search ${fails ? 'error' : 'result'}',
      () async {
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final response = Completer<String>();
        final started = Completer<void>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'customSearchWithExtension') return null;
          started.complete();
          return response.future;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(trackProvider.notifier);
        final search = notifier.customSearch('clear-search-$fails', 'query');
        await started.future;
        notifier.clear();
        if (fails) {
          response.completeError(PlatformException(code: 'late-search-error'));
        } else {
          response.complete('[{"id":"late","name":"Late result"}]');
        }
        await search;
        final state = container.read(trackProvider);
        expect(state.hasContent, isFalse);
        expect(state.isLoading, isFalse);
        expect(state.error, isNull);
      },
    );
  }

  for (final handler in [null, 'clear-url-provider']) {
    test('clear rejects URL preflight completion ($handler)', () async {
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final response = Completer<String?>();
      final started = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'findURLHandler');
        started.complete();
        return response.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(trackProvider.notifier);
      final fetch = notifier.fetchFromUrl(
        'https://example.test/clear-$handler',
      );
      await started.future;
      notifier.clear();
      response.complete(handler);
      await fetch;
      expect(container.read(trackProvider).hasContent, isFalse);
      expect(container.read(trackProvider).isLoading, isFalse);
      expect(container.read(trackProvider).error, isNull);
    });
  }
}
