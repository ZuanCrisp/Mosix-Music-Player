import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/services/backend/native_backend_transport.dart';
import 'package:path/path.dart' as p;

/// Absolute library path that takes precedence over the bundled location.
const desktopBackendLibraryEnvironmentKey = 'MORNYE_DESKTOP_LIB';

typedef _CallbackNative =
    Void Function(Uint64 id, Int32 kind, Pointer<Uint8> data, Size len);
typedef _InitNative =
    Void Function(
      Pointer<NativeFunction<_CallbackNative>> callback,
      Pointer<Uint8> config,
      Size len,
    );
typedef _InitDart =
    void Function(
      Pointer<NativeFunction<_CallbackNative>> callback,
      Pointer<Uint8> config,
      int len,
    );
typedef _CallNative =
    Void Function(
      Uint64 id,
      Pointer<Utf8> method,
      Pointer<Uint8> args,
      Size argsLen,
      Pointer<Uint8> bytes,
      Size bytesLen,
    );
typedef _CallDart =
    void Function(
      int id,
      Pointer<Utf8> method,
      Pointer<Uint8> args,
      int argsLen,
      Pointer<Uint8> bytes,
      int bytesLen,
    );
typedef _KindNative = Void Function(Int32 kind);
typedef _KindDart = void Function(int kind);
typedef _FreeNative = Void Function(Pointer<Uint8> data, Size len);
typedef _FreeDart = void Function(Pointer<Uint8> data, int len);

/// Where the desktop backend library is looked up, in order.
@visibleForTesting
List<String> desktopBackendLibraryCandidates({
  required Map<String, String> environment,
  required String operatingSystem,
  required String executable,
}) {
  final candidates = <String>[];
  final override = environment[desktopBackendLibraryEnvironmentKey]?.trim();
  if (override != null && override.isNotEmpty) candidates.add(override);
  final context = operatingSystem == 'windows' ? p.windows : p.posix;
  final executableDir = context.dirname(executable);
  switch (operatingSystem) {
    case 'macos':
      // <App>.app/Contents/MacOS/<exe> -> <App>.app/Contents/Frameworks.
      candidates.add(
        context.join(
          context.dirname(executableDir),
          'Frameworks',
          'libmornye_desktop.dylib',
        ),
      );
    case 'windows':
      candidates.add(context.join(executableDir, 'mornye_desktop.dll'));
    case 'linux':
      candidates.add(
        context.join(executableDir, 'lib', 'libmornye_desktop.so'),
      );
  }
  return candidates;
}

DynamicLibrary _openDesktopBackendLibrary() {
  final candidates = desktopBackendLibraryCandidates(
    environment: Platform.environment,
    operatingSystem: Platform.operatingSystem,
    executable: Platform.resolvedExecutable,
  );
  final failures = <String>[];
  for (final path in candidates) {
    try {
      return DynamicLibrary.open(path);
    } on Object catch (error) {
      failures.add('$path: $error');
    }
  }
  throw StateError(
    failures.isEmpty
        ? 'No desktop backend library location for '
              '${Platform.operatingSystem}'
        : 'Desktop backend library not loaded (${failures.join('; ')})',
  );
}

/// [NativeBackendTransport] over the exported C functions of
/// `mornye_desktop`.
final class FfiBackendTransport implements NativeBackendTransport {
  FfiBackendTransport._(DynamicLibrary library)
    : _init = library.lookupFunction<_InitNative, _InitDart>('mornye_init'),
      _call = library.lookupFunction<_CallNative, _CallDart>('mornye_call'),
      _subscribe = library.lookupFunction<_KindNative, _KindDart>(
        'mornye_subscribe',
      ),
      _unsubscribe = library.lookupFunction<_KindNative, _KindDart>(
        'mornye_unsubscribe',
      ),
      _free = library.lookupFunction<_FreeNative, _FreeDart>('mornye_free');

  /// Opens the library from [desktopBackendLibraryEnvironmentKey] or the
  /// bundled location. Throws when it cannot be loaded.
  factory FfiBackendTransport.open() =>
      FfiBackendTransport._(_openDesktopBackendLibrary());

  final _InitDart _init;
  final _CallDart _call;
  final _KindDart _subscribe;
  final _KindDart _unsubscribe;
  final _FreeDart _free;

  // Lives as long as the process; the native side may call it at any time.
  NativeCallable<_CallbackNative>? _callback;

  @override
  void init(Uint8List configJson, NativeMessageListener listener) {
    if (_callback != null) return;
    final callback = NativeCallable<_CallbackNative>.listener((
      int id,
      int kind,
      Pointer<Uint8> data,
      int len,
    ) {
      final copy = data == nullptr || len == 0
          ? Uint8List(0)
          : Uint8List.fromList(data.asTypedList(len));
      if (data != nullptr) _free(data, len);
      listener(id, kind, copy);
    });
    _callback = callback;
    final config = _copyIn(configJson);
    try {
      _init(callback.nativeFunction, config, configJson.length);
    } finally {
      malloc.free(config);
    }
  }

  @override
  void call(int id, String method, Uint8List argsJson, Uint8List? bytes) {
    final name = method.toNativeUtf8(allocator: malloc);
    final args = _copyIn(argsJson);
    final binary = bytes == null ? nullptr : _copyIn(bytes);
    try {
      _call(id, name, args, argsJson.length, binary, bytes?.length ?? 0);
    } finally {
      malloc.free(name);
      malloc.free(args);
      if (binary != nullptr) malloc.free(binary);
    }
  }

  @override
  void subscribe(int kind) => _subscribe(kind);

  @override
  void unsubscribe(int kind) => _unsubscribe(kind);

  static Pointer<Uint8> _copyIn(Uint8List bytes) {
    final pointer = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    return pointer;
  }
}
