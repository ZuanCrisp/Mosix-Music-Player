package com.zuancrisp.mosix

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Exercise shipped libraries rather than the host's unrelated FFmpeg build. */
@RunWith(AndroidJUnit4::class)
class FFmpegCapabilitiesTest {
    private fun execute(vararg arguments: String) {
        val result = NativeDownloadFinalizer.runFFmpegArguments(arrayOf("-v", "error", "-y", *arguments))
        assertTrue(result.second, result.first)
    }

    @Test
    fun audioEncodersAnalysisAndCoverFiltersRemainAvailable() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "ffmpeg-capabilities-${System.nanoTime()}").apply { mkdirs() }
        try {
            for ((extension, encoder) in listOf(
                "flac" to "flac", "m4a" to "alac", "wav" to "pcm_s24le",
                "aiff" to "pcm_s24be", "mp3" to "libmp3lame", "opus" to "libopus", "aac" to "aac",
            )) {
                val output = File(root, "track.$extension")
                execute("-f", "lavfi", "-i", "sine=frequency=997:sample_rate=48000", "-t", "0.5", "-c:a", encoder, output.path)
                execute("-i", output.path, "-map", "0:a:0", "-f", "null", "-")
                assertTrue(output.length() > 0)
            }
            val audio = File(root, "track.flac")
            val stats = File(root, "analysis.txt")
            execute("-i", audio.path, "-af", "astats=metadata=1:reset=0,ebur128=peak=true:metadata=1,ametadata=print:file='${stats.path}'", "-f", "null", "-")
            assertTrue(stats.readText().contains("lavfi.astats"))
            val spectrum = File(root, "spectrum.png")
            execute("-i", audio.path, "-lavfi", "showspectrumpic=s=64x64:legend=0:mode=combined:color=channel:scale=log:fscale=lin:win_func=hann", "-frames:v", "1", spectrum.path)
            val cover = File(root, "cover.jpg")
            execute("-i", spectrum.path, "-vf", "scale=32:32", "-frames:v", "1", cover.path)
            assertTrue(cover.length() > 0)
        } finally { root.deleteRecursively() }
    }

    @Test
    fun motionArtworkDecodingAndRemuxRemainAvailable() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = File(instrumentation.targetContext.cacheDir, "ffmpeg-motion-${System.nanoTime()}").apply { mkdirs() }
        try {
            for (codec in listOf("h264", "hevc")) {
                val input = File(root, "$codec.mp4")
                instrumentation.context.assets.open("motion-probe-$codec.mp4").use { source ->
                    input.outputStream().use { source.copyTo(it) }
                }
                execute("-xerror", "-err_detect", "explode", "-i", input.path, "-map", "0:v:0", "-an", "-sn", "-dn", "-f", "null", "-")
                val output = File(root, "$codec-remux.mp4")
                execute("-i", input.path, "-map", "0:v:0", "-an", "-c:v", "copy", "-movflags", "+faststart", output.path)
                assertTrue(output.length() > 0)
            }
            // Optional live Dart HTTPS/HLS proxy gate, forwarded with adb reverse.
            // The local codec fixtures above remain independent of this server.
            InstrumentationRegistry.getArguments().getString("motionProxyUrl")?.let { source ->
                val output = File(root, "proxy-remux.mp4")
                val input = arrayOf(
                    "-protocol_whitelist", "file,http,https,tcp,tls,crypto",
                    "-rw_timeout", "10000000", "-http_multiple", "0",
                    "-http_persistent", "0", "-extension_picky", "0", "-i", source,
                )
                execute("-xerror", "-err_detect", "explode", *input, "-map", "0:v:0", "-an", "-f", "null", "-")
                execute(*input, "-map", "0:v:0", "-an", "-c:v", "copy", "-movflags", "+faststart", output.path)
                assertTrue(output.length() > 0)
                execute("-xerror", "-err_detect", "explode", "-i", output.path, "-map", "0:v:0", "-an", "-f", "null", "-")
            }
        } finally { root.deleteRecursively() }
    }
}
