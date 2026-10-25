import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/audio_format_utils.dart';

void main() {
  test('container conversion agrees with the native pipeline fixture', () {
    final rows = File(
      'android/app/src/test/resources/finalization_container_cases.tsv',
    ).readAsLinesSync();
    var cases = 0;
    for (final row in rows) {
      if (row.startsWith('#') || row.trim().isEmpty) continue;
      final fields = row.split('\t');
      expect(fields, hasLength(3));
      expect(
        shouldAttemptLosslessContainerConversion(
          forceConversion: fields[0] == 'true',
          probedCodec: fields[1].isEmpty ? null : fields[1],
        ),
        fields[2] == 'true',
        reason: row,
      );
      cases++;
    }
    expect(cases, greaterThan(0));
  });
}
