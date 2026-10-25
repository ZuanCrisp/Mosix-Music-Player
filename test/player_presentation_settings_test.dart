import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/widgets/material_player_backdrop.dart';

void main() {
  test('cover style and music haptics keep their defaults', () {
    final restored = AppSettings.fromJson(const {});
    expect(restored.playerCoverStyle, 'default');
    expect(restored.musicHaptics, isFalse);
  });

  test('cover style and music haptics survive a round trip', () {
    final settings = const AppSettings().copyWith(
      playerCoverStyle: 'fullscreen',
      musicHaptics: true,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.playerCoverStyle, 'fullscreen');
    expect(restored.musicHaptics, isTrue);
  });

  test('invalid cover styles preserve the rest of the saved settings', () {
    for (final value in [null, '', 'unknown', 42, <String, String>{}]) {
      final restored = AppSettings.fromJson({
        'playerCoverStyle': value,
        'musicHaptics': true,
      });
      expect(restored.playerCoverStyle, 'default');
      expect(restored.musicHaptics, isTrue);
    }
  });

  testWidgets('full-screen Material cover keeps the entire app bar readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.reset);
    const key = ValueKey('backdrop');
    final colors = ColorScheme.fromSeed(
      seedColor: Colors.blue,
    ).copyWith(surface: Colors.white, surfaceContainerHighest: Colors.white);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: MaterialPlayerBackdrop(
            mediaItem: const MediaItem(id: 'bright-cover', title: 'Track'),
            colorScheme: colors,
            showArtwork: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        double luminanceAt(int y) {
          final offset = (y * image.width + 20) * 4;
          return Color.fromARGB(
            bytes.getUint8(offset + 3),
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2),
          ).computeLuminance();
        }

        // The shade is darkest under the status bar, eases out across the
        // app bar, stays light enough not to hide the cover, and is gone
        // below the bar (24 inset + 56 toolbar + 32 fade).
        final top = luminanceAt(2);
        final bar = luminanceAt(52);
        final below = luminanceAt(130);
        expect(top, lessThan(bar));
        expect(bar, lessThan(below));
        expect(top, greaterThan(below * 0.5));
        expect(below, closeTo(luminanceAt(200), 0.01));
      } finally {
        image.dispose();
      }
    });
  });
}
