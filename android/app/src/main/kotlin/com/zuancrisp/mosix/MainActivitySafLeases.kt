package com.zuancrisp.mosix

import android.net.Uri
import java.util.UUID

/**
 * Opens a short-lived descriptor lease for zero-copy SAF playback. The
 * returned proc path identifies the lease. The Android audio plugin must
 * duplicate this descriptor, never reopen it (AppFuse rejects reopening).
 * A small hard cap protects against abandoned method calls.
 */
internal fun MainActivity.openSafPlaybackLease(uriStr: String): Map<String, String>? {
    if (!uriStr.startsWith("content://")) return null
    val descriptor = try {
        contentResolver.openFileDescriptor(Uri.parse(uriStr), "r")
    } catch (e: Exception) {
        android.util.Log.w("Mosix", "Failed to open SAF playback descriptor: ${e.message}")
        null
    } ?: return null

    if (!isSeekableSafDescriptor(descriptor)) {
        descriptor.close()
        return null
    }
    val token = UUID.randomUUID().toString()
    synchronized(playbackLeaseLock) {
        while (playbackLeases.size >= 4) {
            val oldest = playbackLeases.entries.firstOrNull() ?: break
            playbackLeases.remove(oldest.key)
            try {
                oldest.value.close()
            } catch (_: Exception) {}
        }
        playbackLeases[token] = descriptor
    }
    return mapOf(
        "token" to token,
        "path" to "/proc/self/fd/${descriptor.fd}",
        "display_name" to buildUriDisplayName(Uri.parse(uriStr)),
    )
}

internal fun MainActivity.closeSafPlaybackLease(token: String) {
    if (token.isBlank()) return
    val descriptor = synchronized(playbackLeaseLock) {
        playbackLeases.remove(token)
    } ?: return
    try {
        descriptor.close()
    } catch (_: Exception) {}
}

internal fun MainActivity.closeAllSafPlaybackLeases() {
    val descriptors = synchronized(playbackLeaseLock) {
        val openDescriptors = playbackLeases.values.toList()
        playbackLeases.clear()
        openDescriptors
    }
    descriptors.forEach { descriptor ->
        try {
            descriptor.close()
        } catch (_: Exception) {}
    }
}
