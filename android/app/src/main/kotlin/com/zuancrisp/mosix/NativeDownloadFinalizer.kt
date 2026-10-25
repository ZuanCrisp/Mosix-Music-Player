package com.zuancrisp.mosix

import android.content.Context
import android.util.Log
import com.antonkarpenko.ffmpegkit.FFmpegKit
import com.antonkarpenko.ffmpegkit.FFmpegSessionCompleteCallback
import com.zuancrisp.mosix.SafDownloadHandler.mimeTypeForExt
import com.zuancrisp.mosix.SafDownloadHandler.normalizeExt
import com.zuancrisp.mosix.NativeFinalizationPolicy.normalizeAudioCodec
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.concurrent.CancellationException
import kotlin.math.pow

object NativeDownloadFinalizer {
    internal const val TAG = "NativeFinalizer"
    const val NATIVE_WORKER_CONTRACT_VERSION = 1
    internal val activeFFmpegSessionIds = mutableSetOf<Long>()
    internal val nativeFFmpegSessionIds = BoundedRegistry<Long>(maxEntries = 256)
    internal val activeFFmpegSessionLock = Any()
    internal val ffmpegCompleteCallbackLock = Any()
    internal val qualityVariantNameLocks = KeyedLockPool<String>()
    internal var forwardedFFmpegCompleteCallback: FFmpegSessionCompleteCallback? = null
    internal val nativeFilteringFFmpegCompleteCallback = FFmpegSessionCompleteCallback { session ->
        val isNativeSession = nativeFFmpegSessionIds.consume(session.sessionId)
        if (!isNativeSession) {
            val delegate = synchronized(ffmpegCompleteCallbackLock) {
                forwardedFFmpegCompleteCallback
            }
            delegate?.apply(session)
        }
    }

    internal data class FinalizeInput(
        val itemId: String,
        val request: JSONObject,
        val item: JSONObject,
        val track: JSONObject,
        val result: JSONObject,
    )

    internal data class FinalizeState(
        var filePath: String,
        var fileName: String,
        var quality: String,
        var bitDepth: Int?,
        var sampleRate: Int?,
        var bitrateKbps: Int? = null,
        var audioCodec: String? = null,
        var pendingExternalLrc: String? = null,
        var pendingExternalLrcFileName: String? = null,
        var lyricsMetadataScanned: Boolean = false,
        var hasEmbeddedLyrics: Boolean = false,
        var externalLrcWritten: Boolean = false,
        var replayGainMetadataScanned: Boolean = false,
        var hasReplayGain: Boolean = false,
    )

    internal data class ReplayGainScan(
        val trackGain: String,
        val trackPeak: String,
        val integratedLufs: Double,
        val truePeakLinear: Double,
    )

    fun cancelActiveWork() {
        val sessionIds = synchronized(activeFFmpegSessionLock) {
            activeFFmpegSessionIds.toList()
        }
        for (sessionId in sessionIds) {
            try {
                FFmpegKit.cancel(sessionId)
            } catch (_: Exception) {
            }
        }
    }

    private inline fun <T> timedStage(name: String, block: () -> T): T {
        val started = System.nanoTime()
        try {
            return block()
        } finally {
            Log.d(TAG, "Finalization stage $name took ${(System.nanoTime() - started) / 1_000_000}ms")
        }
    }

