package com.zuancrisp.mosix

import android.content.Context
import android.net.Uri
import com.zuancrisp.mosix.SafDownloadHandler.mimeTypeForExt
import com.zuancrisp.mosix.SafDownloadHandler.normalizeExt
import com.zuancrisp.mosix.NativeFinalizationPolicy.displayAudioQuality
import com.zuancrisp.mosix.NativeFinalizationPolicy.normalizeAudioCodec
import org.json.JSONObject
import java.io.File
import java.util.Locale
import kotlin.math.abs

internal fun NativeDownloadFinalizer.finalizeMetadata(context: Context, input: NativeDownloadFinalizer.FinalizeInput, state: NativeDownloadFinalizer.FinalizeState) {
    if (!input.request.optBoolean("embed_metadata", false)) return
    if (!state.filePath.startsWith("content://")) {
        embedBasicMetadata(context, state.filePath, input, formatForPath(state.filePath))
        return
    }

    val tempPath = SafDownloadHandler.copyContentUriToTemp(context, state.filePath)
        ?: throw IllegalStateException("failed to copy SAF file for metadata")
    try {
        embedBasicMetadata(context, tempPath, input, formatForPath(state.fileName.ifBlank { tempPath }))
        val tempFile = File(tempPath)
        val finalName = desiredFileName(input, state, normalizeExt(state.fileName.substringAfterLast('.', "")))
        val newUri = SafDownloadHandler.writeFileToSaf(
            context = context,
            treeUriStr = input.request.optString("saf_tree_uri", ""),
            relativeDir = input.request.optString("saf_relative_dir", ""),
            fileName = finalName,
            mimeType = mimeTypeForExt(finalName.substringAfterLast('.', "")),
            srcPath = tempFile.absolutePath,
        ) ?: throw IllegalStateException("failed to write metadata-updated SAF file")
        if (newUri != state.filePath) SafDownloadHandler.deleteContentUri(context, state.filePath)
        state.filePath = newUri
        state.fileName = finalName
    } finally {
        File(tempPath).delete()
    }
}

internal fun NativeDownloadFinalizer.writeReplayGain(
    context: Context,
    input: NativeDownloadFinalizer.FinalizeInput,
    state: NativeDownloadFinalizer.FinalizeState,
    shouldCancel: () -> Boolean,
): JSONObject? {
    if (!input.request.optBoolean("embed_replaygain", false)) return null
    val ext = normalizeExt(File(state.filePath).extension)
    val fileExt = if (state.filePath.startsWith("content://")) {
        normalizeExt(state.fileName.substringAfterLast('.', ""))
    } else {
        ext
    }
    if (
        fileExt != ".flac" &&
        fileExt != ".m4a" &&
        fileExt != ".mp4" &&
        fileExt != ".mp3" &&
        fileExt != ".opus" &&
        fileExt != ".ogg"
    ) return null

    val scanPath = if (state.filePath.startsWith("content://")) {
        SafDownloadHandler.copyContentUriToTemp(context, state.filePath)
            ?: throw IllegalStateException("failed to copy SAF file for ReplayGain")
    } else {
        state.filePath
    }
    val deleteScanPath = scanPath != state.filePath
    val scan = try {
        scanReplayGain(scanPath, shouldCancel)
            ?: throw IllegalStateException("ReplayGain analysis produced no valid measurement")
    } finally {
        if (deleteScanPath) File(scanPath).delete()
    }
    checkCancelled(shouldCancel)
    val fields = JSONObject()
        .put("replaygain_track_gain", scan.trackGain)
        .put("replaygain_track_peak", scan.trackPeak)
    writeReplayGainFields(context, state.filePath, fields)

    return JSONObject()
        .put("album_key", albumKey(input))
        .put("file_path", state.filePath)
        .put("file_name", state.fileName)
        .put("track_id", trackString(input, "id", input.request.optString("spotify_id", input.itemId)))
        .put("integrated_lufs", scan.integratedLufs)
        .put("true_peak_linear", scan.truePeakLinear)
        .put("duration_secs", replayGainDurationSeconds(input))
        .put("track_gain", scan.trackGain)
        .put("track_peak", scan.trackPeak)
}

internal fun NativeDownloadFinalizer.writeReplayGainFields(context: Context, path: String, fields: JSONObject) {
    if (!path.startsWith("content://")) {
        writeLocalReplayGainFields(context, path, fields)
        return
    }

    val tempPath = SafDownloadHandler.copyContentUriToTemp(context, path)
        ?: throw IllegalStateException("failed to copy SAF file for ReplayGain write")
    try {
        writeLocalReplayGainFields(context, tempPath, fields)
        val uri = Uri.parse(path)
        context.contentResolver.openOutputStream(uri, "wt")?.use { output ->
            File(tempPath).inputStream().use { input -> input.copyTo(output) }
            SafDownloadHandler.syncOutputStream(output)
        } ?: throw IllegalStateException("failed to write ReplayGain back to SAF")
    } finally {
        File(tempPath).delete()
    }
}

