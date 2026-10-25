package com.zuancrisp.mosix

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafPublicationPolicyTest {
    @Test
    fun unfinishedNamesStayOutOfFullAndIncrementalScans() {
        for (name in listOf("Track.flac.partial", "Track.partial.flac", "Track.partial.MP3", "Track.flac.replaced")) {
            assertTrue(name, isIncompleteSafFileName(name))
        }
        for (name in listOf("EjAj - Lej Mi Pół.flac", "Track.mp3", "Partial Eclipse.flac", "Track.partial-remix.flac")) {
            assertFalse(name, isIncompleteSafFileName(name))
        }
    }
}
