import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/app_sliver_header.dart';

void main() {
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);
  late int refreshes;
  late ScrollController scroll;

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    refreshes = 0;
    scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        // The app's macOS scrolling: lists bounce past their edges.
        scrollBehavior: const MaterialScrollBehavior().copyWith(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
        ),
        home: Scaffold(
          body: AppRefreshIndicator(
            onRefresh: () async {
              refreshes++;
              await Future<void>.delayed(const Duration(milliseconds: 300));
            },
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                const AppSliverHeader.tabRoot(title: 'Page'),
                SliverList.builder(
                  itemCount: 40,
                  itemBuilder: (_, i) =>
                      SizedBox(height: 80, child: Text('row $i')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A two-finger trackpad pan through [path] (total pan, downward
  /// positive), checking the list after every step.
  Future<void> pan(
    WidgetTester tester,
    List<double> path, {
    void Function()? check,
  }) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(const Offset(400, 400));
    for (final y in path) {
      await gesture.panZoomUpdate(const Offset(400, 400), pan: Offset(0, y));
      await tester.pump(const Duration(milliseconds: 16));
      check?.call();
    }
    await gesture.panZoomEnd();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('a pull the indicator ignores leaves no gap', (tester) async {
    await pumpPage(tester);
    await pan(tester, [40, 80, 120, 160, 200]);
    await tester.pump(const Duration(milliseconds: 50));
    expect(refreshes, 1);

    // The indicator ignores a pull while it is busy; the list must not
    // bounce below the pinned header either.
    await pan(tester, [
      40,
      80,
      120,
      160,
    ], check: () => expect(scroll.position.pixels, 0));
    await settle(tester);
    expect(refreshes, 1);
  }, variant: macOS);

  testWidgets('pushing a pull back shrinks it before the list scrolls', (
    tester,
  ) async {
    await pumpPage(tester);
    await pan(tester, [
      40,
      80,
      120,
      160,
      120,
      60,
      20,
    ], check: () => expect(scroll.offset, 0));
    await settle(tester);
    expect(scroll.offset, 0);

    // Past the start of the pull, the list scrolls as usual.
    await pan(tester, [40, 80, 40, 0, -40, -80]);
    await settle(tester);
    expect(scroll.offset, greaterThan(0));
  }, variant: macOS);

  testWidgets('refreshVisible refreshes the page on screen', (tester) async {
    await pumpPage(tester);
    expect(AppRefreshIndicator.refreshVisible(), isTrue);
    await settle(tester);
    expect(refreshes, 1);
  }, variant: macOS);
}
