package com.zuancrisp.mosix

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build

/** OS-owned diagnostics survive fatal native crashes that bypass Dart cleanup. */
internal object LibraryScanExitInfo {
    fun matches(processName: String, timestamp: Long, packageName: String, startedAfter: Long): Boolean =
        startedAfter > 0L && processName == packageName && timestamp >= startedAfter

    fun reasonLabel(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_CRASH -> "App crash"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "Native crash"
        ApplicationExitInfo.REASON_ANR -> "App stopped responding"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "Android stopped the app because memory was low"
        ApplicationExitInfo.REASON_SIGNALED -> "App process terminated by a signal"
        ApplicationExitInfo.REASON_USER_REQUESTED,
        ApplicationExitInfo.REASON_USER_STOPPED -> "App stopped by the user or system"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "Android stopped the app for resource usage"
        else -> "App process stopped (Android reason $reason)"
    }

    fun importanceLabel(importance: Int): String = when (importance) {
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND -> "Foreground activity"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE -> "Foreground service"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "Visible"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_PERCEPTIBLE -> "Perceptible"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "Background service"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_TOP_SLEEPING -> "Top activity while device sleeps"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_CANT_SAVE_STATE -> "Cannot save state"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "Cached background process"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE -> "Process gone"
        else -> "Unknown ($importance)"
    }

    fun read(context: Context, startedAfter: Long): Map<String, Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || startedAfter <= 0L) return null
        val manager = context.getSystemService(ActivityManager::class.java)
        // Android returns newest first. Ignore unrelated package processes and
        // exits older than this scan, rather than blaming an earlier crash.
        val exit = manager.getHistoricalProcessExitReasons(context.packageName, 0, 16)
            .firstOrNull { matches(it.processName, it.timestamp, context.packageName, startedAfter) }
            ?: return null
        return mapOf(
            "reason" to reasonLabel(exit.reason),
            "reason_code" to exit.reason,
            "description" to exit.description.orEmpty().take(2000),
            "timestamp" to exit.timestamp,
            "status" to exit.status,
            "importance_code" to exit.importance,
            "importance_label" to importanceLabel(exit.importance),
            "process_name" to exit.processName,
            "pss_kb" to exit.pss,
            "rss_kb" to exit.rss,
            "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "android" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
        )
    }
}
