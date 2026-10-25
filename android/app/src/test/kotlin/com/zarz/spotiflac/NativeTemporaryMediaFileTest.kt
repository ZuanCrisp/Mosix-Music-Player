package com.zuancrisp.mosix

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeTemporaryMediaFileTest {
    @Test
    fun completedCopyClosesTheInputAndTransfersTheTemporaryFileToItsCaller() {
        val directory = Files.createTempDirectory("native-media-copy-test").toFile()
        try {
            val temporary = File.createTempFile("saf_", ".flac", directory)
            var closed = false
            val input = object : ByteArrayInputStream("audio".toByteArray()) {
                override fun close() {
                    closed = true
                    super.close()
                }
            }

            assertSame(temporary, copyToTemporaryMediaFile(temporary) { input })
            assertTrue(closed)
            assertEquals("audio", temporary.readText())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun absentOrDeniedInputRemovesTheUnusedTemporaryFile() {
        val directory = Files.createTempDirectory("native-media-copy-test").toFile()
        try {
            val absent = File.createTempFile("saf_", ".flac", directory)
            assertEquals(null, copyToTemporaryMediaFile(absent) { null })
            assertFalse(absent.exists())

            val denied = File.createTempFile("saf_", ".flac", directory)
            val failure = SecurityException("permission revoked")
            assertSame(failure, assertThrows(SecurityException::class.java) {
                copyToTemporaryMediaFile(denied) { throw failure }
            })
            assertFalse(denied.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun interruptedCopyClosesTheInputRemovesPartialBytesAndPreservesTheError() {
        val directory = Files.createTempDirectory("native-media-copy-test").toFile()
        try {
            val temporary = File.createTempFile("saf_", ".flac", directory)
            val failure = IOException("remote read interrupted")
            var closed = false
            val input = object : InputStream() {
                var started = false
                override fun read(): Int = throw failure
                override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                    if (started) throw failure
                    started = true
                    bytes[offset] = 1
                    return 1
                }
                override fun close() { closed = true }
            }

            assertSame(failure, assertThrows(IOException::class.java) {
                copyToTemporaryMediaFile(temporary) { input }
            })
            assertTrue(closed)
            assertFalse(temporary.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun postProcessingAlwaysRetiresItsInputWithoutClaimingSourceOrReplacementFiles() {
        val directory = Files.createTempDirectory("native-media-scope-test").toFile()
        try {
            val source = File(directory, "saved.flac").also { it.writeText("saved audio") }
            val replacement = File(directory, "shared.flac").also { it.writeText("shared audio") }
            for (response in listOf("success", "hook rejected", "output missing", "SAF write failed")) {
                val temporary = File.createTempFile("saf_", ".flac", directory)
                temporary.writeText("temporary audio")
                assertEquals(response, withOwnedTemporaryMediaFile(temporary) { input ->
                    assertEquals("temporary audio", input.readText())
                    response
                })
                assertFalse(temporary.exists())
            }

            val temporary = File.createTempFile("saf_", ".flac", directory)
            val failure = IllegalStateException("postProcess failed")
            assertSame(failure, assertThrows(IllegalStateException::class.java) {
                withOwnedTemporaryMediaFile(temporary) { throw failure }
            })
            assertFalse(temporary.exists())
            assertEquals("saved audio", source.readText())
            assertEquals("shared audio", replacement.readText())
        } finally {
            directory.deleteRecursively()
        }
    }
}
