package com.zuancrisp.mosix

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.mosix.backend.CancellationDomain
import com.mosix.backend.CancellationRegistry
import com.mosix.backend.ExtensionManager
import android.os.ParcelFileDescriptor
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ResolvedCueAudioTest {
    @Test
    fun cueLibraryScanUsesBorrowedDescriptorAndPreservesQualityAndLastDuration() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "descriptor-cue-${System.nanoTime()}").apply { mkdirs() }
        try {
            val sources = File(root, "sources").apply { mkdirs() }
            val data = File(root, "data")
            ExtensionManager(sources.path, data.path, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", 2000uL).use { manager ->
                val cue = File(data, "album.cue").apply {
                    writeText("PERFORMER \"Artist\"\nTITLE \"Album\"\nFILE \"absent.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:01:00\n")
                }
                val audio = File(root, "outside-cue-directory.flac")
                val fixture = NativeDownloadFinalizer.runFFmpegArguments(arrayOf(
                    "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=96000",
                    "-t", "2.75", "-c:a", "flac", "-sample_fmt", "s32", audio.path,
                ))
                assertTrue(fixture.second, fixture.first)
                val prefix = "content://example.documents/document/album.cue"
                ParcelFileDescriptor.open(audio, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                    val rows = JSONArray(manager.scanCueFileForLibraryFromDescriptor(
                        cue.path, descriptor.fd, audio.name, prefix, 123L, "cached-cover.jpg", "scan-time", null,
                    ))
                    assertEquals(2, rows.length())
                    val last = rows.getJSONObject(1)
                    assertEquals("$prefix#track02", last.getString("filePath"))
                    assertEquals(96000, last.getInt("sampleRate"))
                    assertEquals(24, last.getInt("bitDepth"))
                    assertEquals(1, last.getInt("duration"))
                    assertEquals("cached-cover.jpg", last.getString("coverPath"))
                    assertTrue(descriptor.statSize > 0)
                }
                assertTrue(!File(data, "absent.flac").exists())
                assertTrue(runCatching { manager.scanCueFileForLibraryFromDescriptor(
                    cue.path, -1, audio.name, prefix, 123L, "", "scan-time", null,
                ) }.isFailure)
            }
        } finally { root.deleteRecursively() }
    }

    @Test
    fun realRustBindingParsesWithoutAudioAndPreservesLegacyValidation() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "resolved-cue-${System.nanoTime()}").apply { mkdirs() }
        try {
            val sources = File(root, "sources").apply { mkdirs() }
            val data = File(root, "data")
            ExtensionManager(sources.path, data.path, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "1", 2000uL).use { manager ->
                val cue = File(data, "album.cue").apply {
                    writeText("PERFORMER \"Artist\"\nTITLE \"Album\"\nFILE \"album.flac\" WAVE\nTRACK 01 AUDIO\nTITLE \"First\"\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nTITLE \"Second\"\nINDEX 01 03:00:00\n")
                }
                val original = cue.readText()
                val audio = File(data, "album.flac").apply { writeText("") }
                val legacy = JSONObject(manager.parseCueFileJson(cue.path, "", null))
                assertTrue(audio.delete())
                val uri = "content://example.documents/tree/root/document/opaque%2F音楽.flac"
                val parsed = JSONObject(manager.parseCueFileJsonWithResolvedAudio(cue.path, uri, null))
                assertEquals(uri, parsed.getString("audio_path"))
                assertEquals(cue.path, parsed.getString("cue_path"))
                assertEquals(legacy.getJSONArray("tracks").toString(), parsed.getJSONArray("tracks").toString())
                assertEquals(-1.0, parsed.getJSONArray("tracks").getJSONObject(1).getDouble("end_sec"), 0.0)
                assertTrue(runCatching { manager.parseCueFileJson(cue.path, "", null) }.isFailure)
                assertTrue(runCatching { manager.parseCueFileJsonWithResolvedAudio(cue.path, "  ", null) }.isFailure)
                CancellationRegistry(CancellationDomain.EXTENSION_REQUEST).use { registry ->
                    registry.acquire("cue-preview").use { lease ->
                        registry.cancel("cue-preview")
                        assertTrue(runCatching { manager.parseCueFileJsonWithResolvedAudio(cue.path, uri, lease) }.isFailure)
                    }
                }
                assertEquals(original, cue.readText())
                assertTrue(!audio.exists())
            }
        } finally {
            root.deleteRecursively()
        }
    }
}
