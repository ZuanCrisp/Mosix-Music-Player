package com.zuancrisp.mosix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SafDocumentIdentityTest {
    private val authority = "org.example.documents"
    private val documentId = "account:Music/Album/01 Song.flac"

    @Test
    fun treeAndDirectUrisUseTheSamePersistedKey() {
        val expected = "saf-document:b3JnLmV4YW1wbGUuZG9jdW1lbnRz:$documentId"
        for (segments in listOf(
            listOf("tree", "account:Music", "document", documentId),
            listOf("tree", "account:Music/Album", "document", documentId),
            listOf("document", documentId),
        )) {
            assertEquals(expected, safDocumentMatchKey("content", authority, segments))
        }
    }

    @Test
    fun decodedDocumentIdsKeepCaseUnicodeAndLiteralPercentEscapes() {
        for (id in listOf("Opaque-A", "account:Music/夜/100%20 Real.flac")) {
            val key = safDocumentMatchKey("content", authority, listOf("document", id))
            assertEquals("saf-document:b3JnLmV4YW1wbGUuZG9jdW1lbnRz:$id", key)
            assertNotEquals(key, safDocumentMatchKey("content", "org.other.documents", listOf("document", id)))
        }
        assertNotEquals(
            safDocumentMatchKey("content", authority, listOf("document", "Opaque-A")),
            safDocumentMatchKey("content", authority, listOf("document", "opaque-a")),
        )
    }

    @Test
    fun malformedOrNonDocumentUrisDoNotGainAnIdentity() {
        for (segments in listOf(
            emptyList(),
            listOf("tree", "account:Music"),
            listOf("document", ""),
            listOf("tree", "", "document", documentId),
            listOf("album", "one", "document", documentId),
        )) {
            assertNull(safDocumentMatchKey("content", authority, segments))
        }
        assertNull(safDocumentMatchKey("https", authority, listOf("document", documentId)))
        assertNull(safDocumentMatchKey("content", null, listOf("document", documentId)))
    }
}
