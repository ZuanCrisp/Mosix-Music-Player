package com.zuancrisp.mosix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

class SafMetadataReadPolicyTest {
    @Test fun savingLyricsResolvesTheAudioUriAndKeepsTheOutputFile() {
        val directory = java.nio.file.Files.createTempDirectory("lyrics-save-").toFile()
        try {
            val temporary = File(directory, "input.flac").also { it.writeText("audio") }
            val output = File(directory, "Song.lrc")
            val arguments = mapOf(
                "audio_file_path" to "content://example.documents/song.flac",
                "output_path" to output.absolutePath,
                "track_name" to "Song",
                "artist_name" to "Artist",
            )
            val result = readLyricsRequestWithSafCopy(
                "fetchAndSaveLyrics",
                arguments,
                copyToTemp = { uri ->
                    assertEquals(arguments["audio_file_path"], uri)
                    temporary
                },
                read = { request ->
                    assertEquals(temporary.absolutePath, request["audio_file_path"])
                    assertEquals(output.absolutePath, request["output_path"])
                    assertEquals("Song", request["track_name"])
                    assertEquals("Artist", request["artist_name"])
                    assertTrue(temporary.exists())
                    output.writeText("[00:01.00]Saved lyrics")
                    "saved"
                },
            )
            assertEquals("saved", result)
            assertEquals("[00:01.00]Saved lyrics", output.readText())
            assertFalse(temporary.exists())
            assertEquals("content://example.documents/song.flac", arguments["audio_file_path"])
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test fun revokedSaveInputDoesNotWriteAnOutputOrFetchAnotherSource() {
        assertNull(readLyricsRequestWithSafCopy<String>(
            "fetchAndSaveLyrics",
            mapOf("audio_file_path" to "content://example.documents/revoked.flac"),
            copyToTemp = { null },
            read = { error("Unreadable document must not become a successful save") },
        ))
    }

    @Test fun localAndOnlineSaveRequestsPreserveTheSourceAndOutput() {
        for (path in listOf("/example/song.flac", "")) {
            val request = mapOf("audio_file_path" to path, "output_path" to "/example/Song.lrc")
            assertEquals(request, readLyricsRequestWithSafCopy(
                "fetchAndSaveLyrics",
                request,
                copyToTemp = { error("Unexpected SAF copy") },
                read = { it },
            ))
        }
    }

    @Test fun exhaustedReadsReportTheFailureOnce() {
        val failures = mutableListOf<String?>()
        val result = readSafMetadataWithFallback<String>(
            directRead = { throw java.io.IOException("Invalid audio header") },
            fallbackRead = { null },
            retryDirectOnFailure = true,
            onFailure = { failures.add(it?.message) },
        )
        assertNull(result)
        assertEquals(listOf("Invalid audio header"), failures)
    }

    @Test fun recoveredReadsDoNotReportAScanError() {
        var failures = 0
        val result = readSafMetadataWithFallback(
            directRead = { throw SecurityException("Descriptor unavailable") },
            fallbackRead = { "valid metadata" },
            onFailure = { failures++ },
        )
        assertEquals("valid metadata", result)
        assertEquals(0, failures)
    }

    @Test fun rejectsTemporaryWorkspaceMetadataAndRetriesDescriptorOnce() {
        val guessed = mapOf(
            "metadataFromFilename" to true,
            "albumName" to "native-media-work",
            "trackName" to "Artist",
            "artistName" to "Song",
        )
        val tags = mapOf("trackName" to "Song", "artistName" to "Artist", "albumName" to "Album")
        var reads = 0
        var copies = 0
        val result = readSafMetadataWithFallback(
            directRead = { if (++reads == 1) guessed else tags },
            fallbackRead = { copies++; guessed },
            accept = { it["metadataFromFilename"] != true },
            retryDirectOnFailure = true,
        )
        assertEquals(tags, result)
        assertEquals(2, reads)
        assertEquals(1, copies)
    }

    @Test fun persistentNasReadFailureDoesNotPublishGuessedMetadataOrLoop() {
        var reads = 0
        var copies = 0
        val guessed = mapOf("metadataFromFilename" to true, "albumName" to "native-media-work")
        val result = readSafMetadataWithFallback(
            directRead = { reads++; guessed },
            fallbackRead = { copies++; guessed },
            accept = { it["metadataFromFilename"] != true },
            retryDirectOnFailure = true,
        )
        assertNull(result)
        assertEquals(2, reads)
        assertEquals(1, copies)
    }

    @Test fun retryWaitsAfterTheCopyAndRecoversATransientFailure() {
        val events = mutableListOf<String>()
        var failures = 0
        val result = readSafMetadataWithFallback(
            directRead = {
                events.add("direct")
                if (events.size == 1) throw java.io.IOException("EIO") else "tags"
            },
            fallbackRead = { events.add("copy"); throw java.io.IOException("EIO") },
            retryDirectOnFailure = true,
            onFailure = { failures++ },
            waitBeforeRetry = { events.add("wait") },
        )
        assertEquals("tags", result)
        assertEquals(listOf("direct", "copy", "wait", "direct"), events)
        assertEquals(0, failures)
    }

    @Test fun readsThatSucceedOrDoNotRetryNeverWait() {
        var waits = 0
        assertEquals("tags", readSafMetadataWithFallback(
            directRead = { "tags" },
            fallbackRead = { error("copy") },
            retryDirectOnFailure = true,
            waitBeforeRetry = { waits++ },
        ))
        assertNull(readSafMetadataWithFallback<String>(
            directRead = { null },
            fallbackRead = { null },
            waitBeforeRetry = { waits++ },
        ))
        assertEquals(0, waits)
    }

    @Test fun validCopiedTagsDoNotTriggerAnotherRemoteRead() {
        var reads = 0
        val tags = mapOf<String, Any>("trackName" to "Song", "albumName" to "Album")
        val result = readSafMetadataWithFallback(
            directRead = { reads++; throw java.io.IOException("Provider not ready") },
            fallbackRead = { tags },
            accept = { it["metadataFromFilename"] != true },
            retryDirectOnFailure = true,
        )
        assertEquals(tags, result)
        assertEquals(1, reads)
    }

    @Test fun lyricsReadUsesSafCopyAndDeletesItAfterSuccessOrFailure() {
        for (fails in listOf(false, true)) {
            val temporary = File.createTempFile("lyrics_", ".flac")
            temporary.writeText("embedded lyrics fixture")
            try {
                val result = runCatching {
                    readLyricsWithSafCopy(
                        "content://example.documents/track.flac",
                        copyToTemp = { uri ->
                            assertEquals("content://example.documents/track.flac", uri)
                            temporary
                        },
                        read = { path ->
                            assertEquals(temporary.absolutePath, path)
                            assertEquals("flac", File(path).extension)
                            assertTrue(File(path).exists())
                            if (fails) throw IllegalStateException("read failed")
                            File(path).readText()
                        },
                    )
                }
                assertEquals(fails, result.isFailure)
                if (!fails) assertEquals("embedded lyrics fixture", result.getOrThrow())
                assertFalse(temporary.exists())
            } finally {
                temporary.delete()
            }
        }
    }

    @Test fun revokedSafLyricsReadDoesNotFetchOnline() {
        assertNull(readLyricsWithSafCopy<String>(
            "content://example.documents/revoked.flac",
            copyToTemp = { null },
            read = { error("Unreadable document must not become an online request") },
        ))
    }

    @Test fun localAndOnlineLyricsReadsKeepOriginalPath() {
        for (path in listOf("/example/track.flac", "")) {
            assertEquals(path, readLyricsWithSafCopy(
                path,
                copyToTemp = { error("Unexpected SAF copy") },
                read = { it },
            ))
        }
    }

    @Test fun completeMetadataReadErrorUsesTemporaryCopy() {
        val metadata = mapOf("lyrics" to "words", "comment" to "notes", "track_number" to 3)
        assertEquals(metadata, readSafMetadataWithFallback(
            directRead = { throw Exception("failed to read metadata: permission denied") },
            fallbackRead = { metadata },
        ))
    }

    @Test fun fallbackFailureIsIsolatedToOneFile() {
        assertNull(readSafMetadataWithFallback<String>({ null }, { throw IllegalArgumentException("malformed metadata") }))
        assertEquals("next file", readSafMetadataWithFallback({ "next file" }, { error("copy") }))
    }

    @Test fun seekableReadAvoidsTempCopy() {
        val metadata = mapOf("lyrics" to "words", "replaygain_track_gain" to "-6 dB")
        assertEquals(metadata, readSafMetadataWithFallback({ metadata }, { error("Unexpected copy") }))
    }

    @Test fun pipeAndRevokedUriDoNotDisableNextDescriptor() {
        var directReads = 0
        for (fails in listOf(true, false)) {
            var closed = false
            val value = readSafMetadataWithFallback(
                directRead = {
                    directReads++
                    try {
                        if (fails) throw SecurityException("revoked URI")
                        "descriptor metadata"
                    } finally { closed = true }
                },
                fallbackRead = {
                    assertTrue(closed)
                    "temporary metadata"
                },
            )
            assertEquals(if (fails) "temporary metadata" else "descriptor metadata", value)
        }
        assertEquals(2, directReads)
        assertEquals("pipe fallback", readSafMetadataWithFallback({ null }, { "pipe fallback" }))
        assertEquals("next provider", readSafMetadataWithFallback({ "next provider" }, { error("copy") }))
    }
}
