import 'dart:convert';

import 'package:flutter/services.dart';

/// Logging transport is independent of the bridge whose calls it records.
class NativeLogSource {
  const NativeLogSource({
    MethodChannel channel = const MethodChannel('com.zuancrisp.mosix/backend'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<Map<String, dynamic>> getSince(int index) async {
    final result = await _channel.invokeMethod<Object?>('getLogsSince', {
      'index': index,
    });
    final decoded = result is String
        ? (result.isEmpty ? null : jsonDecode(result))
        : result;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw FormatException(
      'Expected map result from getLogsSince, got ${decoded.runtimeType}',
    );
  }

  Future<void> setLoggingEnabled(bool enabled) =>
      _channel.invokeMethod<void>('setLoggingEnabled', {'enabled': enabled});

  Future<void> clear() => _channel.invokeMethod<void>('clearLogs');
}
