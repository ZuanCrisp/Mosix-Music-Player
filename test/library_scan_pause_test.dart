import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/local_library_provider.dart';

class _ScanningLibrary extends LocalLibraryNotifier {
  _ScanningLibrary({this.finalizing = false});

  final bool finalizing;

  @override
  LocalLibraryState build() => LocalLibraryState(
    isScanning: true,
    scanIsFinalizing: finalizing,
    scannedFiles: 100,
    scanTotalFiles: 400,
    scanProgress: 25,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> calls;

  setUp(() {
    calls = <String>[];
    messenger.setMockMethodCallHandler(backend, (call) async {
      calls.add(call.method);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(backend, null));

  ProviderContainer containerFor(_ScanningLibrary library) {
    final container = ProviderContainer(
      overrides: [localLibraryProvider.overrideWith(() => library)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('pause holds the scan in place and resume continues it', () async {
    final container = containerFor(_ScanningLibrary());
    final notifier = container.read(localLibraryProvider.notifier);

    await notifier.pauseScan();
    var state = container.read(localLibraryProvider);
    expect(state.isScanning, isTrue);
    expect(state.scanIsPaused, isTrue);
    expect(state.scannedFiles, 100);

    await notifier.pauseScan();
    expect(calls, ['pauseLibraryScan']);

    await notifier.resumeScan();
    state = container.read(localLibraryProvider);
    expect(state.isScanning, isTrue);
    expect(state.scanIsPaused, isFalse);
    expect(state.scannedFiles, 100);
    expect(calls, ['pauseLibraryScan', 'resumeLibraryScan']);

    await notifier.resumeScan();
    expect(calls, ['pauseLibraryScan', 'resumeLibraryScan']);
  });

  test('cancel releases a paused scan without resuming it first', () async {
    final container = containerFor(_ScanningLibrary());
    final notifier = container.read(localLibraryProvider.notifier);

    await notifier.pauseScan();
    await notifier.cancelScan();

    final state = container.read(localLibraryProvider);
    expect(state.scanIsPaused, isFalse);
    expect(state.scanWasCancelled, isTrue);
    expect(calls, ['pauseLibraryScan', 'cancelLibraryScan']);

    await notifier.resumeScan();
    expect(calls, ['pauseLibraryScan', 'cancelLibraryScan']);
  });

  test('finalizing scans cannot be paused', () async {
    final container = containerFor(_ScanningLibrary(finalizing: true));
    final notifier = container.read(localLibraryProvider.notifier);

    await notifier.pauseScan();

    expect(container.read(localLibraryProvider).scanIsPaused, isFalse);
    expect(calls, isEmpty);
  });

  test('a failed native pause leaves the scan running', () async {
    messenger.setMockMethodCallHandler(backend, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'pause-unavailable');
    });
    final container = containerFor(_ScanningLibrary());
    final notifier = container.read(localLibraryProvider.notifier);

    await notifier.pauseScan();

    expect(container.read(localLibraryProvider).scanIsPaused, isFalse);
    await notifier.resumeScan();
    expect(calls, ['pauseLibraryScan']);
  });
}
