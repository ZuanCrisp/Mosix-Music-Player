import 'dart:io';

import 'package:mornye/models/download_result.dart';
import 'package:mornye/services/download_saf_file_replacer.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/file_access.dart';

/// Finalizes a requested lossless container using the measured audio stream.
/// Native FLAC bytes can be renamed; FLAC-in-MP4 still needs remuxing.
class DownloadContainerFinalizer {
  const DownloadContainerFinalizer({
    required this.probeCodec,
    required this.isNativeFlac,
    required this.ensureFlacExtension,
    required this.convertToFlac,
    required this.replaceSafFile,
    required this.debug,
  });

  final Future<String?> Function(String) probeCodec;
  final Future<bool> Function(String) isNativeFlac;
  final Future<String> Function(String) ensureFlacExtension;
  final Future<String?> Function(String) convertToFlac;
  final ReplaceSafDownloadFile replaceSafFile;
  final void Function(String) debug;

  Future<String?> finalize({
    required DownloadResult result,
    required String filePath,
    required String requestedExtension,
    required bool forceConversion,
    required bool useSaf,
    String? treeUri,
    String relativeDir = '',
    String? fallbackFileName,
    Future<void> Function(String path)? embedMetadata,
  }) async {
    if (requestedExtension != '.flac') return filePath;
    forceConversion = forceConversion || result.requiresContainerConversion;
    final outputExtension = result.outputExtension(path: filePath);
    final lowerPath = filePath.toLowerCase();
    final isSafSource = isContentUri(filePath);
    final pathLooksLikeM4a =
        lowerPath.endsWith('.m4a') ||
        lowerPath.endsWith('.mp4') ||
        outputExtension == '.m4a' ||
        outputExtension == '.mp4';
    if (!forceConversion && !pathLooksLikeM4a && !isSafSource) return filePath;
    // Provider/decryption extensions describe the input container, not its
    // audio codec. Inspect the stream before preserving an M4A/MP4 download.
    bool shouldConvert(String? codec) {
      if (shouldAttemptLosslessContainerConversion(
        forceConversion: forceConversion,
        probedCodec: codec,
      )) {
        return true;
      }
      debug(
        'Preserving native container; audio codec is ${codec ?? 'unknown'}, no FLAC container conversion needed.',
      );
      return false;
    }

    if (useSaf && isSafSource) {
      if (treeUri == null || treeUri.isEmpty) return null;
      var preserve = false;
      final name = result.fileName ?? fallbackFileName ?? 'track';
      final flacName = '${name.replaceFirst(RegExp(r'\.[^.]+$'), '')}.flac';
      final uri = await replaceSafFile(
        uri: filePath,
        treeUri: treeUri,
        relativeDir: relativeDir,
        op: (tempPath, addCleanup) async {
          final codec = await probeCodec(tempPath);
          final nativeFlac = codec == 'flac' && await isNativeFlac(tempPath);
          if (!shouldConvert(codec)) {
            preserve = true;
            return null;
          }
          if (nativeFlac) {
            debug(
              'Native FLAC payload detected in temporary container; publishing as FLAC and embedding metadata.',
            );
            await embedMetadata?.call(tempPath);
            return (tempPath, flacName);
          }
          final output = await convertToFlac(tempPath);
          if (output == null) return null;
          addCleanup(output);
          await embedMetadata?.call(output);
          return (output, flacName);
        },
      );
      if (preserve) return filePath;
      if (uri == null) return null;
      result.markFlacContainer(path: uri, name: flacName);
      return uri;
    }
    final codec = await probeCodec(filePath);
    final nativeFlac = codec == 'flac' && await isNativeFlac(filePath);
    if (!shouldConvert(codec)) return filePath;
    final output = nativeFlac
        ? await ensureFlacExtension(filePath)
        : await convertToFlac(filePath);
    if (output == null) return null;
    await embedMetadata?.call(output);
    result.markFlacContainer(
      path: output,
      name: useSaf
          ? finalizedAudioFileName(
              fileName:
                  result.fileName ??
                  fallbackFileName ??
                  File(output).uri.pathSegments.last,
              localPath: output,
              fallbackExtension: '.flac',
            )
          : File(output).uri.pathSegments.last,
    );
    return output;
  }
}
