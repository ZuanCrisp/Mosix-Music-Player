import 'dart:typed_data';

/// Receives one callback from the native backend. [data] is a Dart-owned copy;
/// the transport has already released the native buffer.
typedef NativeMessageListener = void Function(int id, int kind, Uint8List data);

/// Callback kinds of the desktop backend C ABI.
abstract final class NativeMessageKind {
  static const result = 0;
  static const error = 1;
  static const binaryResult = 2;
  static const downloadProgress = 10;
  static const libraryScanProgress = 11;
  static const inboundCall = 12;
  static const log = 13;
}

/// Raw access to the desktop backend's exported functions, injectable so the
/// message handling can be tested without the native library.
abstract interface class NativeBackendTransport {
  /// `mornye_init`: installs [listener] and passes the config JSON.
  void init(Uint8List configJson, NativeMessageListener listener);

  /// `mornye_call`: starts [method]; the answer arrives with the same [id].
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes);

  /// `mornye_subscribe`: starts pushing an event [kind].
  void subscribe(int kind);

  /// `mornye_unsubscribe`: stops pushing an event [kind].
  void unsubscribe(int kind);
}
