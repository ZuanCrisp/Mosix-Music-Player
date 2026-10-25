import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _labelNode(
  ValueNotifier<String> label,
  Widget child, {
  bool boundary = false,
  bool explicitChildren = false,
}) => ValueListenableBuilder<String>(
  valueListenable: label,
  child: child,
  builder: (_, value, child) => Semantics(
    label: value,
    container: boundary,
    explicitChildNodes: explicitChildren,
    child: child,
  ),
);

void main() {
  // Flutter #192724: updates behind a modal barrier must not reuse an ancestor
  // geometry cache from a previous frame. Keep accessibility enabled throughout.
  testWidgets('geometry survives updates behind a modal barrier', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final blocked = ValueNotifier(false);
      final position = ValueNotifier(0.0);
      final outer = ValueNotifier('page');
      final middle = ValueNotifier('content');
      final inner = ValueNotifier('empty action');
      addTearDown(() {
        blocked.dispose();
        position.dispose();
        outer.dispose();
        middle.dispose();
        inner.dispose();
      });
      final page = Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 240,
          height: 240,
          child: _labelNode(
            outer,
            ValueListenableBuilder<double>(
              valueListenable: position,
              builder: (_, x, child) =>
                  Transform.translate(offset: Offset(x, 0), child: child),
              child: Align(
                alignment: Alignment.topLeft,
                child: _labelNode(
                  middle,
                  _labelNode(inner, const SizedBox.shrink(), boundary: true),
                ),
              ),
            ),
            boundary: true,
            explicitChildren: true,
          ),
        ),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ValueListenableBuilder<bool>(
            valueListenable: blocked,
            child: page,
            builder: (_, value, child) => Stack(
              children: [
                child!,
                if (value) const BlockSemantics(child: SizedBox.expand()),
              ],
            ),
          ),
        ),
      );
      blocked.value = true;
      await tester.pump();
      position.value = 1;
      middle.value = 'changed content';
      await tester.pump();
      outer.value = 'changed page';
      position.value = 2;
      inner.value = 'changed empty action';
      await tester.pump();
      expect(tester.takeException(), isNull);
      blocked.value = false;
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('changed page'), findsOneWidget);
      expect(find.bySemanticsLabel('changed content'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });
}
