import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/utils/adaptive_layout.dart';

void main() {
  group('adaptive navigation', () {
    test('keeps phone and tablet widths on reachable bottom navigation', () {
      expect(useNavigationRailForWidth(390), isFalse);
      expect(useNavigationRailForWidth(1032), isFalse);
      expect(useNavigationRailForWidth(1366), isFalse);
    });

    test('reserves the navigation rail for desktop-width windows', () {
      expect(useNavigationRailForWidth(navigationRailBreakpoint - 1), isFalse);
      expect(useNavigationRailForWidth(navigationRailBreakpoint), isTrue);
    });
  });

  group('wide content', () {
    test('uses the full tablet width before applying a small gutter', () {
      expect(wideInsetForWidth(853), 0);
      expect(wideInsetForWidth(1024), 32);
      expect(wideInsetForWidth(1366), maxWideContentInset);
    });

    test('never removes more than the shared gutter from each side', () {
      expect(adaptiveContentMaxWidth(1366), 1302);
    });
  });

  group('adaptive UI scale', () {
    test('keeps phone density unchanged', () {
      expect(adaptiveUiScaleForSize(const Size(430, 932)), 1);
    });

    test('enlarges compact and large tablet touch surfaces', () {
      expect(adaptiveUiScaleForSize(const Size(700, 1000)), 1.1);
      expect(adaptiveUiScaleForSize(const Size(1024, 1366)), 1.2);
      expect(adaptiveUiScaleForSize(const Size(1366, 1024)), 1.2);
    });

    test('keeps desktop-width windows at native density', () {
      expect(adaptiveUiScaleForSize(const Size(1440, 900)), 1);
    });

    testWidgets('reflows the tablet viewport and preserves touch mapping', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2048, 2732);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Size? innerSize;
      var taps = 0;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: AdaptiveUiScaler(
              child: Builder(
                builder: (context) {
                  innerSize = MediaQuery.sizeOf(context);
                  return Align(
                    alignment: Alignment.topLeft,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => taps++,
                      child: const SizedBox.square(dimension: 100),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(innerSize!.width, closeTo(1024 / 1.2, 0.01));
      expect(innerSize!.height, closeTo(1366 / 1.2, 0.01));
      await tester.tapAt(const Offset(110, 110));
      await tester.pump();
      expect(taps, 1);
    });
  });
}
