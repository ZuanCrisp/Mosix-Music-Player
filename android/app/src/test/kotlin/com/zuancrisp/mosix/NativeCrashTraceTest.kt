package com.zuancrisp.mosix

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeCrashTraceTest {
    @Test
    fun decodesActualSignalAbortAndBacktraceFieldsWithoutMemoryDumpContents() {
        val frame = number(1, 0x1234) + text(4, "decoder_abort") + number(5, 8) +
            text(6, "/data/app/libaudio.so") + text(8, "abcd1234")
        val thread = number(1, 22) + text(2, "audio-worker") + blob(4, frame)
        val tombstone = number(5, 11) + number(6, 22) +
            blob(10, number(1, 6) + text(2, "SIGABRT") + text(4, "SI_TKILL")) +
            text(14, "allocator detected an invalid pointer") +
            blob(16, number(1, 22) + blob(2, thread)) + text(17, "PRIVATE_MEMORY_DUMP")
        val trace = NativeCrashTrace.decode(tombstone)
        assertTrue(trace.contains("SIGABRT (6)"))
        assertTrue(trace.contains("allocator detected an invalid pointer"))
        assertTrue(trace.contains("Thread 22: audio-worker"))
        assertTrue(trace.contains("pc 1234 /data/app/libaudio.so (decoder_abort+8)"))
        assertTrue(trace.contains("BuildId: abcd1234"))
        assertFalse(trace.contains("PRIVATE_MEMORY_DUMP"))
    }

    @Test
    fun keepsCrashDetailsWhenBoundedInputTruncatesALaterMemoryDump() {
        val tombstone = text(14, "original fatal error") + varint((17L shl 3) or 2L) + varint(1000) + byteArrayOf(1)
        assertTrue(NativeCrashTrace.decode(tombstone).contains("original fatal error"))
    }

    @Test
    fun crashedThreadIsShownBeforeOtherThreads() {
        fun thread(id: Long) = blob(16, number(1, id) + blob(2, number(1, id) + text(2, "thread-$id")))
        val trace = NativeCrashTrace.decode(number(6, 99) + thread(10) + thread(99))
        assertTrue(trace.indexOf("Thread 99") < trace.indexOf("Thread 10"))
    }

    private fun text(key: Int, value: String): ByteArray = blob(key, value.toByteArray())
    private fun blob(key: Int, value: ByteArray): ByteArray =
        varint((key.toLong() shl 3) or 2L) + varint(value.size.toLong()) + value
    private fun number(key: Int, value: Long): ByteArray = varint(key.toLong() shl 3) + varint(value)
    private fun varint(value: Long): ByteArray {
        val output = ByteArrayOutputStream()
        var remaining = value
        while (remaining > 127) {
            output.write((remaining.toInt() and 127) or 128)
            remaining = remaining ushr 7
        }
        output.write(remaining.toInt())
        return output.toByteArray()
    }
}
