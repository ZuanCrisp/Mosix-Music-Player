import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/mornye_squircle_border.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> open(
    WidgetTester tester,
    Rect anchor, {
    bool reduced = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mornyeGlassLevelProvider.overrideWithValue(MornyeGlassLevel.frosted),
          mornyeBlurEnabledProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark, glassClarity: 1),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduced,
              padding: const EdgeInsets.symmetric(vertical: 24),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showMornyeContextMenu<void>(
                    context: context,
                    anchor: anchor,
                    builder: (context) => MornyeContextMenu(
                      groups: [
                        [
                          MornyeMenuAction(
                            icon: Icons.play_arrow,
                            label: 'Play',
                            onPressed: () => Navigator.pop(context),
                          ),
                          MornyeMenuAction(
                            icon: Icons.queue_music,
                            label: 'Add to queue',
                            onPressed: () {},
                          ),
                          MornyeMenuAction(
                            icon: Icons.album,
                            label: 'Go to album',
                            onPressed: () {},
                          ),
                        ],
                      ],
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
  }

  Rect visibleBounds(WidgetTester tester) {
    final box = tester.renderObject<RenderBox>(find.byType(MornyeContextMenu));
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  MornyeGlassPanel panel(WidgetTester tester) =>
      tester.widget<MornyeGlassPanel>(find.byType(MornyeGlassPanel));

  for (final anchor in [
    const Rect.fromLTWH(325, 100, 44, 44),
    const Rect.fromLTWH(16, 720, 44, 44),
  ]) {
    testWidgets('menu flies from $anchor while opaque, then reveals glass', (
      tester,
    ) async {
      await open(tester, anchor);
      final first = visibleBounds(tester);
      expect(first.center.dx, closeTo(anchor.center.dx, 0.01));
      expect(first.center.dy, closeTo(anchor.center.dy, 0.01));
      expect(first.width, closeTo(320 * 0.16, 0.01));
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      final flying = visibleBounds(tester);
      expect(flying.width, greaterThan(first.width));
      expect(flying.width, lessThan(320));
      expect(panel(tester).glassProgress, 0);
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pump(const Duration(milliseconds: 140));
      final resting = visibleBounds(tester);
      expect(resting.width, closeTo(320, 0.01));
      expect(panel(tester).glassProgress, inExclusiveRange(0, 1));
      expect(find.byType(BackdropFilter), findsOneWidget);
      await tester.pumpAndSettle();
      expect(visibleBounds(tester), resting);
      expect(panel(tester).glassProgress, 1);
      expect(resting.left, greaterThanOrEqualTo(16));
      expect(resting.right, lessThanOrEqualTo(374));
      expect(resting.top, greaterThanOrEqualTo(40));
      expect(resting.bottom, lessThanOrEqualTo(804));
      expect(panel(tester).smoothCorners, isTrue);
      expect(panel(tester).radius, 28);
      // The outside clip follows the same squircle as the lens and rim.
      final shapes = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((w) => w.decoration)
          .whereType<ShapeDecoration>();
      expect(shapes.any((d) => d.shape is MornyeSquircleBorder), isTrue);
      await tester.tap(find.text('Play'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));
      expect(panel(tester).glassProgress, 0);
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(MornyeContextMenu), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Reduce Motion opens the finished glass menu immediately', (
    tester,
  ) async {
    await open(tester, const Rect.fromLTWH(325, 100, 44, 44), reduced: true);
    await tester.pump();
    expect(visibleBounds(tester).width, 320);
    expect(panel(tester).glassProgress, 1);
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(find.byType(MornyeContextMenu), findsNothing);
  });
}
