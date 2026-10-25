package com.zuancrisp.mosix

import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.LinkedHashMap

/**
 * Creates an install-scoped marker in noBackupFilesDir. A platform restore
 * can bring SharedPreferences back after reinstall, but this marker is never
 * backed up. Package timestamps distinguish that case from the first app
 * update after this marker was introduced, so existing users are not sent
 * through onboarding again.
 */
internal fun MainActivity.ensureInstallMarker(): Map<String, Any> {
    val marker = File(noBackupFilesDir, "installation_state_v1")
    val markerExisted = marker.isFile
    val packageInfo = @Suppress("DEPRECATION")
    packageManager.getPackageInfo(packageName, 0)
    val installTimestampDelta = kotlin.math.abs(
        packageInfo.lastUpdateTime - packageInfo.firstInstallTime
    )
    val looksLikeFreshPackageInstall = installTimestampDelta <= 10_000L

    var markerCreated = markerExisted
    if (!markerExisted) {
        markerCreated = try {
            marker.parentFile?.mkdirs()
            marker.writeText(
                "created_at=${System.currentTimeMillis()}\n" +
                    "version_code=${BuildConfig.VERSION_CODE}\n"
            )
            true
        } catch (e: Exception) {
            android.util.Log.w(
                "Mosix",
                "Failed to create installation marker: ${e.message}"
            )
            false
        }
    }

    return mapOf(
        "marker_existed" to markerExisted,
        "marker_created" to markerCreated,
        "fresh_package_install" to looksLikeFreshPackageInstall,
    )
}

internal fun MainActivity.prepareRuntimeState(extensionDataDir: String): String {
    val pattern = Regex("^[0-9a-f]{32}$")
    fun normalize(value: String?): String? {
        val normalized = value?.trim()?.lowercase().orEmpty()
        return normalized.takeIf(pattern::matches)
    }
    fun ByteArray.hex(): String = buildString(size * 2) {
        for (byte in this@hex) {
            append(((byte.toInt() ushr 4) and 0x0f).toString(16))
            append((byte.toInt() and 0x0f).toString(16))
        }
    }

    val values = LinkedHashMap<String, String>()
    File(extensionDataDir, "signed_sessions")
        .listFiles { file -> file.isFile && file.name.endsWith(".json") }
        ?.forEach { record ->
            try {
                if (record.length() <= 64 * 1024L) {
                    normalize(
                        JSONObject(record.readText()).optString("install_id"),
                    )?.let { values[record.name] = it }
                }
            } catch (_: Exception) {
                // Invalid records are handled by the normal session loader.
            }
        }

    val defaultValue = values.toSortedMap().values.firstOrNull() ?: run {
        val androidID = android.provider.Settings.Secure.getString(
            contentResolver,
            android.provider.Settings.Secure.ANDROID_ID,
        )?.trim().orEmpty()
        val domain = "com.zuancrisp.mosix/runtime/v1:"
        val source = if (androidID.isNotEmpty()) {
            domain + androidID
        } else {
            val fallbackFile = File(noBackupFilesDir, "rs_v1")
            val fallback = try {
                normalize(fallbackFile.takeIf(File::isFile)?.readText())
            } catch (_: Exception) {
                null
            } ?: ByteArray(16).also(SecureRandom()::nextBytes).hex().also { value ->
                try {
                    fallbackFile.parentFile?.mkdirs()
                    fallbackFile.writeText(value)
                } catch (_: Exception) {}
            }
            domain + fallback
        }
        MessageDigest.getInstance("SHA-256")
            .digest(source.toByteArray(Charsets.UTF_8))
            .copyOf(16)
            .hex()
    }
    val entries = JSONObject()
    for ((key, value) in values.toSortedMap()) entries.put(key, value)
    return JSONObject()
        .put("v", 1)
        .put("d", defaultValue)
        .put("s", entries)
        .toString()
}
