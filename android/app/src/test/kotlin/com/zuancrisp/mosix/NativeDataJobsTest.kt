package com.zuancrisp.mosix

import com.mosix.backend.NativeDataJobException
import com.mosix.backend.RequestLease
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Test

/** Exercises the actual generated Kotlin ABI against the host Rust library.
 * Set MOSIX_NATIVE_HOST_LIBRARY to the host dylib/so and optionally
 * MOSIX_JNA_HOST_DIRECTORY to desktop JNA's native dispatch directory.
 * Ordinary Android-only checkouts skip these host ABI tests.
 */
class NativeDataJobsTest {
    companion object {
        @BeforeClass @JvmStatic
        fun configureHostLibrary() {
            val library = System.getenv("MOSIX_NATIVE_HOST_LIBRARY")
            assumeTrue("Build the Rust host library for ABI tests", !library.isNullOrBlank())
            require(File(library!!).isFile) { "Native host library does not exist" }
            System.setProperty("uniffi.component.mosix_mobile.libraryOverride", library)
            System.getenv("MOSIX_JNA_HOST_DIRECTORY")?.let {
                System.setProperty("jna.boot.library.path", it)
            }
        }
    }

    private fun <T> withLease(id: String, block: (RequestLease) -> T): T {
        val lease = NativeDataJobs.acquire(id)
        return try { block(lease) } finally { NativeDataJobs.release(id, lease) }
    }

    @Test fun pureJobsWorkBeforeExtensionInitializationAndCancelledLeasesRejectWork() {
        val id = UUID.randomUUID().toString()
        withLease(id) { lease ->
            val request = JSONObject().put("operation", "palette")
            val pixels = byteArrayOf(255.toByte(), 0, 0, 255.toByte())
            val result = JSONObject(RustCoreBackend.runDataJob(request, pixels, lease))
            val color = result.getJSONArray("colors").getJSONArray(0)
            assertEquals(0xff0000ffL, color.getLong(0))
            assertEquals(1, color.getInt(1))
            NativeDataJobs.cancel(id)
            assertTrue(lease.isCancelled())
            val error = assertThrows(NativeDataJobException.Operation::class.java) {
                RustCoreBackend.runDataJob(request, pixels, lease)
            }
            assertTrue(error.message!!.contains("cancelled"))
        }
    }

    @Test fun cancellationCannotLeakIntoAnotherRequestOrAnIdleReplacement() {
        val cancelledId = UUID.randomUUID().toString()
        val otherId = UUID.randomUUID().toString()
        withLease(cancelledId) { cancelled ->
            withLease(otherId) { other ->
                NativeDataJobs.cancel(cancelledId)
                assertTrue(cancelled.isCancelled())
                assertFalse(other.isCancelled())
            }
        }
        withLease(cancelledId) { replacement ->
            assertFalse(replacement.isCancelled())
        }
    }

    @Test fun unknownAndFinishedCancellationCannotPoisonLaterWork() {
        val id = UUID.randomUUID().toString()
        NativeDataJobs.cancel(id)
        withLease(id) { lease -> assertFalse(lease.isCancelled()) }
        NativeDataJobs.cancel(id)
        withLease(id) { lease -> assertFalse(lease.isCancelled()) }
    }

    @Test fun sharedIdRetainsCancellationUntilEveryLeaseHasFinished() {
        val id = UUID.randomUUID().toString()
        val first = NativeDataJobs.acquire(id)
        val second = NativeDataJobs.acquire(id)
        try {
            NativeDataJobs.release(id, first)
            NativeDataJobs.release(id, first)
            NativeDataJobs.cancel(id)
            assertTrue(second.isCancelled())
        } finally {
            NativeDataJobs.release(id, first)
            NativeDataJobs.release(id, second)
        }
        NativeDataJobs.cancel(id)
        withLease(id) { lease -> assertFalse(lease.isCancelled()) }
    }

    @Test fun acquiredJobCanBeCancelledWhileStillQueuedForIo() {
        val id = UUID.randomUUID().toString()
        val executor = Executors.newSingleThreadExecutor()
        val occupied = CountDownLatch(1)
        val proceed = CountDownLatch(1)
        val lease = NativeDataJobs.acquire(id)
        try {
            executor.submit {
                occupied.countDown()
                check(proceed.await(5, TimeUnit.SECONDS))
            }
            assertTrue(occupied.await(5, TimeUnit.SECONDS))
            val queued = executor.submit<String> {
                RustCoreBackend.runDataJob(
                    JSONObject().put("operation", "palette"),
                    byteArrayOf(255.toByte(), 0, 0, 255.toByte()),
                    lease,
                )
            }
            NativeDataJobs.cancel(id)
            proceed.countDown()
            val error = assertThrows(ExecutionException::class.java) {
                queued.get(5, TimeUnit.SECONDS)
            }
            assertTrue(error.cause is NativeDataJobException.Operation)
            assertTrue(error.cause!!.message!!.contains("cancelled"))
        } finally {
            proceed.countDown()
            executor.shutdownNow()
            NativeDataJobs.release(id, lease)
        }
    }

    @Test fun streamedHashJobUsesTheGeneratedByteArrayAndLeaseABI() {
        val path = Files.createTempFile("native-job-hash-", ".bin")
        try {
            Files.write(path, "abc".toByteArray())
            withLease(UUID.randomUUID().toString()) { lease ->
                val request = JSONObject().put("operation", "hash_file").put("path", path.toString())
                val result = JSONObject(RustCoreBackend.runDataJob(request, byteArrayOf(), lease))
                assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                    result.getString("sha256"))
            }
        } finally {
            Files.deleteIfExists(path)
        }
    }
}
