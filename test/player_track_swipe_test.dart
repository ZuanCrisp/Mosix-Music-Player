import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/widgets/player_queue_dismissible.dart';
import 'package:mosix/widgets/player_track_swipe.dart';

void main() {
  final queue = [
    for (var i = 0; i < 3; i++)
      MediaItem(id: '$i', title: 'Song $i', artist: 'Artist $i'),
  ];

  for (final reducedMotion in [false, true]) {
    testWidgets(
      'left swipe advances and right swipe returns without moving cover ($reducedMotion)',
      (tester) async {
        var index = 0;
        final selected = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reducedMotion),
              child: StatefulBuilder(
                builder: (context, setState) {
                  return PlayerTrackSwipe(
                    queue: queue,
                    currentIndex: index,
                    onSelected: (item) async {
                      selected.add(queue.indexOf(item));
                      setState(() => index = queue.indexOf(item));
                    },
                    child: Scaffold(
                      body: Center(
                        child: SizedBox(
                          width: 300,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const PlayerTrackSwipeRegion(
                                child: SizedBox(
                                  key: ValueKey('cover'),
                                  width: 200,
                                  height: 200,
                                  child: ColoredBox(color: Colors.black),
                                ),
                              ),
                              PlayerTrackSwipeTitles(
                                current: queue[index],
                                builder: (item) => Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(item.title),
                                    Text(item.artist!),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        final cover = find.byKey(const ValueKey('cover'));
        final coverRect = tester.getRect(cover);
        final titleX = tester.getTopLeft(find.text('Song 0')).dx;
        final gesture = await tester.startGesture(coverRect.center);
        await gesture.moveBy(const Offset(-110, 0));
        await tester.pump();
        expect(tester.getRect(cover), coverRect);
        expect(tester.getTopLeft(find.text('Song 0')).dx, lessThan(titleX));
        expect(find.text('Song 1'), findsOneWidget);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(selected, [1]);
        expect(tester.getTopLeft(find.text('Song 1')).dx, closeTo(titleX, 0.1));

        await tester.drag(find.text('Song 1'), const Offset(180, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0]);
        // At the first song the previous direction resists, then returns.
        await tester.drag(cover, const Offset(200, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0]);
        expect(tester.getTopLeft(find.text('Song 0')).dx, closeTo(titleX, 0.1));
        await tester.drag(cover, const Offset(-20, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0]);
        await tester.drag(cover, const Offset(-200, 0));
        await tester.pumpAndSettle();
        await tester.drag(cover, const Offset(-200, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0, 1, 2]);
        // At the last song, only the next direction is blocked.
        await tester.drag(cover, const Offset(-200, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0, 1, 2]);
        await tester.drag(cover, const Offset(200, 0));
        await tester.pumpAndSettle();
        expect(selected, [1, 0, 1, 2, 1]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('queue left swipe removes just that occurrence', (tester) async {
    final entries = [queue[0], queue[0].copyWith(), queue[1]];
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Column(
              children: [
                for (final item in entries)
                  PlayerQueueDismissible(
                    key: ObjectKey(item),
                    enabled: !identical(item, entries.first),
                    onRemove: () => setState(() {
                      entries.removeWhere((entry) => identical(entry, item));
                    }),
                    child: SizedBox(
                      width: 320,
                      height: 64,
                      child: Text(item.title),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.drag(
      find.byType(PlayerQueueDismissible).at(1),
      const Offset(280, 0),
    );
    await tester.pumpAndSettle();
    expect(entries, hasLength(3));
    await tester.drag(
      find.byType(PlayerQueueDismissible).at(1),
      const Offset(-280, 0),
    );
    await tester.pumpAndSettle();
    expect(entries.map((item) => item.id), ['0', '1']);
    await tester.drag(
      find.byType(PlayerQueueDismissible).first,
      const Offset(-280, 0),
    );
    await tester.pumpAndSettle();
    expect(entries, hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
