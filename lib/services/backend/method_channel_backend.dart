import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/backend/backend_channel.dart';

/// The Android and iOS backend: the host platform channels, unchanged.
class MethodChannelBackend extends BackendChannel {
  const MethodChannelBackend(
    this.channel, {
    this.downloadProgressChannel = const EventChannel(
      'com.zarz.mornye/download_progress_stream',
    ),
    this.libraryScanProgressChannel = const EventChannel(
      'com.zarz.mornye/library_scan_progress_stream',
    ),
  });

  static const shared = MethodChannelBackend(
    MethodChannel('com.zarz.mornye/backend'),
  );

  final MethodChannel channel;
  final EventChannel downloadProgressChannel;
  final EventChannel libraryScanProgressChannel;

  @override
  @optionalTypeArgs
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      channel.invokeMethod<T>(method, arguments);

  @override
  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    dynamic arguments,
  ]) => channel.invokeMapMethod<K, V>(method, arguments);

  @override
  void setMethodCallHandler(BackendCallHandler? handler) =>
      channel.setMethodCallHandler(handler);

  @override
  Stream<dynamic> downloadProgressEvents() =>
      downloadProgressChannel.receiveBroadcastStream();

  @override
  Stream<dynamic> libraryScanProgressEvents() =>
      libraryScanProgressChannel.receiveBroadcastStream();
}
