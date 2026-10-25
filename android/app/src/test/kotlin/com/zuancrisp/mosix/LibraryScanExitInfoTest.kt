package com.zuancrisp.mosix

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryScanExitInfoTest {
    @Test
    fun distinguishesForegroundUiPlaybackServicesAndCachedProcesses() {
        assertEquals(
            "Foreground activity",
            LibraryScanExitInfo.importanceLabel(ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND),
        )
        assertEquals(
            "Foreground service",
            LibraryScanExitInfo.importanceLabel(ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE),
        )
        assertEquals(
            "Cached background process",
            LibraryScanExitInfo.importanceLabel(ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED),
        )
        assertEquals("Unknown (999)", LibraryScanExitInfo.importanceLabel(999))
    }

    @Test
    fun excludesOldDeathsAndUnrelatedProcesses() {
        assertTrue(LibraryScanExitInfo.matches("example.app", 200L, "example.app", 100L))
        assertFalse(LibraryScanExitInfo.matches("example.app", 99L, "example.app", 100L))
        assertFalse(LibraryScanExitInfo.matches("example.app", 200L, "example.app", 0L))
        assertFalse(LibraryScanExitInfo.matches("example.app:other", 200L, "example.app", 100L))
    }

    @Test
    fun distinguishesNativeCrashesFromLowMemoryAndAnr() {
        assertEquals("Native crash", LibraryScanExitInfo.reasonLabel(ApplicationExitInfo.REASON_CRASH_NATIVE))
        assertEquals("App crash", LibraryScanExitInfo.reasonLabel(ApplicationExitInfo.REASON_CRASH))
        assertEquals("App stopped responding", LibraryScanExitInfo.reasonLabel(ApplicationExitInfo.REASON_ANR))
        assertTrue(LibraryScanExitInfo.reasonLabel(ApplicationExitInfo.REASON_LOW_MEMORY).contains("memory"))
        assertTrue(LibraryScanExitInfo.reasonLabel(999).contains("999"))
    }
}
