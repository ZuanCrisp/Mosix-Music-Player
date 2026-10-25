import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/l10n/l10n.dart';
import 'package:mosix/widgets/mornye_volume_control.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('In-app volume writes suppress the system volume panel', () async {
    const channel = MethodChannel('com.kurenai7968.volume_controller.method');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => calls.add(call),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(systemVolumeWriterProvider)(0.7);
    expect(calls.single.method, 'setVolume');
    expect(calls.single.arguments, {'volume': 0.7, 'showSystemUI': false});
  });

  testWidgets('Slow volume writes coalesce and cannot reset an active drag', (
    tester,
  ) async {
    final writes = <double>[];
    final completions = <Completer<void>>[];
    final volumes = StreamController<double>();
    addTearDown(volumes.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          systemVolumeProvider.overrideWith((ref) => volumes.stream),
          systemVolumeWriterProvider.overrideWith(
            (ref) => (value) {
              writes.add(value);
              final completion = Completer<void>();
              completions.add(completion);
              return completion.future;
            },
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: MornyeVolumeControl()),
        ),
      ),
    );
    volumes.add(0.5);
    await tester.pumpAndSettle();
    Slider slider() => tester.widget(find.byType(Slider));

    slider().onChangeStart!(0.5);
    slider().onChanged!(0.6);
    slider().onChanged!(0.7);
    slider().onChanged!(0.8);
    await tester.pump();
    expect(writes, [0.6]);
    expect(slider().value, 0.8);

    completions.first.complete();
    await tester.pump();
    expect(writes, [0.6, 0.8]);
    volumes.add(0.6);
    completions.last.complete();
    await tester.pump();
    expect(slider().value, 0.8);

    slider().onChangeEnd!(0.8);
    slider().onChangeStart!(0.8);
    slider().onChanged!(0.9);
    completions.last.complete();
    await tester.pump();
    expect(writes.last, 0.9);
    completions.last.complete();
    await tester.pump();
    expect(slider().value, 0.9);

    slider().onChangeEnd!(0.9);
    volumes.add(0.9);
    completions.last.complete();
    await tester.pump();
    volumes.add(0.3);
    await tester.pumpAndSettle();
    expect(slider().value, 0.3);
    expect(tester.takeException(), isNull);
  });
}
