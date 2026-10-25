package com.zuancrisp.mosix

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppCrashReporterTest {
    @Test
    fun onlyRecentUnseenReportsNotifyWithoutDiscardingDiagnostics() {
        val timestamp = 10L * 24 * 60 * 60 * 1000
        val report = JSONObject().put("timestamp", timestamp)
            .put("reason_code", ApplicationExitInfo.REASON_CRASH_NATIVE)
        assertTrue(AppCrashReporter.shouldNotify(report, 0L, 0L, timestamp))
        assertFalse(AppCrashReporter.shouldNotify(report, timestamp, 0L, timestamp))
        assertFalse(AppCrashReporter.shouldNotify(report, 0L, timestamp, timestamp))
        assertFalse(AppCrashReporter.shouldNotify(report, 0L, 0L, timestamp + 8L * 24 * 60 * 60 * 1000))
        assertFalse(AppCrashReporter.shouldNotify(report, 0L, 0L, timestamp - 1))
        assertTrue(AppCrashReporter.shouldShowSavedReport(report))
        // A new crash is not silenced by the acknowledgement of an older one.
        report.put("timestamp", timestamp + 1)
        assertTrue(AppCrashReporter.shouldNotify(report, timestamp, timestamp, timestamp + 1))
    }

    @Test
    fun cachedProcessExitsAreQuietButActiveServicesAndUnknownStatesStillNotify() {
        val report = JSONObject().put("timestamp", 1000L)
            .put("reason_code", ApplicationExitInfo.REASON_ANR)
        for (importance in listOf(
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED,
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE,
        )) {
            report.put("importance_code", importance)
            assertFalse(AppCrashReporter.shouldNotify(report, 0L, 0L, 2000L))
            assertTrue(AppCrashReporter.shouldShowSavedReport(report))
        }
        for (importance in listOf(
            0,
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND,
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE,
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE,
            ActivityManager.RunningAppProcessInfo.IMPORTANCE_TOP_SLEEPING,
        )) {
            report.put("importance_code", importance)
            assertTrue(AppCrashReporter.shouldNotify(report, 0L, 0L, 2000L))
        }
    }

    @Test
    fun aSecondStartupCrashCannotBeOverwrittenByPreviousExitRecovery() {
        assertTrue(AppCrashReporter.shouldKeepSavedReport(2250L, 2000L, 2200L))
        assertFalse(AppCrashReporter.shouldKeepSavedReport(1950L, 2000L, 2200L))
    }

    @Test
    fun includesCrashesAndAnr() {
        for (reason in listOf(
            ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE,
            ApplicationExitInfo.REASON_ANR,
        )) {
            assertTrue(AppCrashReporter.isUnexpectedExit(reason))
        }
    }

    @Test
    fun normalExitsForceStopsAndUpdatesAreNotReportedAsCrashes() {
        for (reason in listOf(
            ApplicationExitInfo.REASON_LOW_MEMORY,
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
            ApplicationExitInfo.REASON_SIGNALED,
            ApplicationExitInfo.REASON_EXIT_SELF,
            ApplicationExitInfo.REASON_USER_REQUESTED,
            ApplicationExitInfo.REASON_USER_STOPPED,
            ApplicationExitInfo.REASON_PACKAGE_UPDATED,
            ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE,
        )) {
            assertFalse(AppCrashReporter.isUnexpectedExit(reason))
        }
    }

    @Test
    fun osKillSignalsAreIgnoredWhileFatalSignalsRemainReported() {
        for (signal in listOf(0, 9, 15)) {
            assertFalse(AppCrashReporter.isUnexpectedExit(ApplicationExitInfo.REASON_SIGNALED, signal))
        }
        for (signal in listOf(4, 5, 6, 7, 8, 11, 31)) {
            assertTrue(AppCrashReporter.isUnexpectedExit(ApplicationExitInfo.REASON_SIGNALED, signal))
        }
    }

    @Test
    fun oldSavedSystemKillsAreHiddenButActualCrashReportsRemainVisible() {
        for (reason in listOf(ApplicationExitInfo.REASON_LOW_MEMORY, ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE)) {
            assertFalse(AppCrashReporter.shouldShowSavedReport(JSONObject().put("reason_code", reason)))
        }
        assertFalse(AppCrashReporter.shouldShowSavedReport(JSONObject()
            .put("reason_code", ApplicationExitInfo.REASON_SIGNALED).put("status", 9)))
        assertTrue(AppCrashReporter.shouldShowSavedReport(JSONObject()
            .put("reason_code", ApplicationExitInfo.REASON_CRASH_NATIVE)))
        assertTrue(AppCrashReporter.shouldShowSavedReport(JSONObject()
            .put("reason", "Unhandled Android exception").put("trace", "java.lang.OutOfMemoryError")))
    }
}
