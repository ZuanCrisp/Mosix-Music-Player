package com.zuancrisp.mosix

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import androidx.activity.result.ActivityResult
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

internal fun MainActivity.launchSafTreePicker(call: MethodCall, result: MethodChannel.Result) {
    if (MainActivity.pendingSafTreeResult != null) {
        result.error("saf_pending", "SAF picker already active", null)
        return
    }
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
    intent.addFlags(
        Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
            Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
    )
    val resolver = intent.resolveActivity(packageManager)
    if (resolver == null) {
        result.error("saf_unavailable", "No folder picker available on this device", null)
        return
    }
    setupFolderPickerStore.begin(call.argument<Boolean>("for_setup") == true)
    MainActivity.pendingSafTreeResult = result
    try {
        android.util.Log.i("Mosix", "Launching SAF picker via $resolver")
        safTreeLauncher.launch(intent)
    } catch (e: Exception) {
        MainActivity.pendingSafTreeResult = null
        setupFolderPickerStore.complete(null)
        android.util.Log.e("Mosix", "Failed to launch SAF picker: ${e.message}", e)
        result.error(
            "saf_launch_failed",
            e.message ?: "Failed to launch folder picker",
            null
        )
    }
}

internal fun MainActivity.handleSafTreeResult(activityResult: ActivityResult) {
    val result = MainActivity.pendingSafTreeResult
    MainActivity.pendingSafTreeResult = null

    fun deliver(payload: String?) {
        // Android can return to a new process with no Dart method reply.
        // Persist the grant/result anyway, then notify the restored setup.
        try {
            if (setupFolderPickerStore.complete(payload)) {
                backendChannel?.invokeMethod("setupFolderSelectionChanged", null)
            }
        } catch (e: Exception) {
            android.util.Log.e("Mosix", "Could not retain setup folder selection", e)
            result?.error("saf_save_failed", "Could not save selected folder", null)
            return
        }
        result?.success(payload)
    }

    if (activityResult.resultCode != Activity.RESULT_OK) {
        deliver(null)
        return
    }

    val data = activityResult.data
    val uri = data?.data
    if (uri == null) {
        deliver(null)
        return
    }

    val takeFlags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    try {
        contentResolver.takePersistableUriPermission(uri, takeFlags)
    } catch (e: Exception) {
        android.util.Log.w("Mosix", "Failed to persist SAF permission: ${e.message}")
    }

    val payload = JSONObject()
    payload.put("tree_uri", uri.toString())
    payload.put("display_name", resolveSafDisplayPath(uri))
    val storageId = resolveSafStorageId(uri)
    val volume = getSystemService(StorageManager::class.java).storageVolumes.firstOrNull {
        (storageId == "primary" && it.isPrimary) ||
            (!it.uuid.isNullOrBlank() && it.uuid.equals(storageId, ignoreCase = true))
    }
    payload.put("volume_id", storageId ?: JSONObject.NULL)
    payload.put(
        "is_removable",
        volume?.isRemovable ?: (storageId != null && storageId != "primary"),
    )
    deliver(payload.toString())
}

private fun resolveSafStorageId(treeUri: Uri): String? {
    return try {
        DocumentsContract.getTreeDocumentId(treeUri)
            ?.substringBefore(':')
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    } catch (_: Exception) {
        null
    }
}

/**
 * Resolve a SAF tree URI to a human-readable path.
 * e.g. "content://...tree/primary%3AMusic" -> "/storage/emulated/0/Music"
 *      "content://...tree/1234-5678%3AMusic" -> "SD Card/Music"
 */
private fun MainActivity.resolveSafDisplayPath(treeUri: Uri): String {
    try {
        val docId = android.provider.DocumentsContract.getTreeDocumentId(treeUri)
        if (docId.isNullOrEmpty()) return treeUri.toString()

        val parts = docId.split(":", limit = 2)
        val storageId = parts.getOrNull(0) ?: return docId
        val subPath = parts.getOrNull(1) ?: ""

        val prefix = if (storageId == "primary") {
            "/storage/emulated/0"
        } else {
            val volumeName = getSystemService(StorageManager::class.java).storageVolumes
                .firstOrNull { it.uuid.equals(storageId, ignoreCase = true) }
                ?.getDescription(this)
            volumeName?.takeIf { it.isNotBlank() } ?: "External storage"
        }

        return if (subPath.isEmpty()) prefix else "$prefix/$subPath"
    } catch (e: Exception) {
        android.util.Log.w("Mosix", "Failed to resolve SAF display path: ${e.message}")
        return treeUri.toString()
    }
}
