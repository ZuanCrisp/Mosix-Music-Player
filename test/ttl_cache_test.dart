import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/ttl_cache.dart';

void main() {
  test('TtlCache evicts the least recently used entry at its bound', () {
    final cache = TtlCache<int>(const Duration(minutes: 1), maxEntries: 2);

    cache.set('first', 1);
    cache.set('second', 2);
    expect(cache.get('first'), 1);
    cache.set('third', 3);

    expect(cache.get('first'), 1);
    expect(cache.get('second'), isNull);
    expect(cache.get('third'), 3);
    expect(cache.length, 2);
  });

  test('TtlCache sweeps expired keys even when another key is accessed', () {
    final cache = TtlCache<int>(Duration.zero, maxEntries: 3);
    cache.set('expired', 1);

    expect(cache.get('different-key'), isNull);
    expect(cache.length, 0);
  });

  test('TtlCache rejects a non-positive bound', () {
    expect(
      () => TtlCache<int>(const Duration(minutes: 1), maxEntries: 0),
      throwsArgumentError,
    );
    expect(
      () => TtlCache<int>(const Duration(minutes: 1), maxEntries: -1),
      throwsArgumentError,
    );
  });
}
