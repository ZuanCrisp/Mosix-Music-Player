import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

import 'support/fixed_settings.dart';

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => const DownloadQueueState().copyWith(
    items: [
      DownloadItem(
        id: 'queued',
        track: const Track(
          id: 'example:track',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 180,
        ),
        service: 'example',
        createdAt: DateTime.utc(2026),
      ),
    ],
  );
}

class _Extensions extends ExtensionNotifier {
  final _started = Completer<void>();
  final _ready = Completer<void>();

  @override
  ExtensionState build() => const ExtensionState();

  @override
  Future<void> ensureInitialized() async {
    if (!_started.isCompleted) _started.complete();
    await _ready.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const connectivity = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(connectivity, null);
  });

  test('a failed queue setup releases processing and permits retry', () async {
    final extensions = _Extensions().._ready.complete();
    var pathAttempts = 0;
    messenger.setMockMethodCallHandler(paths, (_) async {
      pathAttempts++;
      throw PlatformException(code: 'folder_unavailable');
    });
    messenger.setMockMethodCallHandler(connectivity, (_) async => null);
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [
        downloadQueueProvider.overrideWith(() => queue),
        settingsProvider.overrideWith(FixedSettingsNotifier.new),
        extensionProvider.overrideWith(() => extensions),
      ],
    );
    addTearDown(container.dispose);
    var started = false;
    var finished = Completer<void>();
    container.listen(downloadQueueProvider, (previous, next) {
      if (next.isProcessing) started = true;
      if (started && !next.isProcessing && !finished.isCompleted) {
        finished.complete();
      }
    });

    queue.resumePendingDownloadsOnForeground();
    await finished.future;
    final state = container.read(downloadQueueProvider);
    expect(state.isProcessing, isFalse);
    expect(state.currentDownload, isNull);
    expect(state.items.single.status, DownloadStatus.queued);
    expect(pathAttempts, greaterThan(0));

    final firstAttempts = pathAttempts;
    started = false;
    finished = Completer<void>();
    queue.resumePendingDownloadsOnForeground();
    await finished.future;
    expect(pathAttempts, greaterThan(firstAttempts));
    expect(container.read(downloadQueueProvider).isProcessing, isFalse);
  });

  test(
    'restored downloads wait for extensions and remain queued if initialization fails',
    () async {
      var pathAttempts = 0;
      messenger.setMockMethodCallHandler(paths, (_) async {
        pathAttempts++;
        throw PlatformException(code: 'folder_unavailable');
      });
      messenger.setMockMethodCallHandler(connectivity, (_) async => null);
      final extensions = _Extensions();
      final queue = _Queue();
      final container = ProviderContainer(
        overrides: [
          downloadQueueProvider.overrideWith(() => queue),
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          extensionProvider.overrideWith(() => extensions),
        ],
      );
      addTearDown(container.dispose);
      container.read(downloadQueueProvider);
      queue.resumePendingDownloadsOnForeground();
      await extensions._started.future;
      expect(pathAttempts, 0);
      expect(
        container.read(downloadQueueProvider).items.single.status,
        DownloadStatus.queued,
      );
      extensions._ready.completeError(StateError('temporarily unavailable'));
      await Future<void>.delayed(Duration.zero);
      final recovered = container.read(downloadQueueProvider);
      expect(recovered.items.single.status, DownloadStatus.queued);
      expect(recovered.items.single.error, isNull);
      expect(recovered.isProcessing, isFalse);
      expect(pathAttempts, 0);
    },
  );
}
