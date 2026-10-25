import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/extension_row.dart';

const _buttonKey = ValueKey('extension-row-button');

Widget _row({
  required double width,
  bool trailingBelowWhenNarrow = true,
  double textScale = 1,
}) => MaterialApp(
  theme: AppTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: ExtensionRow(
          showDivider: false,
          avatar: const ExtensionAvatar(fallbackIcon: Icons.extension),
          title: const Text('Extension name'),
          subtitle: const Text('Description'),
          trailingBelowWhenNarrow: trailingBelowWhenNarrow,
          trailing: SizedBox(
            key: _buttonKey,
            width: 140,
            height: 40,
            child: FilledButton(onPressed: () {}, child: const Text('Install')),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('a phone row puts the button under the description', (
    tester,
  ) async {
    await tester.pumpWidget(_row(width: 360));

    final title = tester.getRect(find.text('Extension name'));
    final description = tester.getRect(find.text('Description'));
    final button = tester.getRect(find.byKey(_buttonKey));
    expect(button.top, greaterThan(description.bottom));
    expect(button.left, title.left);
    // The title keeps the whole text column.
    final column = find
        .ancestor(
          of: find.text('Extension name'),
          matching: find.byType(Column),
        )
        .first;
    expect(tester.getSize(column).width, greaterThan(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide row keeps the button beside the text', (tester) async {
    await tester.pumpWidget(_row(width: 700));

    final title = tester.getRect(find.text('Extension name'));
    final button = tester.getRect(find.byKey(_buttonKey));
    expect(button.left, greaterThan(title.right));
    expect(
      button.center.dy,
      closeTo(tester.getRect(find.byType(Row).first).center.dy, 1),
    );
  });

  testWidgets('large text moves the button below on a wider row too', (
    tester,
  ) async {
    await tester.pumpWidget(_row(width: 500, textScale: 1.3));

    final description = tester.getRect(find.text('Description'));
    expect(
      tester.getRect(find.byKey(_buttonKey)).top,
      greaterThan(description.bottom),
    );
  });

  testWidgets('a row without the option keeps its control beside the text', (
    tester,
  ) async {
    await tester.pumpWidget(_row(width: 360, trailingBelowWhenNarrow: false));

    final title = tester.getRect(find.text('Extension name'));
    expect(
      tester.getRect(find.byKey(_buttonKey)).left,
      greaterThan(title.left + 100),
    );
  });
}
