import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:mornye/services/backend/backend_channel.dart';
import 'package:mornye/services/backend/method_channel_backend.dart';

/// Logging transport is independent of the bridge whose calls it records.
class NativeLogSource {
  /// Uses [channel] when given, otherwise the platform's backend.
  const NativeLogSource({MethodChannel? channel}) : _channel = channel;

  final MethodChannel? _channel;

  BackendChannel get _backend {
    final channel = _channel;
    return channel == null ? backendChannel : MethodChannelBackend(channel);
  }

  Future<Map<String, dynamic>> getSince(int index) async {
    final result = await _backend.invokeMethod<Object?>('getLogsSince', {
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
      _backend.invokeMethod<void>('setLoggingEnabled', {'enabled': enabled});

  Future<void> clear() => _backend.invokeMethod<void>('clearLogs');
}
