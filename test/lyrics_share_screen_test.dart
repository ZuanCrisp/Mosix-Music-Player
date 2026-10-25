import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/lyrics_share_screen.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/widgets/expressive_button.dart';

void main() {
  test('timed lyrics share their sung lines, plain lyrics their text', () {
    final timed = LyricsParser.parse('''
[00:01.00]First line
[00:03.00]
[00:05.00]Second line
''');
    expect(lyricsShareLines(timed).map((line) => line.text), [
      'First line',
      'Second line',
    ]);
    final plain = LyricsParser.parse('Verse one\n\nVerse two\n');
    expect(lyricsShareLines(plain).map((line) => line.text), [
      'Verse one',
      'Verse two',
    ]);
  });

  test('short quotes use larger type than long ones', () {
    expect(
      LyricsShareCard.fontSizeFor([(text: 'Short', background: false)]),
      greaterThan(
        LyricsShareCard.fontSizeFor([(text: 'A' * 200, background: false)]),
      ),
    );
  });

  testWidgets('selection is limited and required before sharing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LyricsShareScreen(
          mediaItem: const MediaItem(id: 'track', title: 'Track'),
          lines: [
            for (var i = 0; i < 7; i++) (text: 'Line $i', background: false),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    ExpressiveButton share() => tester.widget<ExpressiveButton>(
      find.ancestor(
        of: find.text('Share'),
        matching: find.byType(ExpressiveButton),
      ),
    );
    expect(share().onPressed, isNull);

    Finder choice(int index) => find.descendant(
      of: find.byType(ListView),
      matching: find.text('Line $index'),
    );
    for (var i = 0; i < lyricsShareMaxLines; i++) {
      await tester.tap(choice(i));
    }
    await tester.pumpAndSettle();
    expect(share().onPressed, isNotNull);
    expect(find.text('Line 0'), findsNWidgets(2));

    await tester.scrollUntilVisible(choice(6), 100);
    // Fully reveal the row; a partly clipped one cannot be tapped.
    await tester.ensureVisible(choice(6));
    await tester.pumpAndSettle();
    await tester.tap(choice(6));
    await tester.pump();
    expect(find.text('You can share up to 5 lines'), findsOneWidget);
    expect(find.text('Line 6'), findsOneWidget);
  });
}
