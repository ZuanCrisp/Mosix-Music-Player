package com.zuancrisp.mosix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundServiceStartPolicyTest {
    @Test
    fun mapsAndroidForegroundStartDenialsToStableCode() {
        val error = IllegalStateException(
            "startForegroundService() not allowed due to mAllowStartForeground false",
        )

        assertTrue(ForegroundServiceStartPolicy.isStartNotAllowed(error))
        assertEquals(
            ForegroundServiceStartPolicy.START_NOT_ALLOWED_CODE,
            ForegroundServiceStartPolicy.errorCode(error),
        )
    }

    @Test
    fun leavesUnrelatedPlatformFailuresGeneric() {
        val error = IllegalStateException("network unavailable")

        assertFalse(ForegroundServiceStartPolicy.isStartNotAllowed(error))
        assertEquals("ERROR", ForegroundServiceStartPolicy.errorCode(error))
    }
}
