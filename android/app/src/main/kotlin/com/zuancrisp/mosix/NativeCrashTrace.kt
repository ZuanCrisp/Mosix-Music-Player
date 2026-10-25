package com.zuancrisp.mosix

/** Reads only diagnostic fields from Android's tombstone protobuf, never memory dumps.
 * Schema: https://android.googlesource.com/platform/system/core/+/refs/heads/main/debuggerd/proto/tombstone.proto
 */
internal object NativeCrashTrace {
    fun decode(bytes: ByteArray): String {
        val tombstone = fields(bytes, setOf(5, 6, 10, 14, 15, 16))
        return buildString {
            appendLine("Android native crash (tombstone)")
            appendLine("pid: ${tombstone.number(5)}, crashed tid: ${tombstone.number(6)}")
            tombstone.blobs(10).firstOrNull()?.let {
                val signal = fields(it, setOf(1, 2, 3, 4, 8, 9))
                appendLine("Signal: ${signal.string(2)} (${signal.number(1)}), code: ${signal.string(4)} (${signal.number(3)})")
                if (signal.number(8) != 0L) {
                    appendLine("Fault address: 0x${signal.number(9).toULong().toString(16)}")
                }
            }
            tombstone.string(14).takeIf { it.isNotEmpty() }?.let { appendLine("Abort message: $it") }
            for (cause in tombstone.blobs(15)) {
                appendLine("Cause: ${fields(cause, setOf(1)).string(1)}")
            }
            val threads = tombstone.blobs(16).map { fields(it, setOf(1, 2)) }
                .sortedBy { if (it.number(1) == tombstone.number(6)) 0 else 1 }
            for (entry in threads.take(20)) {
                val thread = fields(entry.blobs(2).firstOrNull() ?: continue, setOf(1, 2, 4, 7))
                appendLine("\nThread ${thread.number(1)}: ${thread.string(2)}")
                for (note in thread.blobs(7)) appendLine(note.toString(Charsets.UTF_8))
                for ((index, frameBytes) in thread.blobs(4).take(64).withIndex()) {
                    val frame = fields(frameBytes, setOf(1, 4, 5, 6, 8))
                    appendLine("#$index pc ${frame.number(1).toULong().toString(16)} ${frame.string(6)} (${frame.string(4)}+${frame.number(5)}) (BuildId: ${frame.string(8)})")
                }
            }
            if (threads.isEmpty()) appendLine("Android did not provide thread backtraces in this trace.")
        }.take(128 * 1024)
    }

    private class Fields(val values: Map<Int, List<Any>>) {
        fun number(key: Int): Long = values[key]?.firstOrNull() as? Long ?: 0L
        fun blobs(key: Int): List<ByteArray> = values[key].orEmpty().filterIsInstance<ByteArray>()
        fun string(key: Int): String = blobs(key).firstOrNull()?.toString(Charsets.UTF_8).orEmpty()
    }

    private fun fields(bytes: ByteArray, wanted: Set<Int>): Fields {
        val values = mutableMapOf<Int, MutableList<Any>>()
        var offset = 0
        fun varint(): Long {
            var value = 0L
            for (shift in 0..63 step 7) {
                require(offset < bytes.size) { "Truncated tombstone" }
                val byte = bytes[offset++].toInt() and 255
                value = value or ((byte and 127).toLong() shl shift)
                if (byte and 128 == 0) return value
            }
            error("Invalid tombstone varint")
        }
        while (offset < bytes.size) {
            try {
                val tag = varint()
                val key = (tag ushr 3).toInt()
                require(key > 0) { "Invalid tombstone field" }
                var value: Any? = null
                when ((tag and 7).toInt()) {
                    0 -> value = varint()
                    1 -> offset += 8
                    2 -> {
                        val length = varint()
                        require(length >= 0 && length <= bytes.size - offset) { "Truncated tombstone field" }
                        if (key in wanted) value = bytes.copyOfRange(offset, offset + length.toInt())
                        offset += length.toInt()
                    }
                    5 -> offset += 4
                    else -> error("Unsupported tombstone wire type")
                }
                require(offset <= bytes.size) { "Truncated tombstone field" }
                if (key in wanted && value != null) values.getOrPut(key) { mutableListOf() }.add(value)
            } catch (_: IllegalArgumentException) {
                // A bounded read can end midway through an unrelated memory
                // dump. Keep complete diagnostic fields preceding that dump.
                break
            }
        }
        return Fields(values)
    }
}