    fun finalize(
        context: Context,
        itemId: String,
        requestJson: String,
        itemJson: String,
        result: JSONObject,
        settingsJson: String = "{}",
        shouldCancel: () -> Boolean = { false },
    ): JSONObject {
        if (!result.optBoolean("success", false)) return result

        val itemObject = parseObject(itemJson)
        val requestObject = parseObject(requestJson)
        validateRequestContract(requestObject)
        if (result.optBoolean("saf_deferred_publish", false) && result.has("saf_relative_dir")) {
            requestObject.put("saf_relative_dir", result.getString("saf_relative_dir"))
        }
        val input = FinalizeInput(
            itemId = itemId,
            request = requestObject,
            item = itemObject,
            track = itemObject.optJSONObject("track") ?: JSONObject(),
            result = result,
        )
        val track = if (input.track.length() > 0) input.track else input.item.optJSONObject("track") ?: JSONObject()
        val effectiveInput = input.copy(track = track)

        val initialPath = result.optString("file_path", "").trim()
        if (initialPath.isEmpty()) {
            result.put("success", false)
            result.put("error", "Native finalizer received empty file path")
            result.put("error_type", "unknown")
            return result
        }

        val state = FinalizeState(
            filePath = initialPath,
            fileName = result.optString("file_name", "").ifBlank { File(initialPath).name },
            quality = requestQuality(effectiveInput),
            bitDepth = optPositiveInt(result, "actual_bit_depth"),
            sampleRate = optPositiveInt(result, "actual_sample_rate"),
            bitrateKbps = optPositiveBitrateKbps(result, "bitrate")
                ?: optPositiveBitrateKbps(result, "actual_bitrate"),
            audioCodec = normalizeAudioCodec(
                result.optString("audio_codec", "").ifBlank { result.optString("format", "") },
            ),
        )

        // Once the output has been published to its final destination the audio
        // is complete; failures past that point are bookkeeping and must never
        // trigger the destructive cleanup below.
        var outputPublished = result.optBoolean("already_exists", false)
        try {
            var qualityMetadataRefreshed = false
            if (!result.optBoolean("already_exists", false)) {
                checkCancelled(shouldCancel)
                finalizeDecryption(context, effectiveInput, state, shouldCancel)
                checkCancelled(shouldCancel)
                timedStage("container conversion") {
                    finalizeContainerConversion(context, effectiveInput, state, shouldCancel)
                }
                checkCancelled(shouldCancel)
                timedStage("metadata") {
                    finalizeMetadata(context, effectiveInput, state)
                }
                checkCancelled(shouldCancel)
                timedStage("extension post-processing") {
                    runPostProcessing(context, effectiveInput, state, shouldCancel)
                }
                checkCancelled(shouldCancel)
                try {
                    timedStage("automatic conversion") {
                        finalizeAutoConversion(
                            context,
                            effectiveInput,
                            state,
                            shouldCancel,
                        )
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Auto-conversion is best effort: a completed source file
                    // must remain usable if FFmpeg or metadata embedding fails.
                    Log.w(TAG, "Automatic conversion failed; keeping source: ${e.message}")
                    result.put("auto_conversion_warning", e.message ?: "conversion failed")
                }
                checkCancelled(shouldCancel)
                try {
                    val replayGain = timedStage("ReplayGain") {
                        writeReplayGain(context, effectiveInput, state, shouldCancel)
                    }
                    if (replayGain != null) {
                        result.put("replaygain", replayGain)
                        state.replayGainMetadataScanned = true
                        state.hasReplayGain = true
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Gain tagging is optional; keep the completed audio if
                    // its native editor or the verification step fails.
                    Log.w(TAG, "ReplayGain write failed: ${e.message}")
                    result.put("replaygain_warning", e.message ?: "ReplayGain write failed")
                }
                checkCancelled(shouldCancel)
                try {
                    timedStage("quality probe") {
                        refreshFinalAudioQualityMetadata(context, result, state)
                    }
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "Quality metadata refresh failed (non-fatal): ${e.message}")
                }
                qualityMetadataRefreshed = true
                try {
                    finalizeQualityVariantFilename(context, effectiveInput, state)
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "Quality variant rename failed (non-fatal): ${e.message}")
                }
                checkCancelled(shouldCancel)
                try {
                    writeExternalLrc(context, effectiveInput, state)
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "External LRC write failed (non-fatal): ${e.message}")
                }
                checkCancelled(shouldCancel)
                timedStage("publish") {
                    if (isDeferredSafPublish(effectiveInput)) {
                        publishDeferredSafOutput(context, effectiveInput, state)
                    } else {
                        promoteStagedSafOutputIfNeeded(context, effectiveInput, state)
                    }
                }
                outputPublished = true
            } else {
                // Match the Dart queue: an existing download still runs enabled
                // extension hooks. It may be the input left by an interrupted
                // finalizer, so file existence does not prove the hook finished.
                // outputPublished keeps this pre-existing input out of cleanup.
                checkCancelled(shouldCancel)
                runPostProcessing(context, effectiveInput, state, shouldCancel)
                checkCancelled(shouldCancel)
            }
            if (!qualityMetadataRefreshed) {
                try {
                    refreshFinalAudioQualityMetadata(context, result, state)
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "Quality metadata refresh failed (non-fatal): ${e.message}")
                }
            }

