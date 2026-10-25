import 'package:flutter/foundation.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/ffmpeg_decryption.dart';
import 'package:mornye/services/ffmpeg_metadata.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/ffmpeg_replaygain.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/audio_conversion_utils.dart';

export 'package:mornye/services/ffmpeg_models.dart';

/// Compatibility entry point for callers; feature modules own the operations.
class FFmpegService {
  @visibleForTesting
  static List<String> buildCoverResizeArguments({
    required String inputPath,
    required String outputPath,
    required int maxDimension,
  }) => FFmpegMetadata.buildCoverResizeArguments(
    inputPath: inputPath,
    outputPath: outputPath,
    maxDimension: maxDimension,
  );

  /// Preserves aspect ratio, allowing upscale to the explicitly chosen size.
  static Future<bool> resizeCoverArt({
    required String inputPath,
    required String outputPath,
    required int maxDimension,
  }) => FFmpegMetadata.resizeCoverArt(
    inputPath: inputPath,
    outputPath: outputPath,
    maxDimension: maxDimension,
  );

  @visibleForTesting
  static ({int width, int height})? imageDimensionsFromProperties(
    Map<dynamic, dynamic> properties,
  ) => FFmpegProbe.imageDimensionsFromProperties(properties);

  /// Reads image dimensions without decoding a bitmap into Dart memory.
  static Future<({int width, int height})?> probeImageDimensions(
    String filePath,
  ) => FFmpegProbe.imageDimensions(filePath);

  static Future<String?> probePrimaryAudioCodec(String filePath) =>
      FFmpegProbe.audioCodec(filePath);

  static bool isLosslessAudioCodec(String? codec) =>
      FFmpegProbe.isLosslessAudioCodec(codec);

  /// Checks the native FLAC magic, distinguishing FLAC-in-MP4 payloads.
  static Future<bool> isNativeFlacFile(String filePath) =>
      FFmpegProbe.isNativeFlacFile(filePath);

  static Future<String?> convertM4aToFlac(
    String inputPath, {
    String? sourceCodec,
    @visibleForTesting Future<FFmpegResult> Function(List<String>)? execute,
  }) => FFmpegConversion.convertM4aToFlac(
    inputPath,
    sourceCodec: sourceCodec,
    execute: execute,
  );

  /// Corrects the suffix without replacing an existing sibling file.
  static Future<String> ensureNativeFlacExtension(String inputPath) =>
      FFmpegConversion.ensureNativeFlacExtension(inputPath);

  static Future<String?> decryptWithDescriptor({
    required String inputPath,
    required DownloadDecryptionDescriptor descriptor,
    bool deleteOriginal = true,
    Future<void> Function(String)? prepareOutput,
  }) => FFmpegDecryption.decrypt(
    inputPath: inputPath,
    descriptor: descriptor,
    deleteOriginal: deleteOriginal,
    prepareOutput: prepareOutput,
  );

  /// Measures EBU R128 loudness and true peak using a -18 LUFS reference.
  static Future<ReplayGainResult?> scanReplayGain(
    String filePath, {
    void Function()? onUnsupportedDecoder,
  }) => FFmpegReplayGain.scan(
    filePath,
    onUnsupportedDecoder: onUnsupportedDecoder,
  );

  @visibleForTesting
  static ReplayGainResult? parseReplayGainScan(
    FFmpegResult result, {
    void Function()? onUnsupportedDecoder,
  }) => FFmpegReplayGain.parseScan(
    result,
    onUnsupportedDecoder: onUnsupportedDecoder,
  );

  /// With [returnTempPath], hands temp output to [onTempReady] for SAF write and
  /// cleanup by the caller. Otherwise publishes to the local file.
  static Future<bool> writeAlbumReplayGainTags(
    String filePath,
    String albumGain,
    String albumPeak, {
    bool returnTempPath = false,
    void Function(String tempPath)? onTempReady,
  }) => FFmpegReplayGain.writeAlbumTags(
    filePath,
    albumGain,
    albumPeak,
    returnTempPath: returnTempPath,
    onTempReady: onTempReady,
  );

