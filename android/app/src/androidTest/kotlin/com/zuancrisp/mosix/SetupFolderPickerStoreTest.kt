package com.zuancrisp.mosix

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SetupFolderPickerStoreTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val name = "setup_folder_picker_test_${System.nanoTime()}"
    private fun store() = SetupFolderPickerStore(
        context.getSharedPreferences(name, Context.MODE_PRIVATE),
    )

    @After
    fun cleanup() {
        context.deleteSharedPreferences(name)
    }

    @Test
    fun resultSurvivesStoreRecreationUntilAcknowledged() {
        val payload = "{\"tree_uri\":\"content://test/tree/music\"}"
        store().begin(true)
        assertTrue(store().complete(payload))
        assertEquals(payload, store().read())
        store().acknowledge("stale result")
        assertEquals(payload, store().read())
        store().acknowledge(payload)
        assertNull(store().read())
    }

    @Test
    fun cancellationIsRetainedSoRestoredSetupCanStopWaiting() {
        store().begin(true)
        assertTrue(store().complete(null))
        assertEquals("{}", store().read())
        store().acknowledge("{}")
        assertNull(store().read())
    }

    @Test
    fun otherFolderPickersDoNotChangeSetup() {
        store().begin(false)
        assertFalse(store().complete("{\"tree_uri\":\"other\"}"))
        assertNull(store().read())
    }
}
