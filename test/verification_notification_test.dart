import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/verification_notification.dart';

void main() {
  const target = VerificationNotification(
    extensionId: 'provider-a',
    itemId: 'source-track',
    tapId: 'native:tap-1',
  );

  test(
    'cold tap waits for a ready handler and keeps fallback ownership',
    () async {
      final router = VerificationNotificationRouter();
      final seen = <VerificationNotification>[];
      router.receive(target.encode());
      router.receive(target.encode());
      expect(seen, isEmpty);
      router.setHandler((value) async => seen.add(value));
      await Future<void>.delayed(Duration.zero);
      expect(seen.single.extensionId, 'provider-a');
      expect(seen.single.itemId, 'source-track');
      router.receive(target.encode());
      expect(seen, hasLength(1));
    },
  );

  test(
    'duplicate active tap is ignored without blocking another provider',
    () async {
      final router = VerificationNotificationRouter();
      final wait = Completer<void>();
      final seen = <String>[];
      router.setHandler((value) async {
        seen.add(value.extensionId);
        await wait.future;
      });
      router.receive(target.encode());
      router.receive(target.encode());
      router.receive(
        const VerificationNotification(
          extensionId: 'provider-b',
          itemId: 'another-track',
          tapId: 'dart:tap-2',
        ).encode(),
      );
      expect(seen, ['provider-a', 'provider-b']);
      wait.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('unrelated and incomplete notifications cannot guess an extension', () {
    for (final payload in [
      null,
      '',
      'not json',
      '{}',
      {'kind': 'extension_verification', 'item_id': 'track', 'tap_id': 'tap'},
      {
        'kind': 'other',
        'extension_id': 'provider-a',
        'item_id': 'track',
        'tap_id': 'tap',
      },
    ]) {
      expect(VerificationNotification.parse(payload), isNull);
    }
  });
}
