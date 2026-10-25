package com.zuancrisp.mosix

import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile

internal fun safScanCheckpointPath(outputPath: String): String = "$outputPath.state"

internal fun loadSafScanCheckpoint(path: String): MutableMap<String, Long> {
    val checkpoint = File(path)
    if (!checkpoint.exists()) return mutableMapOf()
    val entries = mutableMapOf<String, Long>()
    try {
        checkpoint.forEachLine(Charsets.UTF_8) { line ->
            val separator = line.indexOf('\t')
            if (separator <= 0) return@forEachLine
            val uri = line.substring(0, separator)
            val modified = line.substring(separator + 1).toLongOrNull() ?: return@forEachLine
            entries[uri] = modified
        }
    } catch (e: Exception) {
        android.util.Log.w("Mosix", "SAF scan: failed reading checkpoint: ${e.message}")
    }
    return entries
}

internal fun reconcileSafScanCheckpoint(
    outputPath: String,
    loaded: MutableMap<String, Long>,
): MutableMap<String, Long> {
    val output = File(outputPath)
    if (!output.exists()) return loaded

    val outputEntries = mutableMapOf<String, Long>()
    try {
        output.forEachLine(Charsets.UTF_8) { line ->
            if (line.isBlank()) return@forEachLine
            try {
                val obj = JSONObject(line)
                val filePath = obj.optString("filePath", "").trim()
                if (filePath.isNotBlank()) {
                    val modified = obj.optLong("fileModTime", 0L)
                    val cueMarker = filePath.indexOf("#track")
                    val key = if (cueMarker > 0) filePath.substring(0, cueMarker) else filePath
                    outputEntries[key] = modified
                }
            } catch (_: Exception) {}
        }
    } catch (e: Exception) {
        android.util.Log.w("Mosix", "SAF scan: failed reconciling checkpoint: ${e.message}")
        return loaded
    }

    loaded.clear()
    loaded.putAll(outputEntries)
    return loaded
}

internal fun countSafScanRows(path: String): Int {
    val output = File(path)
    if (!output.exists()) return 0
    return try {
        output.useLines(Charsets.UTF_8) { lines -> lines.count { it.isNotBlank() } }
    } catch (e: Exception) {
        android.util.Log.w("Mosix", "SAF scan: failed counting existing rows: ${e.message}")
        0
    }
}

internal fun repairSafScanOutput(path: String) {
    val output = File(path)
    if (!output.exists()) return
    try {
        RandomAccessFile(output, "rw").use { file ->
            var position = file.length() - 1
            while (position >= 0) {
                file.seek(position)
                if (file.readByte().toInt() == '\n'.code) {
                    file.setLength(position + 1)
                    return
                }
                position--
            }
            // No complete line survived the interruption.
            file.setLength(0)
        }
    } catch (e: Exception) {
        android.util.Log.w("Mosix", "SAF scan: failed repairing output: ${e.message}")
    }
}
