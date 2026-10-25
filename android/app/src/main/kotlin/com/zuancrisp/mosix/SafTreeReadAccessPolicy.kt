package com.zuancrisp.mosix

// A provider failure is inconclusive. Only a confirmed missing grant/root
// should hide an indexed library; write permission is irrelevant for reads.
internal fun probeSafTreeReadAccess(
    hasReadPermission: () -> Boolean,
    readRoot: () -> Boolean?,
    onFailure: (Exception) -> Unit = {},
): Boolean? = try {
    if (hasReadPermission()) readRoot() else false
} catch (error: Exception) {
    onFailure(error)
    null
}
