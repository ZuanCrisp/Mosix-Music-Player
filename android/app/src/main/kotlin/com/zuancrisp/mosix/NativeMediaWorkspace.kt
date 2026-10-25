package com.zuancrisp.mosix

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream

/** One workspace per process; in-flight media must survive cache eviction. */
internal class NativeMediaWorkspace(privateDirectory: File) {
    val directory = File(privateDirectory, "native-media-work")

    init {
        // These app-owned scratch files cannot resume after process death.
        // Reclaim them once at startup, before any download or scan can begin.
        ensureDirectory().listFiles()?.forEach { it.delete() }
    }

    fun ensureDirectory(): File {
        if (!directory.mkdirs() && !directory.isDirectory) {
            throw IOException("Could not prepare native media workspace: ${directory.path}")
        }
        return directory
    }

    fun createTemporaryFile(prefix: String, suffix: String): File =
        File.createTempFile(prefix, suffix, ensureDirectory())
}

/** Only the caller's newly created input belongs to this operation, not a hook's replacement. */
internal inline fun <T> withOwnedTemporaryMediaFile(file: File, block: (File) -> T): T {
    try {
        return block(file)
    } finally {
        try { file.delete() } catch (_: Exception) {}
    }
}

/** Transfers ownership only after a complete copy; failed reads retire the partial input. */
internal fun copyToTemporaryMediaFile(file: File, openInput: () -> InputStream?): File? {
    var complete = false
    try {
        openInput()?.use { input ->
            FileOutputStream(file).use { output ->
                input.copyTo(output, bufferSize = 256 * 1024)
            }
        } ?: return null
        complete = true
        return file
    } finally {
        if (!complete) {
            try { file.delete() } catch (_: Exception) {}
        }
    }
}
