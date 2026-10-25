package com.zuancrisp.mosix

import java.util.Locale

/** Match the native library scanner's exclusion of unfinished audio files. */
internal fun isIncompleteSafFileName(name: String): Boolean {
    val lower = name.lowercase(Locale.ROOT)
    return lower.endsWith(".partial") ||
        lower.substringBeforeLast('.', "").endsWith(".partial") ||
        lower.endsWith(".replaced")
}
