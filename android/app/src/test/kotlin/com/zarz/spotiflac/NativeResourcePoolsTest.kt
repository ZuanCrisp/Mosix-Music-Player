package com.zuancrisp.mosix

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeResourcePoolsTest {
    @Test
    fun keyedLockPoolReclaimsAnIdleKey() {
        val pool = KeyedLockPool<String>()

        assertEquals("done", pool.withLock("track.flac") { "done" })
        assertEquals(0, pool.activeKeyCount())
    }

    @Test
    fun keyedLockPoolKeepsOneMonitorWhileAnotherCallerWaits() {
        val pool = KeyedLockPool<String>()
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)

        val first = thread {
            pool.withLock("same-name.flac") {
                firstEntered.countDown()
                releaseFirst.await(2, TimeUnit.SECONDS)
            }
        }
        assertTrue(firstEntered.await(2, TimeUnit.SECONDS))

        val second = thread {
            pool.withLock("same-name.flac") {
                secondEntered.countDown()
            }
        }
        assertFalse(secondEntered.await(100, TimeUnit.MILLISECONDS))
        assertEquals(1, pool.activeKeyCount())

        releaseFirst.countDown()
        first.join(2_000)
        second.join(2_000)
        assertTrue(secondEntered.await(100, TimeUnit.MILLISECONDS))
        assertEquals(0, pool.activeKeyCount())
    }

    @Test
    fun boundedRegistryConsumesIdsAndEvictsOldestEntries() {
        val registry = BoundedRegistry<Long>(maxEntries = 2)
        registry.add(1)
        registry.add(2)
        registry.add(3)

        assertFalse(registry.consume(1))
        assertTrue(registry.consume(2))
        assertTrue(registry.consume(3))
        assertEquals(0, registry.size())
    }
}
