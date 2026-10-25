package com.zuancrisp.mosix

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.SecurePreferencesCallback
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SecureStorageMigrationTest {
    private val base = InstrumentationRegistry.getInstrumentation().targetContext
    private val fixtureId = "secure_storage_migration_${System.nanoTime()}"
    private val preferenceNames = mutableSetOf<String>()
    private val context = object : ContextWrapper(base) {
        override fun getApplicationContext(): Context = this
        override fun getPackageName(): String = "${base.packageName}.$fixtureId"
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            val isolatedName = "$fixtureId.$name"
            preferenceNames.add(isolatedName)
            return base.getSharedPreferences(isolatedName, mode)
        }
    }
    private val config = FlutterSecureStorageConfig(mapOf(
        "resetOnError" to "false",
        "migrateOnAlgorithmChange" to "true",
        "migrateWithBackup" to "true",
        "keyCipherAlgorithm" to "RSA_ECB_OAEPwithSHA_256andMGF1Padding",
        "storageCipherAlgorithm" to "AES_GCM_NoPadding",
    ))
    private val values = mapOf(
        "extension_storage_master_key_v2" to Base64.encodeToString(ByteArray(32) { 7 }, Base64.NO_WRAP),
        "example_network_password" to "example-password",
        "example_session_token" to "example-token",
    )

    @After
    fun cleanup() {
        preferenceNames.forEach { base.deleteSharedPreferences(it) }
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        keys.aliases().toList().filter { it.startsWith("${context.packageName}.") }
            .forEach { keys.deleteEntry(it) }
    }

    @Test
    fun migratesUnmarkedLegacyCbcDataWithoutRotatingTheMasterKey() {
        seedLegacy(gcm = false, marked = false)
        assertReadableAfterRestart()
    }

    @Test
    fun migratesLegacyAlgorithmMarkersFromTheDataPreferences() {
        seedLegacy(gcm = false, marked = true)
        assertReadableAfterRestart()
    }

    @Test
    fun migratesPkcs1WrappedGcmDataInsteadOfReportingInvalidKey() {
        seedLegacy(gcm = true, marked = true)
        assertReadableAfterRestart()
    }

    @Test
    fun readsTheLegacyV9GcmWrappedKeyName() {
        seedLegacy(gcm = true, marked = true, legacyGcmKey = true)
        assertReadableAfterRestart()
    }

    @Test
    fun currentCipherDataRemainsReadableAfterReinitialization() {
        val storage = openStorage()
        values.forEach { (key, value) -> callStorage<Void>(storage, "write", storage.addPrefixToKey(key), value) }
        assertReadableAfterRestart()
    }

    @Test
    fun unrecoverableWrappedKeyDoesNotEraseEncryptedValues() {
        seedLegacy(gcm = false, marked = false)
        val data = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE)
        val before = data.all.toMap()
        context.getSharedPreferences("FlutterSecureKeyStorage", Context.MODE_PRIVATE).edit()
            .putString(CBC_KEY, Base64.encodeToString(byteArrayOf(1, 2, 3), Base64.NO_WRAP))
            .commit()
        assertNotNull(initialize(FlutterSecureStorage(context)))
        before.forEach { (key, value) ->
            assertEquals(value, data.getString(key, null))
            assertEquals(value, data.getString("${key}_BACKUP", null))
        }
    }

    private fun assertReadableAfterRestart() {
        repeat(2) {
            val storage = openStorage()
            values.forEach { (key, value) -> assertEquals(value, callStorage<String>(storage, "read", storage.addPrefixToKey(key))) }
        }
    }

    private fun openStorage(): FlutterSecureStorage = FlutterSecureStorage(context).also {
        initialize(it)?.let { error -> throw AssertionError("Secure storage initialization failed", error) }
    }

    private fun initialize(storage: FlutterSecureStorage): Exception? {
        val complete = CountDownLatch(1)
        val failure = AtomicReference<Exception?>()
        storage.initialize(config, object : SecurePreferencesCallback<Void> {
            override fun onSuccess(value: Void?) { complete.countDown() }
            override fun onError(error: Exception) { failure.set(error); complete.countDown() }
        })
        assertTrue("Secure storage callback timed out", complete.await(10, TimeUnit.SECONDS))
        return failure.get()
    }

    // v11 added callbacks to read/write. Exercise either API so the same test
    // can demonstrate the regression before changing the dependency version.
    @Suppress("UNCHECKED_CAST")
    private fun <T> callStorage(storage: FlutterSecureStorage, name: String, vararg args: String): T? {
        val method = storage.javaClass.methods.single { it.name == name }
        if (method.parameterCount == args.size) return method.invoke(storage, *args) as T?
        val complete = CountDownLatch(1)
        val result = AtomicReference<T?>()
        val failure = AtomicReference<Exception?>()
        method.invoke(storage, *args, object : SecurePreferencesCallback<T> {
            override fun onSuccess(value: T?) { result.set(value); complete.countDown() }
            override fun onError(error: Exception) { failure.set(error); complete.countDown() }
        })
        assertTrue("Secure storage operation timed out", complete.await(10, TimeUnit.SECONDS))
        failure.get()?.let { throw it }
        return result.get()
    }

    // Build old ciphertext independently of the plugin so removing its legacy
    // readers makes this regression fail instead of changing the fixture too.
    private fun seedLegacy(gcm: Boolean, marked: Boolean, legacyGcmKey: Boolean = false) {
        val generator = KeyPairGenerator.getInstance("RSA", "AndroidKeyStore")
        generator.initialize(KeyGenParameterSpec.Builder(
            "${context.packageName}.FlutterSecureStoragePluginKey",
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        ).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_PKCS1)
            .setDigests(KeyProperties.DIGEST_SHA256).build())
        val pair = generator.generateKeyPair()
        val aes = KeyGenerator.getInstance("AES").apply { init(128) }.generateKey()
        val wrapper = Cipher.getInstance("RSA/ECB/PKCS1Padding")
        wrapper.init(Cipher.WRAP_MODE, pair.public)
        val keyName = when {
            legacyGcmKey -> "VGhpcyBpcyB0aGUga2V5IGZvcihBIHNlY3XyZZBzdG9yYWdlIEFFUyBLZXkK"
            gcm -> "AES$CBC_KEY"
            else -> CBC_KEY
        }
        context.getSharedPreferences("FlutterSecureKeyStorage", Context.MODE_PRIVATE).edit()
            .putString(keyName, Base64.encodeToString(wrapper.wrap(aes), Base64.DEFAULT)).commit()
        val data = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE).edit()
        values.forEach { (key, value) ->
            val cipher = Cipher.getInstance(if (gcm) "AES/GCM/NoPadding" else "AES/CBC/PKCS7Padding")
            cipher.init(Cipher.ENCRYPT_MODE, aes)
            val encrypted = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            data.putString("${config.sharedPreferencesKeyPrefix}_$key", Base64.encodeToString(encrypted, Base64.DEFAULT))
        }
        if (marked) {
            data.putString("FlutterSecureSAlgorithmKey", "RSA_ECB_PKCS1Padding")
            data.putString("FlutterSecureSAlgorithmStorage", if (gcm) "AES_GCM_NoPadding" else "AES_CBC_PKCS7Padding")
        }
        assertTrue(data.commit())
    }

    companion object {
        private const val CBC_KEY = "VGhpcyBpcyB0aGUga2V5IGZvciBhIHNlY3VyZSBzdG9yYWdlIEFFUyBLZXkK"
    }
}
