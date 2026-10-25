package com.zuancrisp.mosix

import android.content.ContentValues
import com.zuancrisp.mosix.NativeFinalizationPolicy.normalizeAudioCodec
import org.json.JSONObject

internal fun NativeDownloadFinalizer.validateRequestContract(request: JSONObject) {
    val version = request.optInt("contract_version", -1)
    if (version != NATIVE_WORKER_CONTRACT_VERSION) {
        throw IllegalArgumentException(
            "unsupported native worker request contract v$version"
        )
    }

    val required = listOf("item_id", "service", "track_name", "quality", "storage_mode")
    val missing = required.filter { request.optString(it, "").trim().isEmpty() }
    if (missing.isNotEmpty()) {
        throw IllegalArgumentException(
            "native worker request missing fields: ${missing.joinToString()}"
        )
    }
}

internal fun NativeDownloadFinalizer.buildHistoryRow(input: NativeDownloadFinalizer.FinalizeInput, state: NativeDownloadFinalizer.FinalizeState): ContentValues {
    val result = input.result
    val values = ContentValues()
    values.put("id", input.itemId)
    values.put("track_name", result.optString("title", "").ifBlank { trackString(input, "name", input.request.optString("track_name", "")) })
    values.put("artist_name", result.optString("artist", "").ifBlank { trackString(input, "artistName", input.request.optString("artist_name", "")) })
    values.put("album_name", result.optString("album", "").ifBlank { trackString(input, "albumName", input.request.optString("album_name", "")) })
    values.put("album_artist", normalizeOptional(resolvedAlbumArtist(input)))
    values.put("cover_url", normalizeOptional(metadataCoverUrl(input).ifBlank { resultString(input, "cover_url") }))
    values.put("file_path", state.filePath)
    values.put("storage_mode", input.request.optString("storage_mode", "app"))
    values.put("download_tree_uri", normalizeOptional(input.request.optString("saf_tree_uri", "")))
    values.put("saf_relative_dir", normalizeOptional(input.request.optString("saf_relative_dir", "")))
    values.put("saf_file_name", if (state.filePath.startsWith("content://")) state.fileName else null)
    values.put("saf_repaired", 0)
    values.put("service", result.optString("service", "").ifBlank { input.item.optString("service", "") })
    values.put("downloaded_at", java.time.Instant.now().toString())
    values.put("isrc", normalizeOptional(result.optString("isrc", "").ifBlank { trackString(input, "isrc", input.request.optString("isrc", "")) }))
    values.put("spotify_id", normalizeOptional(trackString(input, "id", input.request.optString("spotify_id", ""))))
    values.put("track_number", positiveOrNull(result.optInt("track_number", 0), trackInt(input, "trackNumber", input.request.optInt("track_number", 0))))
    values.put("total_tracks", positiveOrNull(result.optInt("total_tracks", 0), trackInt(input, "totalTracks", input.request.optInt("total_tracks", 0))))
    values.put("disc_number", positiveOrNull(result.optInt("disc_number", 0), trackInt(input, "discNumber", input.request.optInt("disc_number", 0))))
    values.put("total_discs", positiveOrNull(result.optInt("total_discs", 0), trackInt(input, "totalDiscs", input.request.optInt("total_discs", 0))))
    values.put("duration", trackInt(input, "duration", input.request.optInt("duration_ms", 0) / 1000))
    values.put("release_date", normalizeOptional(resultString(input, "release_date").ifBlank { resultString(input, "date").ifBlank { trackString(input, "releaseDate", requestString(input, "release_date")) } }))
    values.put("quality", state.quality)
    state.bitDepth?.let { values.put("bit_depth", it) }
    state.sampleRate?.let { values.put("sample_rate", it) }
    state.bitrateKbps?.takeIf { it >= 16 }?.let {
        values.put("bitrate", it)
    }
    normalizeAudioCodec(state.audioCodec)?.let { values.put("format", it) }
    values.put("genre", normalizeOptional(result.optString("genre", "").ifBlank { input.request.optString("genre", "") }))
    values.put("composer", normalizeOptional(resultString(input, "composer").ifBlank { trackString(input, "composer", requestString(input, "composer")) }))
    values.put("label", normalizeOptional(result.optString("label", "").ifBlank { input.request.optString("label", "") }))
    values.put("copyright", normalizeOptional(result.optString("copyright", "").ifBlank { input.request.optString("copyright", "") }))
    values.put(
        "explicit",
        if (
            result.optBoolean("explicit", false) ||
                input.track.optBoolean("explicit", false) ||
                input.request.optBoolean("explicit", false)
        ) 1 else 0,
    )
    values.put(
        "has_lyrics",
        if (state.hasEmbeddedLyrics || state.externalLrcWritten) 1 else 0,
    )
    values.put(
        "lyrics_metadata_scan_version",
        if (
            state.lyricsMetadataScanned ||
            state.hasEmbeddedLyrics ||
            state.externalLrcWritten
        ) 1 else 0,
    )
    values.put("has_replaygain", if (state.hasReplayGain) 1 else 0)
    values.put("replaygain_metadata_scan_version", if (state.replayGainMetadataScanned) 1 else 0)
    return values
}

internal fun NativeDownloadFinalizer.historyToJson(values: ContentValues): JSONObject {
    val json = JSONObject()
    fun putCamel(column: String, key: String) {
        if (values.containsKey(column)) json.put(key, values.get(column))
    }
    putCamel("id", "id")
    putCamel("track_name", "trackName")
    putCamel("artist_name", "artistName")
    putCamel("album_name", "albumName")
    putCamel("album_artist", "albumArtist")
    putCamel("cover_url", "coverUrl")
    putCamel("file_path", "filePath")
    putCamel("storage_mode", "storageMode")
    putCamel("download_tree_uri", "downloadTreeUri")
    putCamel("saf_relative_dir", "safRelativeDir")
    putCamel("saf_file_name", "safFileName")
    json.put("safRepaired", values.getAsInteger("saf_repaired") == 1)
    putCamel("service", "service")
    putCamel("downloaded_at", "downloadedAt")
    putCamel("isrc", "isrc")
    putCamel("spotify_id", "spotifyId")
    putCamel("track_number", "trackNumber")
    putCamel("total_tracks", "totalTracks")
    putCamel("disc_number", "discNumber")
    putCamel("total_discs", "totalDiscs")
    putCamel("duration", "duration")
    putCamel("release_date", "releaseDate")
    putCamel("quality", "quality")
    putCamel("bit_depth", "bitDepth")
    putCamel("sample_rate", "sampleRate")
    putCamel("bitrate", "bitrate")
    putCamel("format", "format")
    putCamel("genre", "genre")
    putCamel("composer", "composer")
    putCamel("label", "label")
    putCamel("copyright", "copyright")
    json.put("explicit", values.getAsInteger("explicit") == 1)
    json.put("hasLyrics", values.getAsInteger("has_lyrics") == 1)
    json.put("lyricsMetadataScanVersion", values.getAsInteger("lyrics_metadata_scan_version") ?: 0)
    json.put("hasReplayGain", values.getAsInteger("has_replaygain") == 1)
    json.put("replayGainMetadataScanVersion", values.getAsInteger("replaygain_metadata_scan_version") ?: 0)
    return json
}

private fun NativeDownloadFinalizer.normalizeOptional(value: String?): String? {
    val trimmed = cleanMetadataString(value)
    return trimmed.ifBlank { null }
}
