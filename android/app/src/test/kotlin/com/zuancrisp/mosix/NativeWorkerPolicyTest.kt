package com.zuancrisp.mosix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeWorkerPolicyTest {
    @Test
    fun percentOnlyNotificationTotalsDoNotRenderAsBytes() {
        assertTrue(DownloadService.isPercentOnlyNotificationTotal(10_000L))
        assertTrue(DownloadService.isPercentOnlyNotificationTotal(100L))
        assertFalse(DownloadService.isPercentOnlyNotificationTotal(72L * 1024L * 1024L))
        assertFalse(DownloadService.isPercentOnlyNotificationTotal(0L))
    }

    @Test
    fun rateLimitRetriesExactlyOnce() {
        assertTrue(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "rate_limit",
                errorMessage = "Too many requests",
                attempts = 0,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "rate_limit",
                errorMessage = "Too many requests",
                attempts = 1,
            ),
        )
    }

    @Test
    fun rateLimitDetectionFallsBackToMessage() {
        assertTrue(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "network",
                errorMessage = "HTTP 429: retry later",
                attempts = 0,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldRetryRateLimit(
                errorType = "network",
                errorMessage = "Connection reset",
                attempts = 0,
            ),
        )
    }

    @Test
    fun retryDelayUsesServerHintAndSafeBounds() {
        assertEquals(
            45,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = 45,
                errorMessage = null,
            ),
        )
        assertEquals(
            12,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = null,
                errorMessage = "Retry-After seconds: 12",
            ),
        )
        assertEquals(
            5,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = 1,
                errorMessage = null,
            ),
        )
        assertEquals(
            300,
            NativeWorkerPolicy.rateLimitDelaySeconds(
                retryAfterSeconds = 900,
                errorMessage = null,
            ),
        )
    }

    @Test
    fun wifiOnlyPausesWithoutWifi() {
        assertTrue(
            NativeWorkerPolicy.shouldPauseForNetwork(
                downloadNetworkMode = "wifi_only",
                hasWifi = false,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldPauseForNetwork(
                downloadNetworkMode = "wifi_only",
                hasWifi = true,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldPauseForNetwork(
                downloadNetworkMode = "any",
                hasWifi = false,
            ),
        )
    }

    @Test
    fun verificationDetectionUsesTypeAndMessageFallback() {
        for (errorType in listOf(
            "authentication_error", "provider_auth_failed",
            "request_auth_invalid", "provider_reauth_required",
        )) {
            assertFalse(
                NativeWorkerPolicy.isVerificationRequired(
                    errorType = errorType,
                    errorMessage = "Provider unauthorized; verification required upstream",
                ),
            )
        }
        assertTrue(
            NativeWorkerPolicy.isVerificationRequired(
                errorType = "verification_required",
                errorMessage = null,
            ),
        )
        assertTrue(
            NativeWorkerPolicy.isVerificationRequired(
                errorType = "unknown",
                errorMessage = "Challenge required before download",
            ),
        )
        assertFalse(
            NativeWorkerPolicy.isVerificationRequired(
                errorType = "network",
                errorMessage = "Connection reset",
            ),
        )
    }

    @Test
    fun completionAlertSkipsCancelledOrEmptyRuns() {
        assertTrue(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = false,
                completed = 1,
                failed = 0,
            ),
        )
        assertTrue(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = false,
                completed = 0,
                failed = 1,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = true,
                completed = 1,
                failed = 0,
            ),
        )
        assertFalse(
            NativeWorkerPolicy.shouldNotifyQueueComplete(
                cancelRequested = false,
                completed = 0,
                failed = 0,
            ),
        )
    }

    @Test
    fun stoppedWorkerRequeuesOnlyInFlightItems() {
        listOf("preparing", "downloading", "finalizing").forEach { status ->
            assertEquals("queued", NativeWorkerPolicy.statusAfterWorkerStop(status))
        }
        assertEquals("queued", NativeWorkerPolicy.statusAfterWorkerStop("queued"))
        assertEquals("completed", NativeWorkerPolicy.statusAfterWorkerStop("completed"))
        assertEquals("failed", NativeWorkerPolicy.statusAfterWorkerStop("failed"))
        assertEquals("skipped", NativeWorkerPolicy.statusAfterWorkerStop("skipped"))
    }

    @Test
    fun acknowledgedPayloadsAreReleasedOnlyForTerminalItems() {
        listOf("completed", "failed", "skipped").forEach { status ->
            assertTrue(NativeWorkerPolicy.isTerminalStatus(status))
        }
        listOf("queued", "preparing", "downloading", "finalizing").forEach { status ->
            assertFalse(NativeWorkerPolicy.isTerminalStatus(status))
        }
    }
}
