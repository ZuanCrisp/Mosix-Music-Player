package com.zuancrisp.mosix

import java.util.Base64
import java.util.Locale

// Keep this persisted key identical to Dart's path_match_keys.dart. A provider
// document ID identifies the file independently of the user's selected tree.
internal fun safDocumentMatchKey(
    scheme: String?,
    authority: String?,
    segments: List<String>,
): String? {
    if (scheme != "content" || authority.isNullOrEmpty()) return null
    val isDirect = segments.size == 2 && segments[0] == "document"
    val isTreeDocument = segments.size == 4 &&
        segments[0] == "tree" && segments[1].isNotEmpty() && segments[2] == "document"
    if ((!isDirect && !isTreeDocument) || segments.last().isEmpty()) return null
    val encodedAuthority = Base64.getUrlEncoder().encodeToString(
        authority.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8),
    )
    return "saf-document:$encodedAuthority:${segments.last()}"
}