private fun NativeDownloadFinalizer.writeLocalReplayGainFields(context: Context, path: String, fields: JSONObject) {
    val backend = createCoreBackend(context)
    val result = parseObject(backend.editFileMetadata(path, fields.toString()))
    val method = result.optString("method", "")
    check(
        result.optBoolean("success", false) &&
            !result.has("error") &&
            (method == "native" || method.startsWith("native_")),
    ) { "ReplayGain native write did not complete: $result" }

    val metadata = parseObject(backend.readFileMetadata(path, ""))
    check(!metadata.has("error")) { "ReplayGain verification failed: $metadata" }
    val isOpus = metadata.optString("audio_codec", "") == "opus"
    for (key in fields.keys()) {
        // Opus stores only R128 gain, exposed by the Rust reader as dB.
        if (isOpus && key.endsWith("_peak")) continue
        val expected = fields.optString(key, "").trim().removeSuffix("dB").trim().toDoubleOrNull()
        val actual = metadata.optString(key, "").trim().removeSuffix("dB").trim().toDoubleOrNull()
        val tolerance = if (key.endsWith("_gain")) 0.01 else 0.000001
        check(expected != null && actual != null && abs(actual - expected) <= tolerance) {
            "ReplayGain verification failed for $key"
        }
    }
}

internal fun NativeDownloadFinalizer.refreshFinalAudioQualityMetadata(context: Context, result: JSONObject, state: NativeDownloadFinalizer.FinalizeState) {
    if (!supportsAudioMetadataProbe(state.filePath, state.fileName)) return

    val probePath = if (state.filePath.startsWith("content://")) {
        SafDownloadHandler.copyContentUriToTemp(context, state.filePath) ?: return
    } else {
        state.filePath
    }
    val deleteProbePath = probePath != state.filePath

    try {
        val metadata = parseObject(createCoreBackend(context).readFileMetadata(probePath, state.fileName))
        if (metadata.has("error")) return

        if (!metadata.optBoolean("metadataFromFilename", false) &&
            (metadata.has("audio_codec") || metadata.has("format") ||
                metadata.has("replaygain_track_gain") || metadata.has("replaygain_album_gain"))
        ) {
            state.replayGainMetadataScanned = true
            state.hasReplayGain = listOf("replaygain_track_gain", "replaygain_album_gain").any { key ->
                val value = metadata.optString(key, "").trim()
                val gain = (if (value.endsWith("dB", ignoreCase = true)) value.dropLast(2) else value)
                    .trim().toDoubleOrNull()
                gain != null && gain.isFinite()
            }
        }

        if (metadata.has("lyrics") || metadata.has("hasLyrics")) {
            state.lyricsMetadataScanned = true
            state.hasEmbeddedLyrics =
                metadata.optBoolean("hasLyrics", false) ||
                NativeFinalizationPolicy.hasUsableLyricsContent(
                    metadata.optString("lyrics", ""),
                )
        }

        val bitDepth = optPositiveInt(metadata, "bit_depth")
        val sampleRate = optPositiveInt(metadata, "sample_rate")
        val probedCodec = normalizeAudioCodec(
            metadata.optString("audio_codec", "").ifBlank {
                metadata.optString("codec", "").ifBlank {
                    metadata.optString("format", "")
                }
            }
        )
        if (probedCodec != null) {
            state.audioCodec = probedCodec
            result.put("audio_codec", probedCodec)
        }
        if (bitDepth != null) {
            state.bitDepth = bitDepth
            result.put("actual_bit_depth", bitDepth)
        }
        if (sampleRate != null) {
            state.sampleRate = sampleRate
            result.put("actual_sample_rate", sampleRate)
        }
        val bitrateKbps = optPositiveBitrateKbps(metadata, "bitrate")
            ?: optPositiveBitrateKbps(metadata, "bit_rate")
        if (bitrateKbps != null) {
            state.bitrateKbps = bitrateKbps
            result.put("bitrate", bitrateKbps)
        }

        val displayQuality = displayAudioQuality(
            filePath = state.filePath,
            fileName = state.fileName,
            bitDepth = state.bitDepth,
            sampleRate = state.sampleRate,
            bitrateKbps = state.bitrateKbps,
            audioCodec = state.audioCodec,
            storedQuality = state.quality,
        )
        if (displayQuality != null) {
            state.quality = displayQuality
        }
    } catch (_: Exception) {
    } finally {
        if (deleteProbePath) File(probePath).delete()
    }
}

private fun NativeDownloadFinalizer.supportsAudioMetadataProbe(filePath: String, fileName: String): Boolean {
    val lowerPath = filePath.trim().lowercase(Locale.ROOT)
    val lowerName = fileName.trim().lowercase(Locale.ROOT)
    if (lowerPath.startsWith("content://")) return true
    return lowerPath.endsWith(".flac") ||
        lowerPath.endsWith(".m4a") ||
        lowerPath.endsWith(".mp4") ||
        lowerPath.endsWith(".aac") ||
        lowerPath.endsWith(".mp3") ||
        lowerPath.endsWith(".opus") ||
        lowerPath.endsWith(".ogg") ||
        lowerName.endsWith(".flac") ||
        lowerName.endsWith(".m4a") ||
        lowerName.endsWith(".mp4") ||
        lowerName.endsWith(".aac") ||
        lowerName.endsWith(".mp3") ||
        lowerName.endsWith(".opus") ||
        lowerName.endsWith(".ogg")
}

internal fun NativeDownloadFinalizer.albumKey(input: NativeDownloadFinalizer.FinalizeInput): String {
    val albumId = trackString(input, "albumId", "")
    if (albumId.isNotBlank()) return "id:$albumId"
    val albumName = trackString(input, "albumName", input.request.optString("album_name", ""))
    val albumArtist = resolvedAlbumArtist(input)
    return "name:$albumName|$albumArtist"
}

private fun NativeDownloadFinalizer.replayGainDurationSeconds(input: NativeDownloadFinalizer.FinalizeInput): Double {
    val duration = NativeFinalizationPolicy.durationMilliseconds(
        input.request.optLong("duration_ms", 0L),
        trackInt(input, "duration", 0).toLong(),
    )
    return if (duration > 0L) duration / 1000.0 else 1.0
}
