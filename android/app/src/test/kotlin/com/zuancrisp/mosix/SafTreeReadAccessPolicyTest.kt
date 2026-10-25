package com.zuancrisp.mosix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SafTreeReadAccessPolicyTest {
    @Test fun readableLibraryDoesNotRequireWritePermission() {
        assertTrue(probeSafTreeReadAccess({ true }, { true }) == true)
    }

    @Test fun missingGrantDoesNotQueryTheProvider() {
        assertFalse(probeSafTreeReadAccess({ false }, { error("No permission") })!!)
    }

    @Test fun confirmedMissingRootIsOffline() {
        assertEquals(false, probeSafTreeReadAccess({ true }, { false }))
    }

    @Test fun nullCursorOrLoadingRootIsInconclusive() {
        assertNull(probeSafTreeReadAccess({ true }, { null }))
    }

    @Test fun providerFailureDuringDownloadDoesNotHideReadableLibrary() {
        var readable = true
        for (busy in listOf(false, true, false)) {
            val result = probeSafTreeReadAccess(
                { true },
                {
                    if (busy) throw IllegalStateException("Provider is busy")
                    true
                },
            )
            readable = result ?: readable
            assertTrue(readable)
        }
    }

    @Test fun grantQueryFailureIsInconclusive() {
        assertNull(probeSafTreeReadAccess(
            { throw SecurityException("Provider unavailable") },
            { error("Unexpected root query") },
        ))
    }
}
