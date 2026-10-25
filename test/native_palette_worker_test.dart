import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/cover_palette.dart';

void main() {
  test('native ordered counts retain the pinned Material palette seeds', () {
    final fixtures =
        jsonDecode(
              File(
                'rust_backend/crates/core/src/native_palette/fixtures.json',
              ).readAsStringSync(),
            )
            as Map;
    for (final value in fixtures['fixtures'] as List) {
      final fixture = value as Map<String, dynamic>;
      final colors = [
        for (final pair in fixture['colors'] as List)
          [for (final value in pair as List) (value as num).toInt()],
      ];
      expect(
        paletteSeedFromColorCounts(colors),
        fixture['seed_argb'],
        reason: '${fixture['kind']} seed ${fixture['seed']}',
      );
    }
  });
}
