import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:synchronized/synchronized.dart';

/// SMB2/3 only. Native network and crypto work runs off the UI isolate.
///
/// Serialize native calls across pools: libsmb2 maintains a process-wide
/// context list. Lock individual reads, never an entire audio stream, so cover
/// and metadata requests can run between bounded playback chunks.
class NetworkSmbClient {
  NetworkSmbClient._(this._pool, this.path);

  static final _native = Lock();
  final Smb2Pool _pool;
  final String path;
  bool _closed = false;

  static Future<NetworkSmbClient> connect(
    Uri target, {
    required String username,
    required String password,
    required String domain,
    required Duration timeout,
  }) async {
    final segments = target.pathSegments.where((s) => s.isNotEmpty).toList();
    final host = target.hasPort ? target.authority : target.host;
    final pool = await _native.synchronized(
      () => Smb2Pool.connect(
        host: host,
        share: segments.isEmpty ? 'IPC\$' : segments.first,
        user: username,
        password: password,
        domain: domain,
        workers: 1,
        timeoutSeconds: timeout.inSeconds,
        version: Smb2Version.any,
      ),
    );
    return NetworkSmbClient._(pool, segments.skip(1).join('/'));
  }

  Future<List<Smb2DirEntry>> list() =>
      _native.synchronized(() => _pool.listDirectory(path));

  static Future<List<Smb2ShareInfo>> shares(
    Uri target, {
    required String username,
    required String password,
    required String domain,
    required Duration timeout,
  }) => _native.synchronized(
    () => Smb2Pool.listSharesOn(
      host: target.hasPort ? target.authority : target.host,
      user: username,
      password: password,
      domain: domain,
      timeoutSeconds: timeout.inSeconds,
    ),
  );

  Future<Smb2Stat> stat() => _native.synchronized(() => _pool.stat(path));

  Future<void> mkdir(String relative) =>
      _native.synchronized(() => _pool.mkdir(relative));

  Future<bool> exists(String relative) =>
      _native.synchronized(() => _pool.exists(relative));

  Future<void> delete(String relative) =>
      _native.synchronized(() => _pool.deleteFile(relative));

  Future<void> rename(String from, String to) =>
      _native.synchronized(() => _pool.rename(from, to));

  Future<void> upload(
    String relative,
    File file, {
    required void Function() checkpoint,
    required void Function(int) progress,
  }) async {
    final handle = await _native.synchronized(
      () => _pool.openFileWrite(relative),
    );
    try {
      var offset = 0;
      await for (final chunk in file.openRead()) {
        checkpoint();
        await _native.synchronized(
          () => _pool.writeToHandle(
            handle,
            Uint8List.fromList(chunk),
            offset: offset,
          ),
        );
        offset += chunk.length;
        progress(offset);
      }
    } finally {
      await _native.synchronized(() => _pool.closeHandle(handle));
    }
  }

  /// End is exclusive. Keep one handle and obey downstream backpressure.
  Stream<Uint8List> read(int start, int end) async* {
    final handle = await _native.synchronized(() => _pool.openFile(path));
    try {
      var offset = start;
      while (offset < end && !_closed) {
        final bytes = await _native.synchronized(
          () => _pool.readFromHandle(
            handle,
            offset: offset,
            length: min(256 * 1024, end - offset),
          ),
        );
        if (bytes.isEmpty) {
          throw StateError('SMB file ended before requested range');
        }
        offset += bytes.length;
        yield bytes;
      }
    } finally {
      await _native.synchronized(() => _pool.closeHandle(handle));
    }
  }

  Future<void> close() => _native.synchronized(() async {
    if (_closed) return;
    _closed = true;
    await _pool.disconnect();
  });
}
