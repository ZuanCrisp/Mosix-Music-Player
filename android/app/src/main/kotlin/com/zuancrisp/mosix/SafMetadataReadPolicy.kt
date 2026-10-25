package com.zuancrisp.mosix

import java.io.File

/** How long a failed read waits before its one retry. A provider that failed
 * under load (FUSE, a busy SD card) usually answers again shortly after. */
private const val SAF_RETRY_DELAY_MS = 400L

/** Failure belongs to this read, never to a different document or provider.
 * The direct callback owns and closes its descriptor before fallback starts. */
internal fun <T> readSafMetadataWithFallback(
    directRead: () -> T?,
    fallbackRead: () -> T?,
    accept: (T) -> Boolean = { true },
    retryDirectOnFailure: Boolean = false,
    onFailure: (Exception?) -> Unit = {},
    waitBeforeRetry: () -> Unit = { Thread.sleep(SAF_RETRY_DELAY_MS) },
): T? {
    var lastError: Exception? = null
    fun attempt(read: () -> T?): T? = try {
        read()?.takeIf(accept)
    } catch (error: Exception) {
        lastError = error
        null
    }

    val direct = attempt(directRead)
    if (direct != null) return direct
    val copied = attempt(fallbackRead)
    if (copied != null) return copied
    // A remote provider may have completed its download/cache by now, and a
    // local one may have recovered from a transient error. Reopen once after
    // a short wait; never repeatedly copy whole songs or publish filename guesses.
    val retried = if (retryDirectOnFailure) {
        waitBeforeRetry()
        attempt(directRead)
    } else {
        null
    }
    if (retried == null) onFailure(lastError)
    return retried
}

internal fun <T> readLyricsWithSafCopy(
    path: String,
    copyToTemp: (String) -> File?,
    read: (String) -> T,
): T? {
    if (!path.startsWith("content://")) return read(path)
    val temporary = copyToTemp(path) ?: return null
    return try {
        read(temporary.absolutePath)
    } finally {
        temporary.delete()
    }
}

internal fun <T> readLyricsRequestWithSafCopy(
    method: String,
    arguments: Map<*, *>,
    copyToTemp: (String) -> File?,
    read: (Map<*, *>) -> T,
): T? {
    val fileKey = if (method == "fetchAndSaveLyrics") "audio_file_path" else "file_path"
    val path = arguments[fileKey] as? String ?: ""
    return readLyricsWithSafCopy(path, copyToTemp) { localPath ->
        read(arguments + (fileKey to localPath))
    }
}
