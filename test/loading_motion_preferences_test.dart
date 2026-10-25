import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets(
      'loading stops when ${reduced ? 'motion is reduced' : 'its tab is hidden'} and resumes',
      (tester) async {
        var stopped = false;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduced && stopped),
                  child: TickerMode(
                    enabled: reduced || !stopped,
                    child: const Column(
                      children: [
                        AppLoadingIndicator(semanticLabel: 'Loading'),
                        ShimmerLoading(
                          child: SkeletonBox(width: 100, height: 40),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.binding.hasScheduledFrame, isTrue);
        update(() => stopped = true);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(find.byType(M3ELoadingIndicator), findsOneWidget);
        if (reduced) expect(find.byType(ShaderMask), findsNothing);
        update(() => stopped = false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.binding.hasScheduledFrame, isTrue);
        expect(find.byType(ShaderMask), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('reduced motion shows list content immediately', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: StaggeredListItem(index: 8, child: Text('Album')),
        ),
      ),
    );
    expect(find.text('Album').hitTestable(), findsOneWidget);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
