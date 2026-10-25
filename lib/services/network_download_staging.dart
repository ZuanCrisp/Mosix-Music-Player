import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/services/network_storage_service.dart';

/// Durable, per-queue-item handoff. A failed upload retains the finalized audio
/// and its original destination even if settings change before Retry.
class NetworkDownloadStaging {
  NetworkDownloadStaging({
    NetworkStorageService? storage,
    Future<Directory> Function()? directory,
  }) : _storage = storage ?? NetworkStorageService.instance,
       _directory = directory ?? getApplicationSupportDirectory;
  static final instance = NetworkDownloadStaging();
  final NetworkStorageService _storage;
  final Future<Directory> Function() _directory;

  Future<Directory> workDirectory(String id) async => Directory(
    '${(await _directory()).path}/network_downloads/${sha256.convert(utf8.encode(id))}',
  ).create(recursive: true);

  Future<Map<String, dynamic>?> read(String id) async {
    final dir = await workDirectory(id);
    final journal = File('${dir.path}/ready.json');
    if (!await journal.exists()) return null;
    final data = Map<String, dynamic>.from(
      jsonDecode(await journal.readAsString()) as Map,
    );
    final local = data['localPath'] as String;
    if (!p.isWithin(dir.path, local) || !await File(local).exists()) {
      throw StateError(
        'Prepared network download is missing. Remove it from the queue and download again.',
      );
    }
    return data;
  }

  /// Keep the first finalized output and destination across upload retries.
  /// Provider URLs and authorization fields never enter the durable journal.
  Future<void> prepareCompletion({
    required String id,
    required String localPath,
    required String folder,
    required String relativeDir,
    required String quality,
    required Map<String, dynamic> track,
    required bool externalLrcWritten,
    required Map<String, dynamic> result,
  }) async {
    if (await read(id) != null) return;
    await save(id, {
      'localPath': localPath,
      'folder': folder,
      'relativeDir': relativeDir,
      'quality': quality,
      'track': track,
      'externalLrcWritten': externalLrcWritten,
      'result': {
        for (final key in const [
          'service',
          'quality',
          'actual_bit_depth',
          'actual_sample_rate',
          'bitrate',
          'actual_bitrate',
          'audio_codec',
          'format',
          'genre',
          'label',
          'copyright',
          'title',
          'artist',
          'album',
          'release_date',
          'track_number',
          'disc_number',
          'total_tracks',
          'total_discs',
          'isrc',
          'composer',
          'explicit',
        ])
          if (result[key] != null) key: result[key],
      },
    });
  }

  Future<void> save(String id, Map<String, dynamic> data) async {
    final dir = await workDirectory(id);
    final original = data['localPath'] as String;
    if (!p.isWithin(dir.path, original)) {
      // A post-processing extension may return its own temporary output.
      final owned = p.join(dir.path, p.basename(original));
      await File(original).copy(owned);
      final lyrics = File(p.setExtension(original, '.lrc'));
      if (await lyrics.exists()) {
        await lyrics.copy(p.setExtension(owned, '.lrc'));
      }
      data = {...data, 'localPath': owned};
    }
    final temp = File('${dir.path}/ready.json.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename('${dir.path}/ready.json');
  }

  Future<String> publish(
    String id, {
    required void Function() checkpoint,
    required void Function(int, int) progress,
  }) async {
    final data = await read(id);
    if (data == null) throw StateError('Network download is not ready');
    final file = File(data['localPath'] as String);
    checkpoint();
    var target = data['target'] as String?;
    if (target == null) {
      target = await _storage.prepareUpload(
        data['folder'] as String,
        data['relativeDir'] as String,
        p.basename(file.path),
      );
      data['target'] = target;
      await save(id, data);
    }
    // Reconcile the destination even after a process restart. Matching bytes
    // means an acknowledged/lost-response publication can be adopted safely.
    await _storage.publishUpload(
      target,
      file,
      '$id/audio',
      checkpoint: checkpoint,
      progress: progress,
    );
    final lrc = File(p.setExtension(file.path, '.lrc'));
    if (await lrc.exists()) {
      final uri = Uri.parse(target);
      final path = uri.pathSegments.join('/');
      final sidecar = NetworkStorageService.source(
        uri.host,
        p.posix.setExtension(path, '.lrc'),
      );
      await _storage.publishUpload(
        sidecar,
        lrc,
        '$id/lyrics',
        checkpoint: checkpoint,
        progress: (_, _) {},
      );
    }
    return target;
  }

  Future<void> discard(String id) async {
    final dir = await workDirectory(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
