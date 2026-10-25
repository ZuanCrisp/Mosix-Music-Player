import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/cover_palette.dart';

void main() {
  ByteData pixels(List<(Color, int)> runs) {
    final data = ByteData(runs.fold(0, (sum, run) => sum + run.$2) * 4);
    var offset = 0;
    for (final (color, count) in runs) {
      for (var i = 0; i < count; i++, offset += 4) {
        data
          ..setUint8(offset, (color.r * 255).round())
          ..setUint8(offset + 1, (color.g * 255).round())
          ..setUint8(offset + 2, (color.b * 255).round())
          ..setUint8(offset + 3, 255);
      }
    }
    return data;
  }

  test('a dark cover with one clear colour keeps that colour, not gray', () {
    // Mostly black art with a pale avocado strip, as in issue #658.
    final color = coverSourceColor(
      pixels([
        (const Color(0xff050505), 65),
        (const Color(0xffd4ddac), 30),
        (const Color(0xff6a6e72), 5),
      ]),
    )!;
    final hsl = HSLColor.fromColor(color);
    expect(hsl.hue, inInclusiveRange(60, 80));
    expect(hsl.saturation, greaterThan(0.3));
  });

  test('a small colourful detail does not tint a neutral cover', () {
    final color = coverSourceColor(
      pixels([(const Color(0xff808080), 95), (const Color(0xffff0000), 5)]),
    )!;
    expect(HSLColor.fromColor(color).saturation, lessThan(0.1));
  });

  testWidgets(
    'same-path cover replacement refreshes palette and decoded image',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'palette-replace-',
        );
        final file = File('${directory.path}/cover.png');
        final cache = PaintingBinding.instance.imageCache;
        Future<void> write(Color color) async {
          final recorder = ui.PictureRecorder();
          Canvas(
            recorder,
          ).drawRect(const Rect.fromLTWH(0, 0, 32, 32), Paint()..color = color);
          final picture = recorder.endRecording();
          final image = await picture.toImage(32, 32);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        }

        try {
          await write(Colors.blue);
          final first = await CoverPalette.resolve(file.path, Brightness.light);
          expect(first, isNotNull);
          final oldKey = await CoverPalette.cacheKeyFor(
            file.path,
            Brightness.light,
          );
          // The small source-key lookup may evict a file while Flutter still
          // retains its decoded image. A later edit must stay fresh too.
          for (var index = 0; index < 33; index++) {
            await CoverPalette.resolve(
              '${directory.path}/missing-$index.png',
              Brightness.light,
            );
          }
          expect(CoverPalette.peek(file.path, Brightness.light), isNull);
          await write(Colors.red);
          await file.setLastModified(
            DateTime.now().add(const Duration(seconds: 1)),
          );
          expect(
            await CoverPalette.cacheKeyFor(file.path, Brightness.light),
            isNot(oldKey),
          );
          final second = await CoverPalette.resolve(
            file.path,
            Brightness.light,
          );
          expect(second, isNot(same(first)));
          expect(
            CoverPalette.sourceColor(file.path, Brightness.light)?.toARGB32(),
            Colors.red.toARGB32(),
          );
        } finally {
          cache.clear();
          cache.clearLiveImages();
          await directory.delete(recursive: true);
        }
      });
    },
  );

  testWidgets('palette requests share a small aspect-preserving decode', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('palette-test-');
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      try {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 512, 256),
          Paint()..color = Colors.blue,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(512, 256);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        final file = File('${directory.path}/cover.png');
        await file.writeAsBytes(bytes!.buffer.asUint8List());

        final first = CoverPalette.resolve(file.path, Brightness.light);
        final second = CoverPalette.resolve(file.path, Brightness.light);
        expect(identical(first, second), isTrue);
        final scheme = await first;
        expect(scheme, isNotNull);
        expect(
          CoverPalette.sourceColor(file.path, Brightness.light)?.toARGB32(),
          Colors.blue.toARGB32(),
        );
        // The original is 512 x 256. Its cached decode fits inside 112 x 112
        // while preserving the 2:1 aspect ratio, instead of retaining 512 KiB.
        expect(cache.currentSizeBytes, 112 * 56 * 4);
        expect(
          await CoverPalette.resolve(file.path, Brightness.light),
          same(scheme),
        );
      } finally {
        cache.clear();
        cache.clearLiveImages();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('white and near-black artwork keeps a neutral source colour', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('neutral-cover-');
      try {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 100, 100),
          Paint()..color = Colors.white,
        );
        canvas.drawRect(
          const Rect.fromLTWH(50, 0, 50, 100),
          Paint()..color = const Color(0xff02020f),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(100, 100);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        final file = File('${directory.path}/monochrome.png');
        await file.writeAsBytes(bytes!.buffer.asUint8List());

        expect(
          await CoverPalette.resolve(file.path, Brightness.dark),
          isNotNull,
        );
        final color = CoverPalette.sourceColor(file.path, Brightness.dark)!;
        expect(color.r, color.g);
        expect(color.g, color.b);
        expect(color.r, inInclusiveRange(0.49, 0.52));
      } finally {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await directory.delete(recursive: true);
      }
    });
  });
}
