import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/recent_access_provider.dart';

void main() {
  group('Recent download clear boundary', () {
    final clearedAt = DateTime.parse('2026-08-22T12:00:00.000Z');

    test('keeps downloads when Recent has never been cleared', () {
      expect(
        isRecentDownloadAfterClear(
          DateTime.parse('2026-08-01T00:00:00.000Z'),
          null,
        ),
        isTrue,
      );
    });

    test('removes downloads recorded at or before Clear all', () {
      expect(
        isRecentDownloadAfterClear(
          DateTime.parse('2026-08-22T11:59:59.999Z'),
          clearedAt,
        ),
        isFalse,
      );
      expect(isRecentDownloadAfterClear(clearedAt, clearedAt), isFalse);
    });

    test('allows new downloads after Clear all', () {
      expect(
        isRecentDownloadAfterClear(
          DateTime.parse('2026-08-22T12:00:00.001Z'),
          clearedAt,
        ),
        isTrue,
      );
    });
  });
}
