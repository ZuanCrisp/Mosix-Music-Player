import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/widgets/smoothed_progress.dart';

Widget _testApp({
  required double progress,
  bool animate = true,
  Duration duration = const Duration(milliseconds: 900),
}) {
  return MaterialApp(
    home: SmoothedProgressScope(
      value: progress,
      animate: animate,
      duration: duration,
      child: SmoothedProgressBuilder(
        builder: (context, value, child) => Text(
          value.toStringAsFixed(3),
          key: const ValueKey('smoothed-progress-value'),
        ),
      ),
    ),
  );
}

double _displayedProgress(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.byKey(const ValueKey('smoothed-progress-value')),
  );
  return double.parse(text.data!);
}

void main() {
  testWidgets('shows the first authoritative value immediately', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(progress: 0.42));

    expect(_displayedProgress(tester), 0.42);
  });

  testWidgets('interpolates monotonic progress updates locally', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(progress: 0.2));
    await tester.pumpWidget(_testApp(progress: 0.8));
    await tester.pump(const Duration(milliseconds: 450));

    final halfway = _displayedProgress(tester);
    expect(halfway, greaterThan(0.2));
    expect(halfway, lessThan(0.8));

    await tester.pump(const Duration(milliseconds: 450));
    expect(_displayedProgress(tester), 0.8);
  });

  testWidgets('snaps resets and completion to the backend value', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp(progress: 0.4));
    await tester.pumpWidget(_testApp(progress: 0.9));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.pumpWidget(_testApp(progress: 0.7));
    expect(_displayedProgress(tester), 0.7);

    await tester.pumpWidget(_testApp(progress: 0.1));
    expect(_displayedProgress(tester), 0.1);

    await tester.pumpWidget(_testApp(progress: 1));
    expect(_displayedProgress(tester), 1);
  });

  testWidgets('snaps updates when animation is disabled', (tester) async {
    await tester.pumpWidget(_testApp(progress: 0.2));
    await tester.pumpWidget(_testApp(progress: 0.8, animate: false));

    expect(_displayedProgress(tester), 0.8);
  });
}
