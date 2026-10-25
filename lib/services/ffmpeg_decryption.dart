import 'dart:convert';
import 'dart:io';

import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('FFmpeg');

/// Extension descriptor interpretation and MOV-key container fallbacks.
abstract final class FFmpegDecryption {
  static Future<String?> decrypt({
    required String inputPath,
    required DownloadDecryptionDescriptor descriptor,
    bool deleteOriginal = true,
    Future<FFmpegResult> Function(String)? execute,
    Future<void> Function(String)? prepareOutput,
  }) async {
    if (descriptor.normalizedStrategy != 'ffmpeg.mov_key') {
      _log.e(
        'Unsupported download decryption strategy: ${descriptor.strategy}',
      );
      return null;
    }
    final key = descriptor.key.trim();
    if (key.isEmpty) return inputPath;
    return _decryptMovKeyFile(
      inputPath: inputPath,
      decryptionKey: key,
      inputFormat: descriptor.inputFormat,
      outputExtension: descriptor.outputExtension,
      deleteOriginal: deleteOriginal,
      execute: execute ?? FFmpegExecution.command,
      prepareOutput: prepareOutput,
    );
  }

  static List<String> _keyCandidates(String rawKey) {
    final candidates = <String>[];
    void add(String key) {
      final normalized = key.trim();
      if (normalized.isNotEmpty && !candidates.contains(normalized)) {
        candidates.add(normalized);
      }
    }

    final trimmed = rawKey.trim();
    if (trimmed.isEmpty) return candidates;
    add(trimmed);
    final noPrefix = trimmed.startsWith(RegExp(r'0x', caseSensitive: false))
        ? trimmed.substring(2)
        : trimmed;
    add(noPrefix);
    final compactHex = noPrefix.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (compactHex.isNotEmpty && compactHex.length.isEven) add(compactHex);
    try {
      final decoded = base64Decode(noPrefix.replaceAll(RegExp(r'\s+'), ''));
      if (decoded.isNotEmpty) {
        add(decoded.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
      }
    } catch (_) {}
    return candidates;
  }

  static String _preferredExtension(String inputPath, String? requested) {
    final extension = (requested ?? '').trim();
    if (extension.isNotEmpty) {
      return extension.startsWith('.') ? extension : '.$extension';
    }
    for (final ext in ['.mp3', '.opus', '.mp4']) {
      if (inputPath.toLowerCase().endsWith(ext)) return ext;
    }
    return '.flac';
  }

  static Future<String?> _decryptMovKeyFile({
    required String inputPath,
    required String decryptionKey,
    String? inputFormat,
    String? outputExtension,
    required bool deleteOriginal,
    required Future<FFmpegResult> Function(String) execute,
    Future<void> Function(String)? prepareOutput,
  }) async {
    final preferredExt = _preferredExtension(inputPath, outputExtension);
    final demuxer = (inputFormat ?? '').trim().isNotEmpty
        ? inputFormat!.trim()
        : 'mov';
    String command(
      String outputPath, {
      required bool mapAudioOnly,
      required String key,
      bool forceMov = false,
    }) {
      final map = mapAudioOnly ? '-map 0:a ' : '';
      // Encrypted MOV may have a FLAC suffix; override input detection. Native
      // FLAC output also needs an explicit muxer. MOV permits codecs such as
      // AC-4 that the MP4 muxer rejects while keeping the .mp4 filename.
      final muxer = forceMov
          ? '-f mov '
          : outputPath.toLowerCase().endsWith('.flac')
          ? '-f flac '
          : '';
      return '-v error -decryption_key "$key" -f $demuxer -i "$inputPath" $map-c copy $muxer"$outputPath" -y';
    }

    final candidates = _keyCandidates(decryptionKey);
    if (candidates.isEmpty) {
      _log.e('No usable decryption key candidates');
      return null;
    }
    FFmpegResult? lastResult;
    FFmpegOutputPlan? plan;
    var published = false;
    Future<bool> attempt(
      String extension,
      String key, {
      bool forceMov = false,
    }) async {
      if (plan != null) await FFmpegOutput.cleanup(plan!.workingPath);
      final output = await FFmpegOutput.plan(
        inputPath,
        extension,
        deleteOriginal: deleteOriginal,
      );
      plan = output;
      final result = await execute(
        command(
          output.workingPath,
          mapAudioOnly: extension == '.flac',
          key: key,
          forceMov: forceMov,
        ),
      );
      lastResult = result;
      final file = File(output.workingPath);
      return result.success && await file.exists() && await file.length() > 0;
    }

    try {
      for (final key in candidates) {
        _log.d('Executing FFmpeg decrypt command (key length: ${key.length})');
        if (await attempt(preferredExt, key) ||
            (preferredExt == '.flac' && await attempt('.m4a', key)) ||
            ((preferredExt == '.flac' || preferredExt == '.m4a') &&
                await attempt('.mp4', key)) ||
            await attempt('.mp4', key, forceMov: true)) {
          await prepareOutput?.call(plan!.workingPath);
          final path = await FFmpegOutput.finalize(
            plan: plan!,
            inputPath: inputPath,
            deleteOriginal: deleteOriginal,
          );
          published = path != null;
          return path;
        }
      }
      _log.e('FFmpeg decrypt failed: ${lastResult?.output ?? 'unknown error'}');
      return null;
    } catch (e) {
      _log.e('Failed to finalize decrypted file: $e');
      return null;
    } finally {
      if (!published && plan != null) {
        await FFmpegOutput.cleanup(plan!.workingPath);
      }
    }
  }
}
