import 'package:mornye/models/download_result.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/int_utils.dart';

typedef DownloadCompletionAudio = ({
  String quality,
  int? bitDepth,
  int? sampleRate,
  int? bitrate,
  String? format,
  Map<String, dynamic>? metadata,
});

/// Resolves the audio actually written, reusing metadata read before SAF
/// publication. Failed probes retain the backend values and cached metadata.
Future<DownloadCompletionAudio> resolveDownloadCompletionAudio({
  required Map<String, dynamic> result,
  required String filePath,
  String? fileName,
  required String quality,
  Map<String, dynamic>? metadata,
  required Future<Map<String, dynamic>> Function(String) readMetadata,
  required void Function(String) debug,
}) async {
  final download = DownloadResult.fromMap(result);
  var bitDepth = download.actualBitDepth;
  var sampleRate = download.actualSampleRate;
  var format =
      normalizeAudioFormatValue(download.reportedFormat) ??
      normalizeAudioFormatValue(audioFormatForPath(filePath));
  var bitrate = download.bitrateKbps;
  final lowerPath = filePath.toLowerCase();
  if (isContentUri(filePath) ||
      const [
        '.flac',
        '.m4a',
        '.mp4',
        '.aac',
        '.mp3',
        '.opus',
        '.ogg',
      ].any(lowerPath.endsWith)) {
    try {
      final probed = metadata != null && metadata['error'] == null
          ? metadata
          : await readMetadata(filePath);
      if (probed['error'] == null) {
        metadata = probed;
        bitDepth = readPositiveInt(probed['bit_depth']) ?? bitDepth;
        sampleRate = readPositiveInt(probed['sample_rate']) ?? sampleRate;
        format =
            normalizeAudioFormatValue(
              probed['audio_codec']?.toString() ?? probed['format']?.toString(),
            ) ??
            format;
        bitrate =
            readPositiveBitrateKbps(probed['bitrate'] ?? probed['bit_rate']) ??
            bitrate;
        quality =
            resolveDisplayQuality(
              filePath: filePath,
              fileName: fileName,
              detectedFormat: format,
              bitDepth: bitDepth,
              sampleRate: sampleRate,
              bitrateKbps: bitrate,
              storedQuality: quality,
            ) ??
            quality;
      }
    } catch (error) {
      debug('Final audio metadata probe failed for $filePath: $error');
    }
  }

  final isLossy =
      isLossyAudioFormat(format) ||
      lowerPath.endsWith('.mp3') ||
      lowerPath.endsWith('.opus') ||
      lowerPath.endsWith('.ogg');
  return (
    quality: quality,
    bitDepth: isLossy ? null : bitDepth,
    sampleRate: isLossy ? null : sampleRate,
    bitrate: bitrate,
    format: format,
    metadata: metadata,
  );
}
