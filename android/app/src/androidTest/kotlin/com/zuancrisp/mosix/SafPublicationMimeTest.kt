package com.zuancrisp.mosix

import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SafPublicationMimeTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val authority = "com.mosix.test.documents.lookup"
    private val treeUri = DocumentsContract.buildTreeDocumentUri(authority, "root")

    private fun reset(): DocumentFile {
        context.contentResolver.call(Uri.parse("content://$authority.control"), "lookup.reset", null, Bundle().apply {
            putString("targetPackage", context.packageName)
        })
        return requireNotNull(DocumentFile.fromTreeUri(context, treeUri))
    }

    @Test
    fun everyPublicationPathRetainsAudioMimeAndBytesAfterOpaqueRename() {
        val bytes = ByteArray(16384) { (it % 251).toByte() }
        val source = File(context.cacheDir, "publish-mime-${System.nanoTime()}.tmp").apply { writeBytes(bytes) }
        try {
            for ((extension, mime) in listOf("flac" to "audio/flac", "mp3" to "audio/mpeg", "m4a" to "audio/mp4", "opus" to "audio/opus")) {
                for (mode in 0..3) {
                    val parent = reset()
                    val name = "EjAj - Lej Mi Pół.$extension"
                    val uri = requireNotNull(when (mode) {
                        0 -> SafDownloadHandler.writeFileToSaf(context, treeUri.toString(), "", name, mime, source.path)
                        1 -> SafDownloadHandler.writeFileToSafUnique(context, treeUri.toString(), "", name, mime, source.path)?.uri
                        2 -> SafDownloadHandler.writeFileToSafCollisionAware(context, treeUri.toString(), "", name, "Variant.$extension", mime, source.path)?.uri
                        else -> SafDownloadHandler.writeFileToSafIfAbsent(context, treeUri.toString(), "", name, mime, source.path)?.uri
                    })
                    val published = Uri.parse(uri)
                    assertEquals("$extension/$mode", mime, context.contentResolver.getType(published))
                    assertEquals(name, findSafChild(context, parent, name)?.name)
                    assertArrayEquals(bytes, context.contentResolver.openInputStream(published)?.use { it.readBytes() })
                    assertNull(findSafChild(context, parent, "$name.partial"))
                    assertNull(findSafChild(context, parent, name.removeSuffix(".$extension") + ".partial.$extension"))
                    assertNotNull(source.takeIf { it.exists() })
                }
            }
        } finally { source.delete() }
    }
}
