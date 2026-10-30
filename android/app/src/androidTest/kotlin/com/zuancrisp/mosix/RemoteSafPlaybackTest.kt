package com.zuancrisp.mosix

import android.graphics.Bitmap
import android.media.MediaPlayer
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mosix.backend.readFileMetadata
import com.mosix.backend.readLibraryMetadataFromDescriptor
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import xyz.luan.audioplayers.source.UrlSource

/** AppFuse has the same single-open restriction as rclone's SAF provider. */
@RunWith(AndroidJUnit4::class)
class RemoteSafPlaybackTest {
    private fun <T> withProxy(bytes: ByteArray, size: Long = bytes.size.toLong(),
        block: (ParcelFileDescriptor, AtomicLong) -> T): T {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val thread = HandlerThread("remote-document-fixture").apply { start() }
        val reads = AtomicLong()
        val released = CountDownLatch(1)
        val storage = context.getSystemService(StorageManager::class.java)
        try {
            return storage.openProxyFileDescriptor(ParcelFileDescriptor.MODE_READ_ONLY,
                object : ProxyFileDescriptorCallback() {
                    override fun onGetSize() = size
                    override fun onRelease() { released.countDown() }
                    override fun onRead(offset: Long, length: Int, data: ByteArray): Int {
                        val count = minOf(length.toLong(), (size - offset).coerceAtLeast(0)).toInt()
                        data.fill(0, 0, count)
                        if (offset < bytes.size) {
                            val available = minOf(count, bytes.size - offset.toInt())
                            bytes.copyInto(data, 0, offset.toInt(), offset.toInt() + available)
                        }
                        reads.addAndGet(count.toLong())
                        return count
                    }
                }, Handler(thread.looper)).use { block(it, reads) }
        } finally { released.await(2, TimeUnit.SECONDS); thread.quitSafely() }
    }

    @Test fun proxyPlaybackUsesDescriptorWithoutReopeningOrCopying() {
        val dataSize = 44100 * 2
        val wav = ByteBuffer.allocate(44 + dataSize).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(36 + dataSize); put("WAVEfmt ".toByteArray())
            putInt(16); putShort(1); putShort(1); putInt(44100); putInt(88200)
            putShort(2); putShort(16); put("data".toByteArray()); putInt(dataSize)
        }.array()
        withProxy(wav) { fd, _ ->
            val path = "/proc/self/fd/${fd.fd}"
            assertTrue(runCatching { FileInputStream(path).use { it.read() } }.isFailure)
            val prepared = CountDownLatch(1)
            val failed = AtomicLong()
            lateinit var player: MediaPlayer
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            instrumentation.runOnMainSync {
                player = MediaPlayer().apply {
                    setOnPreparedListener { prepared.countDown() }
                    setOnErrorListener { _, _, _ -> failed.incrementAndGet(); prepared.countDown(); true }
                    UrlSource(path, true).setForMediaPlayer(this)
                    prepareAsync()
                }
            }
            try {
                assertTrue("Proxy must prepare without a full file copy", prepared.await(10, TimeUnit.SECONDS))
                assertEquals(0L, failed.get())
                instrumentation.runOnMainSync { assertTrue(player.duration > 0) }
            } finally { instrumentation.runOnMainSync { player.release() } }
        }
    }

    @Test fun proxyMetadataAndCoverReadOnlyTagsAndKeepOriginalLeaseOpen() {
        val image = ByteArrayOutputStream().apply {
            val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, this)
            bitmap.recycle()
        }.toByteArray()
        val picture = ByteArrayOutputStream().apply {
            DataOutputStream(this).apply {
                writeInt(3); writeInt(9); write("image/png".toByteArray()); writeInt(0)
                writeInt(2); writeInt(2); writeInt(32); writeInt(0)
                writeInt(image.size); write(image)
            }
        }.toByteArray()
        val streamInfo = ByteBuffer.allocate(34).apply {
            putShort(4096); putShort(4096); position(10)
            putLong((44100L shl 44) or (1L shl 41) or (15L shl 36) or 44100L)
        }.array()
        val header = ByteArrayOutputStream().apply {
            write("fLaC".toByteArray()); write(byteArrayOf(0, 0, 0, 34)); write(streamInfo)
            write(0x86); write(picture.size shr 16); write(picture.size shr 8); write(picture.size)
            write(picture)
            write(0xff); write(0xf8) // First audio frame's FLAC sync marker.
        }.toByteArray()
        withProxy(header, 64L * 1024 * 1024) { fd, reads ->
            val result = readLibraryMetadataFromDescriptor(fd.fd, "Remote.flac", "", true, null)
            assertTrue(result.coverBytes.isNotEmpty())
            assertEquals(44100, JSONObject(result.metadataJson).getInt("sampleRate"))
            val complete = JSONObject(readFileMetadata("/proc/self/fd/${fd.fd}", "Remote.flac", null))
            assertEquals(16, complete.getInt("bit_depth"))
            assertTrue("Metadata must not transfer 64 MiB of audio", reads.get() < 1024 * 1024)
            assertTrue(fd.fileDescriptor.valid())
        }
    }

    @Test fun proxyCueLibraryScanReadsTagsWithoutTransferringTheAlbum() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "proxy-cue-${System.nanoTime()}").apply { mkdirs() }
        val library = File(root, "library").apply { mkdirs() }
        val backend = createCoreBackend(context)
        try {
            backend.invokeApplication("initExtensionSystem", mapOf(
                "extensions_dir" to File(root, "sources").apply { mkdirs() }.path,
                "data_dir" to File(root, "data").apply { mkdirs() }.path,
                "master_key" to "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                "allowed_directories" to listOf(library.path),
            ))
            val cue = File(library, "album.cue").apply {
                writeText("FILE \"absent.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:01:00\n")
            }
            val streamInfo = ByteBuffer.allocate(34).apply {
                putShort(4096); putShort(4096); position(10)
                putLong((96000L shl 44) or (1L shl 41) or (23L shl 36) or 264000L)
            }.array()
            val header = "fLaC".toByteArray() + byteArrayOf(0x80.toByte(), 0, 0, 34) + streamInfo + byteArrayOf(0xff.toByte(), 0xf8.toByte())
            withProxy(header, 64L * 1024 * 1024) { fd, reads ->
                val prefix = "content://example.documents/document/album.cue"
                val rows = JSONArray(backend.scanCueForLibraryWithResolvedAudio(
                    cue.path, "/proc/self/fd/${fd.fd}", "Remote.flac", prefix, 123L, "proxy-cue-cover",
                ))
                assertEquals(2, rows.length())
                val last = rows.getJSONObject(1)
                assertEquals("$prefix#track02", last.getString("filePath"))
                assertEquals(96000, last.getInt("sampleRate"))
                assertEquals(24, last.getInt("bitDepth"))
                assertEquals(1, last.getInt("duration"))
                assertTrue("CUE metadata must not transfer 64 MiB of audio", reads.get() < 1024 * 1024)
                assertTrue(fd.fileDescriptor.valid())
            }
            assertFalse(File(library, "absent.flac").exists())
        } finally {
            backend.invokeApplication("cleanupExtensions", emptyMap<String, Any>())
            root.deleteRecursively()
        }
    }
}
