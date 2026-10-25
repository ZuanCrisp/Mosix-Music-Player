package com.zuancrisp.mosix

import android.content.Context
import android.util.Base64
import android.util.Log
import com.zuancrisp.mosix.NativeFinalizationPolicy.normalizeAudioCodec
import com.zuancrisp.mosix.NativeFinalizationPolicy.resolvePreferredDecryptionExtension
import java.io.File
import java.util.Locale
import java.util.concurrent.CancellationException

internal fun NativeDownloadFinalizer.finalizeDecryption(
    context: Context,
    input: NativeDownloadFinalizer.FinalizeInput,
    state: NativeDownloadFinalizer.FinalizeState,
    shouldCancel: () -> Boolean,
) {
    val descriptor = input.result.optJSONObject("decryption")
    val key = descriptor?.optString("key", "")?.trim().orEmpty()
        .ifBlank { input.result.optString("decryption_key", "").trim() }
    if (key.isEmpty()) return

    val inputFormat = descriptor?.optString("input_format", "")?.trim().orEmpty().ifBlank { "mov" }
    val requestedOutputExt = descriptor?.optString("output_extension", "")?.trim().orEmpty()
    val preferredExt = resolvePreferredDecryptionExtension(state.filePath, requestedOutputExt)
    val localInput = materializeForFFmpeg(context, input, state)
    val originalPath = localInput

    var outputPath = buildOutputPath(localInput, preferredExt)
    var successPath: String? = null
    var lastOutput = ""

    try {
        for (candidate in decryptionKeyCandidates(key)) {
            checkCancelled(shouldCancel)
            val attempts = mutableListOf<Triple<String, Boolean, Boolean>>()
            attempts.add(Triple(outputPath, preferredExt == ".flac", false))
            if (preferredExt == ".flac") {
                attempts.add(Triple(buildOutputPath(localInput, ".m4a"), false, false))
            }
            if (preferredExt == ".flac" || preferredExt == ".m4a") {
                attempts.add(Triple(buildOutputPath(localInput, ".mp4"), false, false))
            }
            // MOV muxer fallback for codecs the MP4 muxer rejects (e.g. AC-4):
            // keeps the .mp4 filename but stores the codec params.
            attempts.add(Triple(buildOutputPath(localInput, ".mp4"), false, true))

            for ((candidateOutput, mapAudioOnly, forceMov) in attempts) {
                val stagedOutput = stagedConversionPath(candidateOutput)
                try {
                    val audioMap = if (mapAudioOnly) "-map 0:a " else ""
                    // Force the flac muxer when the target extension is
                    // .flac. Without this override FFmpeg keeps the ISO-BMFF
                    // stream layout, producing FLAC-in-MP4 under a .flac
                    // filename which downstream native FLAC tag writers
                    // cannot read.
                    val muxerOverride = when {
                        forceMov -> "-f mov "
                        candidateOutput.lowercase(Locale.ROOT).endsWith(".flac") -> "-f flac "
                        else -> ""
                    }
                    val command = "-v error -decryption_key ${q(candidate)} -f $inputFormat -i ${q(localInput)} ${audioMap}-c copy ${muxerOverride}${q(stagedOutput)} -y"
                    val result = runFFmpeg(command, shouldCancel)
                    lastOutput = result.second
                    if (result.first && File(stagedOutput).exists() &&
                        promoteStagedConversion(stagedOutput, candidateOutput)
                    ) {
                        successPath = candidateOutput
                        outputPath = candidateOutput
                        break
                    }
                    File(stagedOutput).delete()
                } catch (e: CancellationException) {
                    File(stagedOutput).delete()
                    throw e
                } catch (e: Exception) {
                    File(stagedOutput).delete()
                    throw e
                }
            }
            if (successPath != null) break
        }

        val rawDecryptedPath = successPath ?: throw IllegalStateException("decrypt failed: $lastOutput")
        val decryptedPath = normalizeDecryptedIsoBmffAudioPath(
            rawDecryptedPath,
            state,
            shouldCancel,
        )
        replaceStatePath(context, input, state, decryptedPath, deleteOld = true)
    } finally {
        if (successPath == null && outputPath != localInput) {
            File(outputPath).delete()
        }
        if (originalPath != successPath && originalPath.startsWith(context.cacheDir.absolutePath)) {
            File(originalPath).delete()
        }
    }
}

private fun NativeDownloadFinalizer.normalizeDecryptedIsoBmffAudioPath(
    path: String,
    state: NativeDownloadFinalizer.FinalizeState,
    shouldCancel: () -> Boolean,
): String {
    if (!isMP4ContainerFile(path)) return path

    val probedCodec = probePrimaryAudioCodec(path, shouldCancel)
    val codec = normalizeAudioCodec(probedCodec.ifBlank { state.audioCodec.orEmpty() })
    val desiredExt = NativeFinalizationPolicy.isoBmffAudioExtension(codec)
    state.audioCodec = codec
    if (path.lowercase(Locale.ROOT).endsWith(desiredExt)) return path

    val target = File(buildOutputPath(path, desiredExt))
    if (target.exists()) {
        Log.w(TAG, "Cannot normalize ISO-BMFF audio extension; ${target.name} already exists")
        return path
    }
    val source = File(path)
    if (!source.renameTo(target)) {
        Log.w(TAG, "Failed to normalize ISO-BMFF audio extension to ${target.name}")
        return path
    }
    Log.i(
        TAG,
        "ISO-BMFF audio renamed: ${source.name} -> ${target.name} " +
            "(codec=${codec.orEmpty().ifBlank { "unknown" }})",
    )
    return target.absolutePath
}

private fun NativeDownloadFinalizer.decryptionKeyCandidates(raw: String): List<String> {
    val candidates = linkedSetOf<String>()
    fun add(value: String) {
        val trimmed = value.trim()
        if (trimmed.isNotEmpty()) candidates.add(trimmed)
    }
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return emptyList()
    add(trimmed)
    val noPrefix = if (trimmed.startsWith("0x", ignoreCase = true)) trimmed.substring(2) else trimmed
    add(noPrefix)
    val compactHex = noPrefix.replace(Regex("[^0-9a-fA-F]"), "")
    if (compactHex.isNotEmpty() && compactHex.length % 2 == 0) add(compactHex)
    try {
        val decoded = Base64.decode(noPrefix.replace(Regex("\\s+"), ""), Base64.DEFAULT)
        if (decoded.isNotEmpty()) {
            add(decoded.joinToString("") { "%02x".format(it) })
        }
    } catch (_: Exception) {
    }
    return candidates.toList()
}
