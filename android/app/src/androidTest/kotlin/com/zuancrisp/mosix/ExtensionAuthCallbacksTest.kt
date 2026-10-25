package com.zuancrisp.mosix

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ExtensionAuthCallbacksTest {
    private val uri = Uri.parse("mornye://session-grant?state=nonce&grant=grant")

    @Test
    fun coldCallbackWaitsForReadyBackendAndDrainsOnlyOnce() = runBlocking {
        val callbacks = ExtensionAuthCallbacks()
        assertTrue(callbacks.offer(uri))
        assertTrue(callbacks.offer(uri))
        val started = CompletableDeferred<Unit>()
        val ready = CompletableDeferred<Unit>()
        val handled = mutableListOf<ExtensionAuthCallbacks.Callback>()
        val first = async {
            callbacks.drain {
                started.complete(Unit)
                ready.await()
                handled.add(it)
            }
        }
        started.await()
        val second = async { callbacks.drain { handled.add(it) } }
        assertTrue(handled.isEmpty())
        ready.complete(Unit)
        first.await()
        second.await()
        assertEquals(listOf(ExtensionAuthCallbacks.Callback("nonce", "grant", true)), handled)
    }

    @Test
    fun interruptedHandlingLeavesTheResultAvailable() = runBlocking {
        val callbacks = ExtensionAuthCallbacks()
        callbacks.offer(uri)
        try {
            callbacks.drain { throw IllegalStateException("backend not ready") }
            fail("Expected an interrupted callback")
        } catch (_: IllegalStateException) {
        }
        var handled = 0
        callbacks.drain { handled++ }
        callbacks.drain { handled++ }
        assertEquals(1, handled)
    }

    @Test
    fun onlySupportedCallbacksWithStateAndCodeAreAccepted() = runBlocking {
        val callbacks = ExtensionAuthCallbacks()
        for (invalid in listOf(
            "https://session-grant?state=nonce&grant=grant",
            "mornye://unknown?state=nonce&code=code",
            "mornye://session-grant?grant=grant",
            "mornye://callback?state=nonce",
        )) assertFalse(callbacks.offer(Uri.parse(invalid)))
        assertTrue(callbacks.offer(Uri.parse("mornye://callback?state=oauth&code=code")))
        callbacks.drain {
            assertEquals("oauth", it.state)
            assertEquals("code", it.code)
            assertFalse(it.sessionGrant)
        }
    }
}
