package com.zuancrisp.mosix

import android.content.Context
import com.zuancrisp.mosix.SafDownloadHandler.mimeTypeForExt
import org.json.JSONObject
import java.io.File

internal fun NativeDownloadFinalizer.runPostProcessing(
    context: Context,
    input: NativeDownloadFinalizer.FinalizeInput,
    state: NativeDownloadFinalizer.FinalizeState,
    shouldCancel: () -> Boolean,
) {
    if (!input.request.optBoolean("post_processing_enabled", false)) return
    val metadata = JSONObject()
        .put("title", trackString(input, "name", input.request.optString("track_name", "")))
        .put("artist", trackString(input, "artistName", input.request.optString("artist_name", "")))
        .put("album", trackString(input, "albumName", input.request.optString("album_name", "")))
        .put("album_artist", resolvedAlbumArtist(input))
        .put("track_number", trackInt(input, "trackNumber", input.request.optInt("track_number", 0)))
        .put("disc_number", trackInt(input, "discNumber", input.request.optInt("disc_number", 0)))
        .put("isrc", trackString(input, "isrc", input.request.optString("isrc", "")))
        .put("release_date", trackString(input, "releaseDate", input.request.optString("release_date", "")))
        .put("duration_ms", trackInt(input, "duration", 0) * 1000)
        .put("cover_url", metadataCoverUrl(input))

    if (state.filePath.startsWith("content://")) {
        val uri = state.filePath
        val tempInput = SafDownloadHandler.copyContentUriToTemp(context, uri)
            ?: throw IllegalStateException("failed to copy SAF file for post-processing")
        try {
            val inputObj = JSONObject()
                .put("item_id", input.itemId)
                .put("path", tempInput)
                .put("uri", uri)
                .put("name", state.fileName)
                .put("mime_type", mimeTypeForExt(state.fileName.substringAfterLast('.', "")))
                .put("size", File(tempInput).length())
                .put("is_saf", true)
            checkCancelled(shouldCancel)
            val response = JSONObject(createCoreBackend(context).runPostProcessing(inputObj.toString(), metadata.toString()))
            checkCancelled(shouldCancel)
            if (!response.optBoolean("success", false)) return
            val newPath = response.optString("new_file_path", "")
            val outputPath = newPath.ifBlank { tempInput }
            val outputFile = File(outputPath)
            if (!outputFile.exists()) return
            val outputName = if (newPath.isBlank()) state.fileName else outputFile.name
            val newUri = SafDownloadHandler.writeFileToSaf(
                context = context,
                treeUriStr = input.request.optString("saf_tree_uri", ""),
                relativeDir = input.request.optString("saf_relative_dir", ""),
                fileName = outputName,
                mimeType = mimeTypeForExt(outputFile.extension),
                srcPath = outputFile.absolutePath,
            ) ?: return
            if (newUri != uri) SafDownloadHandler.deleteContentUri(context, uri)
            state.filePath = newUri
            state.fileName = outputName
            if (outputPath != tempInput) outputFile.delete()
        } finally {
            File(tempInput).delete()
        }
        return
    }

    val inputObj = JSONObject()
        .put("item_id", input.itemId)
        .put("path", state.filePath)
        .put("name", state.fileName)
        .put("is_saf", false)
    checkCancelled(shouldCancel)
    val response = JSONObject(createCoreBackend(context).runPostProcessing(inputObj.toString(), metadata.toString()))
    checkCancelled(shouldCancel)
    if (response.optBoolean("success", false)) {
        val newPath = response.optString("new_file_path", "")
        if (newPath.isNotBlank() && newPath != state.filePath) {
            if (isDeferredSafPublish(input)) {
                val output = File(newPath)
                check(output.isFile && output.length() > 0L) {
                    "post-processing output missing or empty"
                }
                // This input is an owned staging file; publication later
                // removes the replacement, so retire the old stage now.
                File(state.filePath).delete()
            }
            state.filePath = newPath
            state.fileName = File(newPath).name
        }
    }
}
