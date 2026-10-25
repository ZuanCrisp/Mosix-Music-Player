import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/explore_cache_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('missing cache has an empty snapshot', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final snapshot = ExploreCacheStore(prefs).read();

    expect(snapshot.payload, isNull);
    expect(snapshot.timestampMs, isNull);
    expect(snapshot.sizeBytes, 0);
  });

  test('round trip preserves Unicode payload and records timestamp', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ExploreCacheStore(prefs);
    const payload = '{"title":"Musik 🎵 日本語"}';
    final beforeWrite = DateTime.now().millisecondsSinceEpoch;

    await store.write(payload);
    final afterWrite = DateTime.now().millisecondsSinceEpoch;
    final snapshot = store.read();

    expect(snapshot.payload, payload);
    expect(snapshot.timestampMs, inInclusiveRange(beforeWrite, afterWrite));
    expect(snapshot.sizeBytes, utf8.encode(payload).length + 8);
    expect(prefs.getString('explore_home_feed_cache'), payload);
    expect(prefs.getInt('explore_home_feed_ts'), snapshot.timestampMs);
  });

  test('timestamp-only cache occupies eight bytes', () async {
    SharedPreferences.setMockInitialValues({'explore_home_feed_ts': 123});
    final prefs = await SharedPreferences.getInstance();

    final snapshot = ExploreCacheStore(prefs).read();

    expect(snapshot.payload, isNull);
    expect(snapshot.timestampMs, 123);
    expect(snapshot.sizeBytes, 8);
  });

  test('empty payload without a timestamp occupies no bytes', () async {
    SharedPreferences.setMockInitialValues({'explore_home_feed_cache': ''});
    final prefs = await SharedPreferences.getInstance();

    final snapshot = ExploreCacheStore(prefs).read();

    expect(snapshot.payload, '');
    expect(snapshot.timestampMs, isNull);
    expect(snapshot.sizeBytes, 0);
  });

  test(
    'clear removes both cache keys and preserves other preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'explore_home_feed_cache': '{"sections":[]}',
        'explore_home_feed_ts': 123,
        'unrelated_setting': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final store = ExploreCacheStore(prefs);

      await store.clear();

      final snapshot = store.read();
      expect(snapshot.payload, isNull);
      expect(snapshot.timestampMs, isNull);
      expect(snapshot.sizeBytes, 0);
      expect(prefs.getKeys(), {'unrelated_setting'});
      expect(prefs.getBool('unrelated_setting'), isTrue);
    },
  );
}
