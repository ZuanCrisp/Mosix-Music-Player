import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/audio_analysis_jobs.dart';
import 'package:mornye/services/network_storage_service.dart';

/// Supplies seekable, unmodified audio to the existing analysers. Credentials
/// stay in the storage proxy; only an owned temporary file reaches the decoder.
class NetworkAudioAnalysisInput {
  NetworkAudioAnalysisInput({
    NetworkStorageService? storage,
    Future<Directory> Function()? temporaryDirectory,
    this.timeout = const Duration(seconds: 20),
  }) : _storage = storage ?? NetworkStorageService.instance,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final NetworkStorageService _storage;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration timeout;
  final Set<HttpClient> _clients = {};
  int _generation = 0;

  static bool isNetwork(String source) => source.startsWith('network://');

  /// Cancels only transfers owned by this analyser, leaving playback intact.
  void cancel() {
    _generation++;
    for (final client in _clients) {
      client.close(force: true);
    }
  }

  Future<T> _withResponse<T>(
    String source,
    String method,
    Future<T> Function(HttpClientResponse, void Function()) consume,
  ) async {
    final generation = _generation;
    void checkpoint() {
      if (generation != _generation) throw const AudioAnalysisCancelled();
    }

    final client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false;
    _clients.add(client);
    try {
      final url = await _storage.resolve(source);
      checkpoint();
      final request = await client
          .openUrl(method, Uri.parse(url))
          .timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      checkpoint();
      final response = await request.close().timeout(timeout);
      checkpoint();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Audio server returned ${response.statusCode}');
      }
      return await consume(response, checkpoint);
    } catch (_) {
      checkpoint();
      rethrow;
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<int> length(String source) =>
      _withResponse(source, 'HEAD', (response, checkpoint) async {
        await response.drain<void>().timeout(timeout);
        checkpoint();
        return response.contentLength;
      });

  /// Streams to disk with backpressure, then retains the file until all native
  /// reads finish. A partial/failed/cancelled transfer never reaches analysis.
  Future<T> withFile<T>(
    String source,
    Future<T> Function(String path) analyze,
  ) => _withResponse(source, 'GET', (response, checkpoint) async {
    Directory? directory;
    try {
      final root = await _temporaryDirectory();
      checkpoint();
      directory = await root.createTemp('network-analysis-');
      checkpoint();
      final name = Uri.parse(source).pathSegments.last;
      final file = File(p.join(directory.path, 'audio${p.extension(name)}'));
      var received = 0;
      final sink = file.openWrite();
      try {
        await sink.addStream(
          response.timeout(timeout).map((chunk) {
            checkpoint();
            received += chunk.length;
            return chunk;
          }),
        );
      } finally {
        await sink.close();
      }
      checkpoint();
      if (received == 0 ||
          (response.contentLength >= 0 && received != response.contentLength)) {
        throw const HttpException('Incomplete network audio file');
      }
      final result = await analyze(file.path);
      checkpoint();
      return result;
    } finally {
      if (directory != null) {
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          // Temporary cleanup must not replace the analysis result or error.
        }
      }
    }
  });
}
