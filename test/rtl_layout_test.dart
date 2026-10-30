import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosix/theme/mosix_icons.dart';

void main() {
  test('Mosix directional icons mirror in right-to-left layouts', () {
    for (final icon in [
      mosixIconFor(Icons.arrow_back),
      mosixIconFor(Icons.chevron_left),
      mosixArrowForward,
      CupertinoIcons.back,
      CupertinoIcons.forward,
      CupertinoIcons.right_chevron,
    ]) {
      expect(icon.matchTextDirection, isTrue, reason: '$icon');
    }
    // The mirrored glyphs are the same shapes as the SF-style names.
    expect(
      CupertinoIcons.back.codePoint,
      CupertinoIcons.chevron_back.codePoint,
    );
    expect(
      CupertinoIcons.forward.codePoint,
      CupertinoIcons.chevron_forward.codePoint,
    );
    expect(mosixArrowForward.codePoint, CupertinoIcons.arrow_right.codePoint);
  });
}
