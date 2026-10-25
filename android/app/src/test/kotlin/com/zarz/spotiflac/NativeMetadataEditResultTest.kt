package com.zuancrisp.mosix

import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeMetadataEditResultTest {
    @Test
    fun successfulNativeEditAndExplicitFfmpegFallbackRemainDistinct() {
        for (method in listOf("native", "native_mp3", "native_ogg", "native_m4a")) {
            assertTrue(nativeMetadataEditHandled("{\"success\":true,\"method\":\"$method\"}"))
        }
        assertFalse(nativeMetadataEditHandled("{\"success\":true,\"method\":\"ffmpeg\"}"))
    }

    @Test
    fun unsuccessfulMissingOrContradictoryResultsCannotSkipEmbedding() {
        for (response in listOf(
            "{}",
            "{\"method\":\"native\"}",
            "{\"success\":false,\"method\":\"native\"}",
            "{\"success\":true}",
            "{\"success\":\"true\",\"method\":\"native\"}",
            "{\"success\":true,\"method\":\"native\",\"error\":\"write failed\"}",
        )) {
            assertThrows(IllegalStateException::class.java) { nativeMetadataEditHandled(response) }
        }
        assertThrows(org.json.JSONException::class.java) { nativeMetadataEditHandled("malformed") }
    }
}
