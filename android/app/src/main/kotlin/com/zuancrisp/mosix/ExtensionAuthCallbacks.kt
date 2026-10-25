package com.zuancrisp.mosix

import android.net.Uri
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Process-owned inbox: Activity recreation must not discard browser results. */
internal class ExtensionAuthCallbacks {
    data class Callback(val state: String, val code: String, val sessionGrant: Boolean)

    private val pending = linkedSetOf<Callback>()
    private val processing = Mutex()

    fun offer(uri: Uri): Boolean {
        if (!uri.scheme.equals("spotiflac", ignoreCase = true)) return false
        val host = uri.host.orEmpty().lowercase(java.util.Locale.US)
        val grant = host == "session-grant"
        if (!grant && host != "callback" && host != "spotify-callback") return false
        val state = uri.getQueryParameter("state")?.trim().orEmpty()
        val code = (if (grant) uri.getQueryParameter("grant") ?: uri.getQueryParameter("code")
            else uri.getQueryParameter("code"))?.trim().orEmpty()
        if (state.isEmpty() || code.isEmpty() || state.length > 4096 || code.length > 16384) return false
        synchronized(pending) { pending.add(Callback(state, code, grant)) }
        return true
    }

    suspend fun drain(complete: suspend (Callback) -> Unit) = processing.withLock {
        while (true) {
            val callback = synchronized(pending) { pending.firstOrNull() } ?: break
            // If initialization fails, leave the callback available for retry.
            complete(callback)
            synchronized(pending) { pending.remove(callback) }
        }
    }
}
