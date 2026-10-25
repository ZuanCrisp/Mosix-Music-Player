package com.zuancrisp.mosix

import java.io.File

/** Failure belongs to this read, never to a different document or provider.
 * The direct callback owns and closes its descriptor before fallback starts. */
internal fun <T> readSafMetadataWithFallback(
    directRead: () -> T?,
    fallbackRead: () -> T?,
    accept: (T) -> Boolean = { true },
    retryDirectOnFailure: Boolean = false,
    onFailure: (Exception?) -> Unit = {},
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
    // A remote provider may have completed its download/cache by now. Reopen
    // once; never repeatedly copy whole songs or publish filename guesses.
    val retried = if (retryDirectOnFailure) attempt(directRead) else null
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
