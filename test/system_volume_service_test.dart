import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/system_volume_service.dart';

void main() {
  test('closing a slider leaves background volume monitoring alive', () async {
    var starts = 0;
    var cancels = 0;
    final source = StreamController<double>.broadcast(
      onListen: () => starts++,
      onCancel: () => cancels++,
    );
    final volume = SystemVolumeService(source: source.stream);
    final background = <double>[];
    final slider = <double>[];
    final backgroundSubscription = volume.changes.listen(background.add);
    source.add(0.5);
    await Future<void>.delayed(Duration.zero);
    final sliderSubscription = volume.changes.listen(slider.add);
    await Future<void>.delayed(Duration.zero);
    expect(slider, [0.5]);
    expect(starts, 1);
    await sliderSubscription.cancel();
    expect(cancels, 0);
    source.add(0);
    await Future<void>.delayed(Duration.zero);
    expect(background, [0.5, 0]);
    await backgroundSubscription.cancel();
    expect(cancels, 1);
    await source.close();
  });

  test(
    'reattaching waits for fresh volume and releases the last listener',
    () async {
      final source = StreamController<double>.broadcast();
      final volume = SystemVolumeService(source: source.stream);
      final first = volume.changes.listen((_) {});
      source.add(0);
      await Future<void>.delayed(Duration.zero);
      await first.cancel();
      final values = <double>[];
      final second = volume.changes.listen(values.add);
      await Future<void>.delayed(Duration.zero);
      expect(values, isEmpty);
      source.add(0.7);
      await Future<void>.delayed(Duration.zero);
      expect(values, [0.7]);
      await second.cancel();
      expect(source.hasListener, isFalse);
      await source.close();
    },
  );
}
