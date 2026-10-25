import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mosix/services/network_metadata_service.dart';
import 'package:mosix/services/network_storage_service.dart';
import 'package:mosix/services/platform_bridge.dart';
import 'package:mosix/utils/lyrics_metadata_helper.dart';
import 'package:mosix/utils/logger.dart';

final _log = AppLogger('LocalLibrary');

/// Bounded tag prefetch; only NDJSON and artwork are stored locally.
/// Failed listings never count as empty directories. Partial scans retain old
/// rows through the same ingestion policy used for local/SAF scans.
class NetworkLibraryScanner {
  NetworkLibraryScanner({
    NetworkStorageService? storage,
    Future<Map<String, dynamic>> Function(String)? readMetadata,
    Future<Directory> Function()? supportDirectory,
    Future<Directory> Function()? temporaryDirectory,
    Future<RandomAccessFile> Function(File)? openOutput,
    int? metadataConcurrency,
  }) : _storage = storage ?? NetworkStorageService.instance,
       _readMetadata = readMetadata,
       _metadataConcurrency = metadataConcurrency == null
           ? null
           : RangeError.checkValueInInterval(metadataConcurrency, 1, 4),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _openOutput = openOutput ?? ((file) => file.open(mode: FileMode.write));

  final NetworkStorageService _storage;
  final Future<Map<String, dynamic>> Function(String)? _readMetadata;
  final int? _metadataConcurrency;
  final Future<Directory> Function() _supportDirectory, _temporaryDirectory;
  final Future<RandomAccessFile> Function(File) _openOutput;

  Future<LibraryScanNDJSONFile> scan(
    String source, {
    required Future<void> Function() checkpoint,
    required void Function(int processed, int errors, String name) onProgress,
  }) async {
    final uri = Uri.parse(source);
    if (uri.scheme != 'network' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid network library source');
    }
    final connection = await _storage.connection(uri.host);
    if (connection.protocol == NetworkProtocol.http) {
      throw const FormatException('Library folders require SMB or WebDAV');
    }
    final root = networkPath(uri.pathSegments.join('/'));
    if (root.isNotEmpty && !root.endsWith('/')) {
      throw const FormatException('Expected a network folder');
    }
    await checkpoint();
    // Fail before creating scan output if the root cannot be listed.
    final first = await _storage.list(connection, root);
    final temp = await Directory(
      '${(await _temporaryDirectory()).path}/network_scans',
    ).create(recursive: true);
    final covers = await Directory(
      '${(await _supportDirectory()).path}/library_covers',
    ).create(recursive: true);
    final file = File('${temp.path}/${NetworkStorageService.newId()}.ndjson');
    RandomAccessFile? output;
    var written = 0;
    var processed = 0;
    var errors = 0;
    final pending = <String>[root];
    final visited = <String>{};
    final seenFiles = <String>{};
    // Leave room for playback and avoid saturating a small NAS/router.
    final concurrency =
        _metadataConcurrency ??
        (connection.protocol == NetworkProtocol.smb ? 2 : 3);
    final metadata = _readMetadata == null
        ? NetworkMetadataService(
            storage: _storage,
            maxConcurrentReads: concurrency,
            cacheDirectory: _temporaryDirectory,
          )
        : null;
    final read =
        _readMetadata ??
        ((String source) => metadata!.read(source, forceRefresh: true));
    final prefetched = <_PendingNetworkTrack>[];
    try {
      final writer = await _openOutput(file);
      output = writer;
      // Bound both memory and uninterrupted work when metadata is cached.
      // Count UTF-16 characters, not bytes; oversized rows are written alone.
      const maxBufferedCharacters = 64 * 1024;
      const maxBufferedRows = 64;
      final buffer = StringBuffer();
      var bufferedRows = 0;
      Future<void> flush() async {
        if (buffer.isEmpty) return;
        await writer.writeString(buffer.toString());
        buffer.clear();
        bufferedRows = 0;
      }

      while (pending.isNotEmpty) {
        await checkpoint();
        final folder = pending.removeLast();
        if (!visited.add(folder)) continue;
        if (visited.length > 100000) {
          throw StateError('Too many network folders');
        }
        final List<NetworkEntry> entries;
        try {
          entries = folder == root
              ? first
              : await _storage.list(connection, folder);
        } catch (error) {
          errors++;
          _log.e('Network folder listing failed [$folder]', error);
          onProgress(processed, errors, folder);
          continue;
        }
        _log.d(
          'Network folder listed [$folder]: '
          '${entries.where((entry) => entry.directory).length} folders, '
          '${entries.where((entry) => entry.audio).length} audio files',
        );
        final iterator = entries.iterator;
        Future<void> fill() async {
          while (prefetched.length < concurrency && iterator.moveNext()) {
            await checkpoint();
            final entry = iterator.current;
            final path = networkPath(entry.path);
            // Reject provider parent links and paths outside this folder.
            if (!path.startsWith(folder) || path == folder) continue;
            if (entry.directory) {
              if (!path.endsWith('/')) {
                throw const FormatException('Invalid folder entry');
              }
              pending.add(path);
              continue;
            }
            if (!entry.audio || !seenFiles.add(path)) continue;
            final trackSource = NetworkStorageService.source(
              connection.id,
              path,
            );
            // Capture failures immediately: a later result can fail while the
            // first read is still running. Consume results in listing order.
            final result = Future.sync(() => read(trackSource))
                .then<_NetworkTags>(
                  (tags) => (tags: tags, error: null, stack: null),
                  onError: (Object error, StackTrace stack) =>
                      (tags: null, error: error, stack: stack),
                );
            prefetched.add((entry: entry, source: trackSource, result: result));
          }
        }

        await fill();
        while (prefetched.isNotEmpty) {
          await checkpoint();
          final next = prefetched.removeAt(0);
          final entry = next.entry;
          final trackSource = next.source;
          String? encodedRow;
          try {
            final result = await next.result;
            if (result.error != null) {
              Error.throwWithStackTrace(result.error!, result.stack!);
            }
            final tags = result.tags!;
            if (tags['error'] != null || tags['metadataFromFilename'] == true) {
              throw StateError(
                tags['error']?.toString() ?? 'Network tags unavailable',
              );
            }
            final id = 'network_${sha256.convert(utf8.encode(trackSource))}';
            String? coverPath;
            final cover = tags['cover_path']?.toString();
            if (cover != null &&
                cover.isNotEmpty &&
                await File(cover).exists()) {
              // Identical embedded artwork shares an immutable file, including
              // across albums/sources. Cleanup retains all DB cover references.
              try {
                try {
                  if (!PlatformBridge.supportsCoreBackend) {
                    coverPath = await _promoteCoverInBackground(
                      cover,
                      covers.path,
                    );
                  } else {
                    final promoted = await PlatformBridge.runNativeDataJob({
                      'operation': 'promote_network_cover',
                      'path': cover,
                      'directory': covers.path,
                    });
                    coverPath = promoted['cover_path'] as String;
                  }
                } on MissingPluginException {
                  coverPath = await _promoteCoverInBackground(
                    cover,
                    covers.path,
                  );
                }
              } catch (_) {}
            }
            await checkpoint();
            final row = networkLibraryRow(trackSource, entry, tags)
              ..['id'] = id
              ..['coverPath'] = coverPath;
            encodedRow = '${jsonEncode(row)}\n';
          } catch (error) {
            // Cancellation must abort the whole staging operation.
            await checkpoint();
            errors++;
            _log.e('Network track scan failed [$trackSource]', error);
          }
          if (encodedRow != null) {
            // A failed output write invalidates the entire staging file; it
            // must not be swallowed as an individual metadata read failure.
            if (buffer.length + encodedRow.length > maxBufferedCharacters) {
              await flush();
            }
            if (encodedRow.length > maxBufferedCharacters) {
              await writer.writeString(encodedRow);
            } else {
              buffer.write(encodedRow);
              bufferedRows++;
              if (bufferedRows >= maxBufferedRows) await flush();
            }
            written++;
          }
          processed++;
          onProgress(processed, errors, entry.name);
          await fill();
        }
      }
      await checkpoint();
      await flush();
      await writer.close();
      output = null;
      // Cancellation can arrive during the final write or close too.
      await checkpoint();
      _log.i(
        'Network scan complete: ${visited.length} folders visited, '
        '$processed audio files discovered, $written indexed, $errors errors',
      );
      return LibraryScanNDJSONFile(
        file: file,
        expectedCount: written,
        errorCount: errors,
      );
    } catch (_) {
      await metadata?.cancelPending();
      await Future.wait(prefetched.map((track) => track.result));
      try {
        await output?.close();
      } catch (error) {
        _log.e('Failed to close incomplete network scan output', error);
      }
      try {
        if (await file.exists()) await file.delete();
      } catch (error) {
        _log.e('Failed to delete incomplete network scan output', error);
      }
      rethrow;
    }
  }
}

