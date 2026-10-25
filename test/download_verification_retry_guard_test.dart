import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_verification_retry_guard.dart';

void main() {
  group('DownloadVerificationRetryGuard', () {
    test('failed challenge attempts do not consume the granted retry', () {
      final guard = DownloadVerificationRetryGuard();

      guard.recordVerificationResult('item-1', 'provider-a', granted: false);

      expect(guard.hasRetriedAfterGrant('item-1', 'provider-a'), isFalse);
    });

    test('completed grants allow only one automatic retry per service', () {
      final guard = DownloadVerificationRetryGuard();

      guard.recordVerificationResult('item-1', ' PROVIDER-A ', granted: true);

      expect(guard.hasRetriedAfterGrant('item-1', 'provider-a'), isTrue);
      expect(guard.hasRetriedAfterGrant('item-1', 'provider-b'), isFalse);
      expect(guard.hasRetriedAfterGrant('item-2', 'provider-a'), isFalse);
    });

    test('manual retry clears every service marker for an item', () {
      final guard = DownloadVerificationRetryGuard()
        ..recordVerificationResult('item-1', 'provider-a', granted: true)
        ..recordVerificationResult('item-1', 'provider-b', granted: true)
        ..recordVerificationResult('item-2', 'provider-a', granted: true);

      guard.clearItem('item-1');

      expect(guard.hasRetriedAfterGrant('item-1', 'provider-a'), isFalse);
      expect(guard.hasRetriedAfterGrant('item-1', 'provider-b'), isFalse);
      expect(guard.hasRetriedAfterGrant('item-2', 'provider-a'), isTrue);
    });

    test('queue cleanup retains markers only for remaining items', () {
      final guard = DownloadVerificationRetryGuard()
        ..recordVerificationResult('removed', 'provider-a', granted: true)
        ..recordVerificationResult('remaining', 'provider-a', granted: true);

      guard.retainItems({'remaining'});

      expect(guard.hasRetriedAfterGrant('removed', 'provider-a'), isFalse);
      expect(guard.hasRetriedAfterGrant('remaining', 'provider-a'), isTrue);
    });
  });

  group('DownloadVerificationWaitCoordinator', () {
    test(
      'cancelling an item releases its verification wait immediately',
      () async {
        final coordinator = DownloadVerificationWaitCoordinator();
        final flowStarted = Completer<void>();
        final flowCancelled = Completer<void>();

        final result = coordinator.waitForGrant(
          itemId: 'item-1',
          service: 'provider-a',
          startFlow: (cancellationSignal) async {
            flowStarted.complete();
            await cancellationSignal;
            flowCancelled.complete();
            return false;
          },
        );
        await flowStarted.future;

        coordinator.cancelItem('item-1');

        expect(await result.timeout(const Duration(seconds: 1)), isFalse);
        await flowCancelled.future.timeout(const Duration(seconds: 1));
      },
    );

    test('a new item does not join an abandoned verification flow', () async {
      final coordinator = DownloadVerificationWaitCoordinator();
      var starts = 0;

      final first = coordinator.waitForGrant(
        itemId: 'item-1',
        service: 'provider-a',
        startFlow: (cancellationSignal) async {
          starts++;
          await cancellationSignal;
          return false;
        },
      );
      coordinator.cancelItem('item-1');
      expect(await first, isFalse);

      final second = coordinator.waitForGrant(
        itemId: 'item-2',
        service: 'provider-a',
        startFlow: (_) async {
          starts++;
          return true;
        },
      );

      expect(await second, isTrue);
      expect(starts, 2);
    });

    test(
      'cancelling one waiter keeps a shared flow alive for another',
      () async {
        final coordinator = DownloadVerificationWaitCoordinator();
        final grant = Completer<bool>();
        final flowCancelled = Completer<void>();
        var starts = 0;

        Future<bool> startFlow(Future<void> cancellationSignal) async {
          starts++;
          cancellationSignal.then((_) {
            if (!flowCancelled.isCompleted) flowCancelled.complete();
          });
          return grant.future;
        }

        final first = coordinator.waitForGrant(
          itemId: 'item-1',
          service: ' PROVIDER-A ',
          startFlow: startFlow,
        );
        final second = coordinator.waitForGrant(
          itemId: 'item-2',
          service: 'provider-a',
          startFlow: startFlow,
        );

        coordinator.cancelItem('item-1');
        expect(await first, isFalse);
        expect(flowCancelled.isCompleted, isFalse);

        grant.complete(true);
        expect(await second, isTrue);
        expect(starts, 1);
      },
    );
  });
}
