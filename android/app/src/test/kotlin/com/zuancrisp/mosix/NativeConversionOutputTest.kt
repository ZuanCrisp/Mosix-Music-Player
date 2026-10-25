package com.zuancrisp.mosix

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeConversionOutputTest {
    @Test
    fun sameSuffixOutputKeepsItsNameAndPublishesOnlyWhenComplete() {
        val directory = Files.createTempDirectory("native-conversion-output-").toFile()
        try {
            for (name in listOf("Song.flac", "Song.m4a", "Song.mp4", "Song_converted.flac")) {
                val input = File(directory, name).apply { writeText("source") }
                val output = NativeDownloadFinalizer.buildOutputPath(input.path, input.extension)
                assertEquals(input.absolutePath, output)
                val staged = File(NativeDownloadFinalizer.stagedConversionPath(output))
                staged.writeText("complete")
                assertEquals("source", input.readText())
                assertTrue(NativeDownloadFinalizer.promoteStagedConversion(staged.path, output))
                assertEquals("complete", input.readText())
                assertFalse(staged.exists())
                input.delete()
                assertEquals(0, directory.listFiles()!!.size)
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun emptyOrMissingStageCannotReplaceTheSource() {
        val directory = Files.createTempDirectory("native-conversion-output-").toFile()
        try {
            val input = File(directory, "Song.flac").apply { writeText("source") }
            val staged = File(NativeDownloadFinalizer.stagedConversionPath(input.path))
            assertFalse(NativeDownloadFinalizer.promoteStagedConversion(staged.path, input.path))
            staged.createNewFile()
            assertFalse(NativeDownloadFinalizer.promoteStagedConversion(staged.path, input.path))
            assertEquals("source", input.readText())
        } finally {
            directory.deleteRecursively()
        }
    }
}
