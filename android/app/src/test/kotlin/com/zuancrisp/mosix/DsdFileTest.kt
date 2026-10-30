package com.zuancrisp.mosix

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class DsdFileTest {
    private fun dsf(): ByteArray {
        val buffer = ByteBuffer.allocate(28 + 52 + 12 + 16).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("DSD ".toByteArray()).putLong(28).putLong(buffer.capacity().toLong()).putLong(0)
        buffer.put("fmt ".toByteArray()).putLong(52).putInt(1).putInt(0).putInt(2)
            .putInt(2).putInt(2822400).putInt(1).putLong(48).putInt(4).putInt(0)
        buffer.put("data".toByteArray()).putLong(28)
        // Two DSF channel blocks per group, with padding in the final group.
        buffer.put(byteArrayOf(1, 2, 4, 8, 16, 32, 64, -128, 3, 5, 0, 0, 6, 10, 0, 0))
        return buffer.array()
    }

    private fun chunk(name: String, data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        DataOutputStream(out).use {
            it.writeBytes(name)
            it.writeLong(data.size.toLong())
            it.write(data)
            if (data.size % 2 == 1) it.writeByte(0)
        }
        return out.toByteArray()
    }

    private fun dff(compression: String = "DSD "): ByteArray {
        val rate = ByteBuffer.allocate(4).putInt(2822400).array()
        val property = "SND ".toByteArray() + chunk("FS  ", rate) +
            chunk("CHNL", byteArrayOf(0, 2) + "SLFTSRGT".toByteArray()) + chunk("CMPR", compression.toByteArray())
        val data = byteArrayOf(1, 11, 2, 12, 3, 13, 4, 14, 5, 15, 6, 16)
        return chunk("FRM8", "DSD ".toByteArray() + chunk("PROP", property) + chunk("DSD ", data))
    }

    private fun <T> withFile(data: ByteArray, run: (String) -> T): T {
        val file = File.createTempFile("mosix-dsd-", ".audio")
        try { file.writeBytes(data); return run(file.absolutePath) } finally { file.delete() }
    }

    @Test fun dsfNormalizesLsbBitsAndDoesNotReadChannelPadding() = withFile(dsf()) { path ->
        DsdFile.open(path)!!.use {
            assertEquals(2822400, it.rate)
            assertEquals(2, it.channels)
            assertArrayEquals(byteArrayOf(64, -128, 5, 4, 8, 5), it.readFrames("dop", 3, 1))
            assertArrayEquals(byteArrayOf(16, 32, 5, 1, 2, 5), it.readFrames("dop", 3, 1))
            assertArrayEquals(byteArrayOf(-96, -64, 5, 80, 96, 5), it.readFrames("dop", 3, 1))
            assertNull(it.readFrames("dop", 3))
        }
    }

    @Test fun nativeDsdOrderAndSeekRemainChannelAligned() = withFile(dff()) { path ->
        DsdFile.open(path)!!.use {
            assertArrayEquals(byteArrayOf(1, 2, 3, 4, 11, 12, 13, 14), it.readFrames("dsd_be", 4, 1))
            it.seek(0, "dsd_le")
            assertArrayEquals(byteArrayOf(4, 3, 2, 1, 14, 13, 12, 11), it.readFrames("dsd_le", 4, 1))
            assertArrayEquals(byteArrayOf(0x69, 0x69, 6, 5, 0x69, 0x69, 16, 15), it.readFrames("dsd_le", 4, 1))
            assertNull(it.readFrames("dsd_le", 4))
        }
    }

    @Test fun dopUsesLeftJustified24BitWordsIn32BitSlots() = withFile(dff()) { path ->
        DsdFile.open(path)!!.use {
            assertArrayEquals(byteArrayOf(0, 2, 1, 5, 0, 12, 11, 5), it.readFrames("dop", 4, 1))
        }
    }

    @Test fun rejectsDstAndTruncatedOrOversizedChunks() {
        for (data in listOf(dff("DST "), dsf().copyOf(99), dff().apply { for (i in 4..11) this[i] = 127 })) {
            withFile(data) { path ->
                assertThrows(Exception::class.java) { DsdFile.open(path) }
            }
        }
    }

    @Test fun nonDsdFilesFallBackWithoutUsingTheExtension() = withFile("fLaC1234".toByteArray()) { path ->
        assertNull(DsdFile.open(path))
    }
}
