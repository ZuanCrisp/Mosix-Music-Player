import 'dart:async';

import 'package:mornye/services/download_scheduler.dart';

/// Original scheduler for paired device timing. Keep its scheduling/draining
/// behavior intact so both variants include the same futures and timer costs.
class LegacyDownloadScheduler<T> extends DownloadScheduler<T> {
  const LegacyDownloadScheduler({
    required super.queuedItems,
    required super.idOf,
    required super.isPaused,
    required super.concurrency,
    required super.start,
    super.onFinished,
    super.checkInterval,
  });

  @override
  Future<void> run() async {
    final active = <String>{};
    (Object, StackTrace)? failure;
    Completer<void>? waiter;
    Timer? timer;
    void wake() {
      timer?.cancel();
      timer = null;
      final pending = waiter;
      waiter = null;
      pending?.complete();
    }

    Future<void> waitForChange() {
      final pending = waiter = Completer<void>();
      timer = Timer(checkInterval, wake);
      return pending.future;
    }

    void failed(Object error, StackTrace stack) => failure ??= (error, stack);
    void launch(T item, String id) {
      active.add(id);
      unawaited(
        Future.sync(
          () => start(item),
        ).then<void>((_) {}, onError: failed).whenComplete(() {
          active.remove(id);
          try {
            onFinished?.call(id);
          } catch (error, stack) {
            failed(error, stack);
          }
          wake();
        }),
      );
    }

    try {
      while (true) {
        if (failure == null && !isPaused()) {
          final limit = concurrency().clamp(1, 3);
          if (active.length < limit) {
            for (final item in queuedItems()) {
              if (isPaused() || active.length >= limit) break;
              final id = idOf(item);
              // Retry can requeue an item before its previous attempt unwinds.
              if (!active.contains(id)) launch(item, id);
            }
          }
        }
        if (active.isEmpty) break;
        await waitForChange();
      }
    } catch (error, stack) {
      failed(error, stack);
      while (active.isNotEmpty) {
        await waitForChange();
      }
    } finally {
      wake();
    }
    if (failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
  }
}
