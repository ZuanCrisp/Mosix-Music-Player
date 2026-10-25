import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/services/native_download_history.dart';

void main() {
  for (final alreadyExists in [false, true]) {
    test(
      'unindexed completed file is persisted before publication (exists: $alreadyExists)',
      () async {
        final saved = Completer<void>();
        final events = <String>[];
        final completion = persistBeforePublishingDownloadCompletion(
          persist: () => reconcileNativeDownloadHistory(
            result: {'already_exists': alreadyExists, 'history_written': false},
            adopt: (_) async => fail('No history item was supplied'),
            reload: () async => fail('Reload cannot index an unpersisted file'),
            persistFallback: () async {
              events.add('persist');
              await saved.future;
            },
          ),
          publish: () => events.add('publish'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(events, ['persist']);
        saved.complete();
        await completion;
        expect(events, ['persist', 'publish']);
      },
    );
  }

  test(
    'native history is adopted without a second fallback insertion',
    () async {
      await reconcileNativeDownloadHistory(
        result: {
          'history_item': {'id': 'native-row'},
          'history_written': true,
        },
        adopt: (json) async => expect(json['id'], 'native-row'),
        reload: () async => fail('Native row should be adopted directly'),
        persistFallback: () async => fail('No duplicate fallback'),
      );
    },
  );

  test('confirmed native write reloads the Library', () async {
    var refreshed = false;
    await reconcileNativeDownloadHistory(
      result: {'history_written': true},
      adopt: (_) async => fail('No row supplied'),
      reload: () async => refreshed = true,
      persistFallback: () async => fail('Native history already persisted'),
    );
    expect(refreshed, isTrue);
  });

  test(
    'bad native history falls back and persistence errors prevent completion',
    () async {
      var published = false;
      await expectLater(
        persistBeforePublishingDownloadCompletion(
          persist: () => reconcileNativeDownloadHistory(
            result: {'history_item': <String, dynamic>{}},
            adopt: (_) async => throw const FormatException('incomplete row'),
            reload: () async => fail('Unconfirmed history write'),
            persistFallback: () async =>
                throw StateError('storage unavailable'),
          ),
          publish: () => published = true,
        ),
        throwsStateError,
      );
      expect(published, isFalse);
    },
  );
}