  static Future<bool> writeTrackReplayGainTags(
    String filePath,
    String trackGain,
    String trackPeak,
  ) => FFmpegReplayGain.writeTrackTags(filePath, trackGain, trackPeak);

  static Future<String?> embedMetadata({
    required String flacPath,
    String? coverPath,
    Map<String, String>? metadata,
    String artistTagMode = artistTagModeJoined,
  }) => FFmpegMetadata.embedMetadata(
    flacPath: flacPath,
    coverPath: coverPath,
    metadata: metadata,
    artistTagMode: artistTagMode,
  );

  static Future<String?> embedMetadataToMp3({
    required String mp3Path,
    String? coverPath,
    Map<String, String>? metadata,
    String artistTagMode = artistTagModeJoined,
    bool preserveMetadata = false,
  }) => FFmpegMetadata.embedMetadataToMp3(
    mp3Path: mp3Path,
    coverPath: coverPath,
    metadata: metadata,
    artistTagMode: artistTagMode,
    preserveMetadata: preserveMetadata,
  );

  static Future<String?> embedMetadataToOpus({
    required String opusPath,
    String? coverPath,
    Map<String, String>? metadata,
    String artistTagMode = artistTagModeJoined,
    bool preserveMetadata = false,
    @visibleForTesting Future<FFmpegResult> Function(List<String>)? execute,
  }) => FFmpegMetadata.embedMetadataToOpus(
    opusPath: opusPath,
    coverPath: coverPath,
    metadata: metadata,
    artistTagMode: artistTagMode,
    preserveMetadata: preserveMetadata,
    execute: execute,
  );

  static Future<String?> embedMetadataToM4a({
    required String m4aPath,
    String? coverPath,
    Map<String, String>? metadata,
    String artistTagMode = artistTagModeJoined,
    bool preserveMetadata = true,
    @visibleForTesting Future<FFmpegResult> Function(List<String>)? execute,
  }) => FFmpegMetadata.embedMetadataToM4a(
    m4aPath: m4aPath,
    coverPath: coverPath,
    metadata: metadata,
    artistTagMode: artistTagMode,
    preserveMetadata: preserveMetadata,
    execute: execute,
  );

  /// Converts with metadata and cover preservation; lossless caps never upscale.
  static Future<String?> convertAudioFormat({
    required String inputPath,
    required String targetFormat,
    required String bitrate,
    required Map<String, String> metadata,
    String? coverPath,
    String artistTagMode = artistTagModeJoined,
    bool deleteOriginal = true,
    int? sourceBitDepth,
    LosslessConversionQuality losslessQuality =
        const LosslessConversionQuality(),
    LosslessConversionProcessing losslessProcessing =
        const LosslessConversionProcessing(),
  }) => FFmpegConversion.convertAudioFormat(
    inputPath: inputPath,
    targetFormat: targetFormat,
    bitrate: bitrate,
    metadata: metadata,
    coverPath: coverPath,
    artistTagMode: artistTagMode,
    deleteOriginal: deleteOriginal,
    sourceBitDepth: sourceBitDepth,
    losslessQuality: losslessQuality,
    losslessProcessing: losslessProcessing,
  );

  static Future<List<String>?> splitCueToTracks({
    required String audioPath,
    required String outputDir,
    required List<CueSplitTrackInfo> tracks,
    required Map<String, String> albumMetadata,
    String? coverPath,
    void Function(int current, int total)? onProgress,
  }) => FFmpegConversion.splitCueToTracks(
    audioPath: audioPath,
    outputDir: outputDir,
    tracks: tracks,
    albumMetadata: albumMetadata,
    coverPath: coverPath,
    onProgress: onProgress,
  );
}
