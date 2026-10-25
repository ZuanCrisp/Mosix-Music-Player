package com.zuancrisp.mosix

import org.junit.Assert.assertEquals
import org.junit.Test

// Pins the extension and MIME tables used by the SAF and finalizer paths.
// They are not inverse maps: "audio/ogg" names ".opus", while ".ogg" and
// ".opus" both map back to "audio/ogg", and ".aac" has no MIME entry.
class ExtensionMimeTablesTest {
    @Test
    fun extFromFileNameMatchesLowercaseSuffixesOnly() {
        for ((input, expected) in listOf(
            "song.m4a" to ".m4a",
            "song.mp4" to ".mp4",
            "song.aac" to ".aac",
            "song.mp3" to ".mp3",
            "song.opus" to ".opus",
            "song.flac" to ".flac",
            "song.ogg" to ".ogg",
            "song.wave" to ".wav",
            "song.wav" to ".wav",
            "song.aiff" to ".aiff",
            "song.aifc" to ".aifc",
            "song.aif" to ".aif",
            "song.dsf" to ".dsf",
            "song.dff" to ".dff",
            ".flac" to ".flac",
            "my.mp3.flac" to ".flac",
            "song.wv" to "",
            "song.cue" to "",
            "song.lrc" to "",
            "song.flac.tmp" to "",
            "song.flac " to "",
            "SONG.FLAC" to "",
            "song.Mp3" to "",
            "flac" to "",
            "" to "",
            " " to "",
        )) {
            assertEquals(input, expected, extFromFileName(input))
        }
    }

    @Test
    fun extFromMimeTypeMatchesExactTypesOnly() {
        for ((input, expected) in listOf(
            "audio/mp4" to ".m4a",
            "audio/aac" to ".aac",
            "audio/eac3" to ".m4a",
            "audio/ac3" to ".m4a",
            "audio/ac4" to ".m4a",
            "audio/mpeg" to ".mp3",
            "audio/ogg" to ".opus",
            "audio/flac" to ".flac",
            "audio/wav" to ".wav",
            "audio/x-wav" to ".wav",
            "audio/wave" to ".wav",
            "audio/vnd.wave" to ".wav",
            "audio/aiff" to ".aiff",
            "audio/x-aiff" to ".aiff",
            null to "",
            "" to "",
            " " to "",
            "AUDIO/FLAC" to "",
            " audio/flac" to "",
            "audio/x-flac" to "",
            "audio/opus" to "",
            "audio/mp3" to "",
            "application/octet-stream" to "",
        )) {
            assertEquals(input.toString(), expected, extFromMimeType(input))
        }
    }

    @Test
    fun normalizersTrimLowercaseAndAddOneLeadingDot() {
        for ((input, expected) in normalizerCases) {
            assertEquals(input.toString(), expected, SafDownloadHandler.normalizeExt(input))
            assertEquals(input.toString(), expected, NativeFinalizationPolicy.normalizeExtension(input))
        }
    }

    @Test
    fun mimeTypeForExtNormalizesBeforeLookup() {
        val octetStream = "application/octet-stream"
        for ((input, expected) in listOf(
            ".m4a" to "audio/mp4",
            "m4a" to "audio/mp4",
            "M4A" to "audio/mp4",
            ".mp4" to "audio/mp4",
            ".mp3" to "audio/mpeg",
            ".opus" to "audio/ogg",
            ".ogg" to "audio/ogg",
            ".flac" to "audio/flac",
            " FLAC " to "audio/flac",
            ".wav" to "audio/wav",
            ".aiff" to "audio/aiff",
            ".aif" to "audio/aiff",
            ".aifc" to "audio/aiff",
            ".lrc" to octetStream,
            ".aac" to octetStream,
            ".wave" to octetStream,
            ".dsf" to octetStream,
            ".dff" to octetStream,
            ".wv" to octetStream,
            "..flac" to octetStream,
            "audio/flac" to octetStream,
            null to octetStream,
            "" to octetStream,
            "  " to octetStream,
        )) {
            assertEquals(input.toString(), expected, SafDownloadHandler.mimeTypeForExt(input))
        }
    }

    private val normalizerCases = listOf(
        null to "",
        "" to "",
        "   " to "",
        "\t\n" to "",
        "m4a" to ".m4a",
        "mp4" to ".mp4",
        "aac" to ".aac",
        "mp3" to ".mp3",
        "opus" to ".opus",
        "ogg" to ".ogg",
        "flac" to ".flac",
        "wav" to ".wav",
        "aiff" to ".aiff",
        "aif" to ".aif",
        "aifc" to ".aifc",
        "lrc" to ".lrc",
        ".flac" to ".flac",
        "FLAC" to ".flac",
        ".FLAC" to ".flac",
        " .Mp3 " to ".mp3",
        "\tFlac\n" to ".flac",
        "  m4a" to ".m4a",
        "." to ".",
        ".." to "..",
        "..flac" to "..flac",
        "tar.gz" to ".tar.gz",
        "ÉXT" to ".éxt",
    )
}
