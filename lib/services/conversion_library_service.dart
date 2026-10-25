import 'package:mornye/models/download_history.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';

class ConversionLibraryService {
  const ConversionLibraryService._();

  static Future<T?> _retryTransientSaf<T>(
    Future<T?> Function() operation,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await operation();
        if (result != null) return result;
      } catch (error) {
        lastError = error;
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (lastError != null) throw lastError;
    return null;
  }

  static Future<String?> copySafSourceToTemp(String uri) {
    return _retryTransientSaf(() => PlatformBridge.copyContentUriToTemp(uri));
  }

  static Future<({String uri, String fileName})?> publishSafConversion({
    required String treeUri,
    required String relativeDir,
    required String originalFileName,
    required String targetFormat,
    required String sourcePath,
    required bool keepOriginal,
  }) async {
    final target = convertTargetExtAndMime(targetFormat);
    final requestedName = convertedOutputFileName(
      originalFileName: originalFileName,
      targetFormat: targetFormat,
    );

    final replacesSameNamedDocument =
        !keepOriginal &&
        requestedName.toLowerCase() == originalFileName.toLowerCase();
    if (!replacesSameNamedDocument) {
      final result = await _retryTransientSaf(
        () => PlatformBridge.createUniqueSafFileFromPath(
          treeUri: treeUri,
          relativeDir: relativeDir,
          fileName: requestedName,
          mimeType: target.mime,
          srcPath: sourcePath,
        ),
      );
      if (result == null) return null;
      final uri = (result['uri'] as String? ?? '').trim();
      final fileName = (result['file_name'] as String? ?? '').trim();
      if (uri.isEmpty || fileName.isEmpty) return null;
      return (uri: uri, fileName: fileName);
    }

    final uri = await _retryTransientSaf(
      () => PlatformBridge.createSafFileFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: requestedName,
        mimeType: target.mime,
        srcPath: sourcePath,
      ),
    );
    if (uri == null || uri.trim().isEmpty) return null;
    return (uri: uri, fileName: requestedName);
  }

  static Future<void> persistHistoryConversion({
    required DownloadHistoryItem source,
    required String newFilePath,
    required String newQuality,
    required String targetFormat,
    required String bitrate,
    required int? bitDepth,
    required int? sampleRate,
    required bool keepOriginal,
    String? newSafFileName,
  }) async {
    final convertedBitrate = convertedAudioBitrateKbps(
      targetFormat: targetFormat,
      bitrate: bitrate,
    );
    final isLossless = isLosslessConversionTarget(targetFormat);

    if (!keepOriginal) {
      await HistoryDatabase.instance.updateFilePath(
        source.id,
        newFilePath,
        newSafFileName: newSafFileName,
        newQuality: newQuality,
        newFormat: normalizedConvertedAudioFormat(targetFormat),
        newBitrate: convertedBitrate,
        newBitDepth: bitDepth,
        newSampleRate: sampleRate,
        clearAudioSpecs: !isLossless,
      );
      return;
    }

    final converted = source.toJson()
      ..['id'] = convertedLibraryItemId(source.id, newFilePath)
      ..['filePath'] = newFilePath
      ..['downloadedAt'] = DateTime.now().toUtc().toIso8601String()
      ..['quality'] = newQuality
      ..['format'] = normalizedConvertedAudioFormat(targetFormat)
      ..['bitrate'] = convertedBitrate
      ..['bitDepth'] = isLossless ? bitDepth : null
      ..['sampleRate'] = isLossless ? sampleRate : null;
    if (newSafFileName != null) {
      converted['safFileName'] = newSafFileName;
    }
    await HistoryDatabase.instance.upsert(converted);
  }
}