            val saveDownloadHistory = parseObject(settingsJson)
                .optBoolean("save_download_history", true)
            val preserveQualityVariant = input.request
                .optBoolean("allow_quality_variant", false)
            val history = if (
                saveDownloadHistory &&
                !result.optBoolean("publish_collision_existing", false) &&
                !(preserveQualityVariant && result.optBoolean("already_exists", false))
            ) {
                try {
                    buildHistoryRow(effectiveInput, state).also {
                        NativeHistoryStore.upsert(
                            context,
                            it,
                            deduplicateTrack = !preserveQualityVariant,
                        )
                    }
                } catch (e: Exception) {
                    // History is bookkeeping; never fail (and never delete) a
                    // finished download because the insert failed.
                    android.util.Log.w(TAG, "History write failed (non-fatal): ${e.message}")
                    null
                }
            } else {
                null
            }

            result.put("file_path", state.filePath)
            if (state.fileName.isNotBlank()) result.put("file_name", state.fileName)
            // Extension result fields describe the pre-conversion input.
            // Publish the actual container with the finalized path and name.
            val finalName = if (state.filePath.startsWith("content://")) state.fileName else state.filePath
            val finalExtension = normalizeExt(File(finalName).extension)
            if (finalExtension.isNotBlank()) {
                result.put("actual_extension", finalExtension)
                result.put("output_extension", finalExtension)
                result.put("actual_container", finalExtension.removePrefix("."))
                if (result.has("container")) result.put("container", finalExtension.removePrefix("."))
            }
            if (!state.audioCodec.isNullOrBlank()) {
                result.put("audio_codec", state.audioCodec)
                result.put("format", state.audioCodec)
            }
            result.put("requires_container_conversion", false)
            result.remove("requiresContainerConversion")
            if (state.quality.isNotBlank()) result.put("quality", state.quality)
            result.put("native_finalized", true)
            result.put("history_written", history != null)
            if (history != null) result.put("history_item", historyToJson(history))
        } catch (e: CancellationException) {
            if (!outputPublished) {
                cleanupFailedFinalizationOutput(context, result, initialPath, state.filePath)
            }
            result.put("success", false)
            result.put("error", "Native finalization cancelled")
            result.put("error_type", "cancelled")
            result.put("native_finalized", false)
        } catch (e: Exception) {
            if (!outputPublished) {
                cleanupFailedFinalizationOutput(context, result, initialPath, state.filePath)
            }
            result.put("success", false)
            result.put("error", "Native finalization failed: ${e.message}")
            result.put("error_type", "unknown")
            result.put("native_finalized", false)
        }

        return result
    }

    internal fun checkCancelled(shouldCancel: () -> Boolean) {
        if (shouldCancel()) {
            throw CancellationException("Native finalization cancelled")
        }
    }

    fun replayGainAlbumKey(requestJson: String, itemJson: String): String {
        val item = parseObject(itemJson)
        val input = FinalizeInput(
            itemId = item.optString("id", ""),
            request = parseObject(requestJson),
            item = item,
            track = item.optJSONObject("track") ?: JSONObject(),
            result = JSONObject(),
        )
        return albumKey(input)
    }

    fun writeAlbumReplayGain(context: Context, entriesJson: String): String {
        val entries = org.json.JSONArray(entriesJson)
        val grouped = linkedMapOf<String, MutableList<JSONObject>>()
        for (index in 0 until entries.length()) {
            val entry = entries.optJSONObject(index) ?: continue
            val key = entry.optString("album_key", "")
            if (key.isBlank()) continue
            grouped.getOrPut(key) { mutableListOf() }.add(entry)
        }

        var albumsWritten = 0
        var filesWritten = 0
        for ((_, group) in grouped) {
            if (group.size <= 1) continue
            var sumWeightedPower = 0.0
            var sumDuration = 0.0
            var maxPeak = 0.0
            for (entry in group) {
                val integrated = entry.optDouble("integrated_lufs", Double.NaN)
                if (integrated.isNaN()) continue
                val duration = entry.optDouble("duration_secs", 1.0).let { if (it > 0) it else 1.0 }
                val peak = entry.optDouble("true_peak_linear", 1.0)
                sumWeightedPower += 10.0.pow(integrated / 10.0) * duration
                sumDuration += duration
                if (peak > maxPeak) maxPeak = peak
            }
            if (sumDuration <= 0) continue
            val albumLufs = 10.0 * kotlin.math.log10(sumWeightedPower / sumDuration)
            val albumGainDb = -18.0 - albumLufs
            val albumGain = "${if (albumGainDb >= 0) "+" else ""}${"%.2f".format(Locale.US, albumGainDb)} dB"
            val albumPeak = "%.6f".format(Locale.US, if (maxPeak > 0) maxPeak else 1.0)
            val fields = JSONObject()
                .put("replaygain_album_gain", albumGain)
                .put("replaygain_album_peak", albumPeak)
            var wroteForAlbum = false
            for (entry in group) {
                val path = entry.optString("file_path", "")
                if (path.isBlank()) continue
                try {
                    writeReplayGainFields(context, path, fields)
                    filesWritten++
                    wroteForAlbum = true
                } catch (e: Exception) {
                    android.util.Log.w("Mosix", "Failed to write native album ReplayGain: ${e.message}")
                }
            }
            if (wroteForAlbum) albumsWritten++
        }

        return JSONObject()
            .put("success", true)
            .put("albums_written", albumsWritten)
            .put("files_written", filesWritten)
            .toString()
    }

    internal fun parseObject(raw: String): JSONObject {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return JSONObject()
        return try {
            JSONObject(trimmed)
        } catch (_: Exception) {
            JSONObject()
        }
    }

    private fun cleanupFailedFinalizationOutput(
        context: Context,
        result: JSONObject,
        initialPath: String,
        currentPath: String,
    ) {
        if (result.optBoolean("already_exists", false)) return

        val paths = linkedSetOf<String>()
        if (initialPath.isNotBlank()) paths.add(initialPath)
        if (currentPath.isNotBlank()) paths.add(currentPath)
        val resultPath = result.optString("file_path", "").trim()
        if (resultPath.isNotBlank()) paths.add(resultPath)

        var cleanedAny = false
        for (path in paths) {
            cleanedAny = deleteFinalizerOwnedOutput(context, path) || cleanedAny
        }
        if (cleanedAny) {
            result.put("native_finalizer_cleaned_output", true)
        }
    }

    private fun deleteFinalizerOwnedOutput(context: Context, path: String): Boolean {
        if (path.startsWith("content://")) {
            return SafDownloadHandler.deleteContentUri(context, path)
        }

        return try {
            val file = File(path)
            if (!file.exists()) return false

            val canonicalPath = file.canonicalPath
            val appDataPath = File(context.applicationInfo.dataDir).canonicalPath
            val cachePath = context.cacheDir.canonicalPath
            if (!canonicalPath.startsWith("$appDataPath/") && !canonicalPath.startsWith("$cachePath/")) {
                return false
            }
            file.delete()
        } catch (_: Exception) {
            false
        }
    }

    private fun requestQuality(input: FinalizeInput): String {
        return input.request.optString("quality", "").ifBlank {
            input.item.optString("qualityOverride", "").ifBlank { "LOSSLESS" }
        }
    }

    internal fun materializeForFFmpeg(context: Context, input: FinalizeInput, state: FinalizeState): String {
        if (!state.filePath.startsWith("content://")) return state.filePath
        return SafDownloadHandler.copyContentUriToTemp(context, state.filePath)
            ?: throw IllegalStateException("failed to copy SAF file")
    }

    internal fun replaceStatePath(
        context: Context,
        input: FinalizeInput,
        state: FinalizeState,
        localOutput: String,
        deleteOld: Boolean,
    ) {
        if (state.filePath.startsWith("content://")) {
            val outputFile = File(localOutput)
            val finalName = desiredFileName(input, state, outputFile.extension)
            val newUri = SafDownloadHandler.writeFileToSaf(
                context = context,
                treeUriStr = input.request.optString("saf_tree_uri", ""),
                relativeDir = input.request.optString("saf_relative_dir", ""),
                fileName = finalName,
                mimeType = mimeTypeForExt(outputFile.extension),
                srcPath = outputFile.absolutePath,
            ) ?: throw IllegalStateException("failed to write finalized file to SAF")
            SafDownloadHandler.deleteContentUri(context, state.filePath)
            state.filePath = newUri
            state.fileName = finalName
            outputFile.delete()
            return
        }

        val oldPath = state.filePath
        state.filePath = localOutput
        state.fileName = File(localOutput).name
        if (deleteOld && oldPath != localOutput) File(oldPath).delete()
    }

    internal fun trackString(input: FinalizeInput, key: String, fallback: String): String =
        cleanMetadataString(input.track.optString(key, "")).ifBlank { cleanMetadataString(fallback) }

    internal fun requestString(input: FinalizeInput, key: String): String =
        cleanMetadataString(input.request.optString(key, ""))

    internal fun resultString(input: FinalizeInput, key: String): String =
        cleanMetadataString(input.result.optString(key, ""))

    internal fun resolvedAlbumArtist(input: FinalizeInput): String =
        NativeFinalizationPolicy.authoritativeAlbumArtist(
            requestValue = requestString(input, "album_artist"),
            trackValue = trackString(input, "albumArtist", ""),
            providerResultValue = resultString(input, "album_artist"),
        )

    internal fun metadataCoverUrl(input: FinalizeInput): String =
        NativeFinalizationPolicy.metadataCoverUrl(
            resultValue = resultString(input, "cover_url"),
            requestValue = requestString(input, "cover_url"),
            trackValue = trackString(input, "coverUrl", ""),
        )

    internal fun trackInt(input: FinalizeInput, key: String, fallback: Int): Int {
        val value = input.track.optInt(key, 0)
        return if (value > 0) value else fallback
    }

    internal fun optPositiveInt(obj: JSONObject, key: String): Int? {
        val value = obj.optInt(key, 0)
        return if (value > 0) value else null
    }

    internal fun optPositiveBitrateKbps(obj: JSONObject, key: String): Int? {
        val value = optPositiveInt(obj, key) ?: return null
        val kbps = if (value >= 10000) {
            Math.round(value / 1000.0).toInt()
        } else {
            value
        }
        return if (kbps >= 16) kbps else null
    }

    internal fun positiveOrNull(primary: Int, fallback: Int): Int? {
        val value = if (primary > 0) primary else fallback
        return if (value > 0) value else null
    }

    internal fun cleanMetadataString(value: String?): String {
        val trimmed = value?.trim().orEmpty()
        return if (trimmed.equals("null", ignoreCase = true)) "" else trimmed
    }

    internal fun q(value: String): String = "\"${value.replace("\"", "\\\"")}\""
}
