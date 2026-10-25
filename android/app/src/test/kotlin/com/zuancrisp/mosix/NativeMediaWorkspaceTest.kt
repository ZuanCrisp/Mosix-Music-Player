package com.zuancrisp.mosix

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeMediaWorkspaceTest {
    @Test
    fun clearingCacheDoesNotRemoveInFlightMediaOrBreakTheNextAttempt() {
        val app = Files.createTempDirectory("native-media-test").toFile()
        try {
            val cache = File(app, "cache").also { it.mkdirs() }
            val legacy = File(cache, "rust-core-pilot/files").also { it.mkdirs() }
            val workspace = NativeMediaWorkspace(File(app, "no_backup"))
            val active = workspace.createTemporaryFile("native_saf_work_", ".m4a")
            active.writeText("in-flight audio")

            assertTrue(cache.deleteRecursively())
            try {
                File.createTempFile("native_saf_work_", ".m4a", legacy)
                throw AssertionError("The old cache path should reproduce the missing-directory failure")
            } catch (_: IOException) {
            }

            assertEquals("in-flight audio", active.readText())
            assertTrue(workspace.createTemporaryFile("native_saf_work_", ".m4a").isFile)
        } finally {
            app.deleteRecursively()
        }
    }

    @Test
    fun aNewProcessReclaimsInterruptedWorkWithoutTouchingSavedMusic() {
        val app = Files.createTempDirectory("native-media-test").toFile()
        try {
            val privateDirectory = File(app, "no_backup")
            val interrupted = NativeMediaWorkspace(privateDirectory)
                .createTemporaryFile("native_saf_work_", ".m4a")
            interrupted.writeText("interrupted transfer")
            val savedMusic = File(app, "Music/song.m4a")
            savedMusic.parentFile!!.mkdirs()
            savedMusic.writeText("saved audio")

            val workspace = NativeMediaWorkspace(privateDirectory)

            assertFalse(interrupted.exists())
            assertEquals("saved audio", savedMusic.readText())
            assertTrue(workspace.createTemporaryFile("native_saf_work_", ".m4a").isFile)
        } finally {
            app.deleteRecursively()
        }
    }

    @Test
    fun createsMissingParentsAndReportsAnUnusableWorkspace() {
        val app = Files.createTempDirectory("native-media-test").toFile()
        try {
            val workspace = NativeMediaWorkspace(File(app, "no_backup"))
            assertTrue(workspace.createTemporaryFile("library_scan_", ".ndjson").isFile)

            assertTrue(workspace.directory.deleteRecursively())
            workspace.directory.writeText("not a directory")
            try {
                workspace.createTemporaryFile("library_scan_", ".ndjson")
                throw AssertionError("An unusable workspace must fail before creating a temporary file")
            } catch (error: IOException) {
                assertTrue(error.message.orEmpty().contains("Could not prepare native media workspace"))
            }
        } finally {
            app.deleteRecursively()
        }
    }
}
