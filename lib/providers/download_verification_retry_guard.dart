import 'dart:async';

class DownloadVerificationRetryGuard {
  final Set<String> _grantedRetryKeys = {};

  bool hasRetriedAfterGrant(String itemId, String service) =>
      _grantedRetryKeys.contains(_key(itemId, service));

  void recordVerificationResult(
    String itemId,
    String service, {
    required bool granted,
  }) {
    if (granted) {
      _grantedRetryKeys.add(_key(itemId, service));
    }
  }

  void clearItem(String itemId) {
    _grantedRetryKeys.removeWhere(
      (retryKey) => retryKey == itemId || retryKey.startsWith('$itemId::'),
    );
  }

  void retainItems(Set<String> itemIds) {
    _grantedRetryKeys.removeWhere((retryKey) {
      final itemId = retryKey.split('::').first;
      return !itemIds.contains(itemId);
    });
  }

  String _key(String itemId, String service) =>
      '$itemId::${service.trim().toLowerCase()}';
}

/// Shares one verification challenge between downloads for the same service
/// while still allowing each queue item to stop waiting independently.
///
/// When the last waiter leaves, [startFlow]'s cancellation signal completes so
/// browser timers and grant subscriptions can be released immediately.
class DownloadVerificationWaitCoordinator {
  final Map<String, _ActiveDownloadVerificationFlow> _flowsByService = {};
  final Map<String, Completer<void>> _cancellationsByItem = {};

  bool hasActiveFlow(String service) =>
      _flowsByService.containsKey(_serviceKey(service));

  bool hasActiveWaiter(String itemId) =>
      _cancellationsByItem.containsKey(itemId);

  Future<bool> waitForGrant({
    required String itemId,
    required String service,
    required Future<bool> Function(Future<void> cancellationSignal) startFlow,
  }) {
    final previousCancellation = _cancellationsByItem[itemId];
    if (previousCancellation != null && !previousCancellation.isCompleted) {
      previousCancellation.complete();
    }

    final itemCancellation = Completer<void>();
    _cancellationsByItem[itemId] = itemCancellation;

    final serviceKey = _serviceKey(service);
    var activeFlow = _flowsByService[serviceKey];
    if (activeFlow == null) {
      final flowCancellation = Completer<void>();
      final result = Future<bool>.sync(
        () => startFlow(flowCancellation.future),
      );
      activeFlow = _ActiveDownloadVerificationFlow(
        result: result,
        cancellation: flowCancellation,
      );
      _flowsByService[serviceKey] = activeFlow;
    }

    final waiter = Object();
    activeFlow.waiters.add(waiter);
    return _waitForGrant(
      itemId: itemId,
      serviceKey: serviceKey,
      activeFlow: activeFlow,
      waiter: waiter,
      itemCancellation: itemCancellation,
    );
  }

  Future<bool> _waitForGrant({
    required String itemId,
    required String serviceKey,
    required _ActiveDownloadVerificationFlow activeFlow,
    required Object waiter,
    required Completer<void> itemCancellation,
  }) async {
    try {
      return await Future.any<bool>([
        activeFlow.result,
        itemCancellation.future.then((_) => false),
      ]);
    } finally {
      if (identical(_cancellationsByItem[itemId], itemCancellation)) {
        _cancellationsByItem.remove(itemId);
      }
      activeFlow.waiters.remove(waiter);
      if (activeFlow.waiters.isEmpty &&
          identical(_flowsByService[serviceKey], activeFlow)) {
        _flowsByService.remove(serviceKey);
        if (!activeFlow.cancellation.isCompleted) {
          activeFlow.cancellation.complete();
        }
      }
    }
  }

  void cancelItem(String itemId) {
    final cancellation = _cancellationsByItem[itemId];
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  void cancelAll() {
    for (final cancellation in _cancellationsByItem.values.toList()) {
      if (!cancellation.isCompleted) cancellation.complete();
    }
  }

  String _serviceKey(String service) => service.trim().toLowerCase();
}

class _ActiveDownloadVerificationFlow {
  _ActiveDownloadVerificationFlow({
    required this.result,
    required this.cancellation,
  });

  final Future<bool> result;
  final Completer<void> cancellation;
  final Set<Object> waiters = {};
}
