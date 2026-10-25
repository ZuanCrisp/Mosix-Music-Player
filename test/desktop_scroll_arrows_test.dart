import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_scroll_arrows.dart';

void main() {
  late ScrollController controller;

  Future<void> pumpShelf(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Center(
          child: SizedBox(
            width: 300,
            height: 100,
            child: DesktopScrollArrows(
              builder: (context, scrollController) {
                controller = scrollController;
                return ListView.builder(
                  controller: scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: 20,
                  itemBuilder: (_, index) =>
                      SizedBox(width: 100, child: Text('Item $index')),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ListView)));
    await tester.pumpAndSettle();
  }

  tearDown(() => debugDesktopPlatformOverride = null);

  testWidgets('desktop shows arrows on hover in the open directions', (
    tester,
  ) async {
    debugDesktopPlatformOverride = true;
    await pumpShelf(tester);
    expect(find.byTooltip('Scroll forward'), findsNothing);

    await hover(tester);
    expect(find.byTooltip('Scroll forward'), findsOneWidget);
    expect(find.byTooltip('Scroll back'), findsNothing);

    await tester.tap(find.byTooltip('Scroll forward'));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(240, 0.1));
    expect(find.byTooltip('Scroll back'), findsOneWidget);

    await tester.tap(find.byTooltip('Scroll back'));
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(find.byTooltip('Scroll back'), findsNothing);
  });

  testWidgets('phones and tablets keep the plain list', (tester) async {
    debugDesktopPlatformOverride = false;
    await pumpShelf(tester);
    await hover(tester);
    expect(find.byTooltip('Scroll forward'), findsNothing);
    expect(
      find.ancestor(of: find.byType(ListView), matching: find.byType(Stack)),
      findsNothing,
    );
  });
}