typedef _NetworkTags = ({
  Map<String, dynamic>? tags,
  Object? error,
  StackTrace? stack,
});
typedef _PendingNetworkTrack = ({
  NetworkEntry entry,
  String source,
  Future<_NetworkTags> result,
});

// Keep the isolate closure outside scan's scope so it cannot capture an open
// output handle or the buffering closures, which are not isolate-sendable.
Future<String?> _promoteCoverInBackground(String cover, String directory) =>
    Isolate.run(() => _promoteCover(cover, directory));

Future<String?> _promoteCover(String cover, String directory) async {
  final digest = await sha256.bind(File(cover).openRead()).first;
  final target = File('$directory/network_cover_$digest.image');
  final staged = File('${target.path}.${NetworkStorageService.newId()}.tmp');
  try {
    if (!await target.exists() || await target.length() == 0) {
      await File(cover).copy(staged.path);
      await staged.rename(target.path);
    }
    return target.path;
  } finally {
    if (await staged.exists()) await staged.delete();
  }
}

Map<String, dynamic> networkLibraryRow(
  String source,
  NetworkEntry entry,
  Map<String, dynamic> tags,
) {
  String text(String key, String fallback) {
    final value = tags[key]?.toString().trim() ?? '';
    return value.isEmpty ? fallback : value;
  }

  return {
    'filePath': source,
    'scannedAt': DateTime.now().toIso8601String(),
    'trackName': text(
      'title',
      entry.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
    ),
    'artistName': text('artist', 'Unknown Artist'),
    'albumName': text('album', 'Unknown Album'),
    'format': text('audio_codec', text('format', entry.extension)),
    'hasLyrics': hasUsableLyricsContent(tags['lyrics']?.toString() ?? ''),
    'explicit': tags['explicit'] == true,
    for (final field in const {
      'album_artist': 'albumArtist',
      'isrc': 'isrc',
      'genre': 'genre',
      'date': 'releaseDate',
      'composer': 'composer',
      'label': 'label',
      'copyright': 'copyright',
      'album_type': 'albumType',
      'track_number': 'trackNumber',
      'total_tracks': 'totalTracks',
      'disc_number': 'discNumber',
      'total_discs': 'totalDiscs',
      'duration': 'duration',
      'bit_depth': 'bitDepth',
      'sample_rate': 'sampleRate',
      'bitrate': 'bitrate',
      'replaygain_track_gain': 'replaygain_track_gain',
      'replaygain_album_gain': 'replaygain_album_gain',
    }.entries)
      if (tags[field.key] != null) field.value: tags[field.key],
  };
}
