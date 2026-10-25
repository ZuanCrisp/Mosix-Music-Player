import 'dart:async';

/// Runs live queue candidates with bounded concurrency. A single timed waiter
/// observes completions instead of attaching listeners to active work each tick.
class DownloadScheduler<T> {
  const DownloadScheduler({
    required this.queuedItems,
    required this.idOf,
    required this.isPaused,
    required this.concurrency,
    required this.start,
    this.onFinished,
    this.checkInterval = const Duration(milliseconds: 250),
  });

  final Iterable<T> Function() queuedItems;
  final String Function(T) idOf;
  final bool Function() isPaused;
  final int Function() concurrency;
  final Future<void> Function(T) start;
  final void Function(String)? onFinished;
  final Duration checkInterval;

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
              // Advancing the lazy filter again may scan a long completed tail.
              if (active.length >= limit || isPaused()) break;
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
