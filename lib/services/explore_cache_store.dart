import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ExploreCacheSnapshot {
  const ExploreCacheSnapshot({
    required this.payload,
    required this.timestampMs,
    required this.sizeBytes,
  });

  final String? payload;
  final int? timestampMs;
  final int sizeBytes;
}

class ExploreCacheStore {
  const ExploreCacheStore(this._prefs);

  static const _cacheKey = 'explore_home_feed_cache';
  static const _cacheTsKey = 'explore_home_feed_ts';

  final SharedPreferences _prefs;

  ExploreCacheSnapshot read() {
    final payload = _prefs.getString(_cacheKey);
    final timestampMs = _prefs.getInt(_cacheTsKey);
    final payloadBytes = payload == null ? 0 : utf8.encode(payload).length;
    return ExploreCacheSnapshot(
      payload: payload,
      timestampMs: timestampMs,
      sizeBytes: payloadBytes + (timestampMs == null ? 0 : 8),
    );
  }

  Future<void> write(String payload) async {
    await _prefs.setString(_cacheKey, payload);
    await _prefs.setInt(_cacheTsKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> clear() async {
    await _prefs.remove(_cacheKey);
    await _prefs.remove(_cacheTsKey);
  }
}
