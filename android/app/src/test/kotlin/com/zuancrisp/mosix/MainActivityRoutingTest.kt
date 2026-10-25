package com.zuancrisp.mosix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * MainActivity routes a backend call to its own `when` only when the method
 * name is in `nativeBackendMethods`; every other name goes to the selected
 * core backend. A name added to only one of the two silently changes where a
 * call is handled, so this test keeps them in step by reading the source.
 */
class MainActivityRoutingTest {
    @Test
    fun nativeBackendMethodsMatchDispatchCases() {
        val source = mainActivitySource()
        val routed = nativeBackendMethodNames(source)
        val cases = dispatchCaseLabels(source)

        assertTrue("nativeBackendMethods is empty", routed.isNotEmpty())
        assertTrue("backend dispatch has no case labels", cases.isNotEmpty())
        val duplicates = cases.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        assertTrue("duplicate dispatch cases: $duplicates", duplicates.isEmpty())

        val caseSet = cases.toSet()
        val onlyInSet = routed - caseSet
        val onlyInCases = caseSet - routed
        if (onlyInSet.isNotEmpty() || onlyInCases.isNotEmpty()) {
            fail(
                "nativeBackendMethods and dispatch cases differ. " +
                    "Only in nativeBackendMethods: ${onlyInSet.sorted()}. " +
                    "Only in dispatch cases: ${onlyInCases.sorted()}.",
            )
        }
        assertEquals(routed, caseSet)
    }

    private fun mainActivitySource(): String {
        val relative = "src/main/kotlin/com/zuancrisp/mosix/MainActivity.kt"
        val candidates = listOf(
            File(relative),
            File("app/$relative"),
            File("android/app/$relative"),
        )
        val file = candidates.firstOrNull { it.isFile }
            ?: throw AssertionError(
                "MainActivity.kt not found from ${File("").absolutePath}",
            )
        return file.readText(Charsets.UTF_8)
    }

    private fun nativeBackendMethodNames(source: String): Set<String> {
        val declaration = Regex("""\bnativeBackendMethods\s*=\s*setOf\(""")
        val matches = declaration.findAll(source).toList()
        assertEquals("nativeBackendMethods declarations", 1, matches.size)
        val start = matches.single().range.last + 1
        val end = source.indexOf(')', start)
        assertTrue("unterminated nativeBackendMethods set", end > start)
        val names = Regex(""""([^"\\]*)"""")
            .findAll(source.substring(start, end))
            .map { it.groupValues[1] }
            .toList()
        val duplicates = names.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        assertTrue("duplicate nativeBackendMethods names: $duplicates", duplicates.isEmpty())
        return names.toSet()
    }

    /**
     * Returns the string labels of the top-level branches of the backend
     * `when (call.method)`. Branches of nested `when` blocks inside a case
     * body are deeper than one brace level and are ignored.
     */
    private fun dispatchCaseLabels(source: String): List<String> {
        val anchor = "when (call.method) {"
        val start = source.indexOf(anchor)
        assertTrue("backend dispatch `$anchor` not found", start >= 0)
        assertEquals(
            "backend dispatch `$anchor` must appear once",
            -1,
            source.indexOf(anchor, start + 1),
        )

        val label = Regex(""""([^"\\]*)"(\s*,\s*"([^"\\]*)")*\s*->""").toPattern().matcher(source)
        val literal = Regex(""""([^"\\]*)"""")
        val labels = mutableListOf<String>()
        var depth = 1
        var atLineStart = false
        var i = start + anchor.length
        while (i < source.length) {
            val c = source[i]
            if (c == '\n') {
                atLineStart = true
                i++
                continue
            }
            if (c == ' ' || c == '\t' || c == '\r') {
                i++
                continue
            }
            if (atLineStart && depth == 1 && c == '"') {
                if (label.region(i, source.length).lookingAt()) {
                    labels += literal.findAll(label.group()).map { it.groupValues[1] }
                    i = label.end()
                    atLineStart = false
                    continue
                }
            }
            atLineStart = false
            when {
                source.startsWith("//", i) -> {
                    val newline = source.indexOf('\n', i)
                    i = if (newline < 0) source.length else newline
                }
                source.startsWith("/*", i) -> {
                    val close = source.indexOf("*/", i + 2)
                    i = if (close < 0) source.length else close + 2
                }
                source.startsWith("\"\"\"", i) -> {
                    val close = source.indexOf("\"\"\"", i + 3)
                    i = if (close < 0) source.length else close + 3
                }
                c == '"' || c == '\'' -> {
                    i++
                    while (i < source.length && source[i] != c) {
                        if (source[i] == '\\') i++
                        i++
                    }
                    i++
                }
                c == '{' -> {
                    depth++
                    i++
                }
                c == '}' -> {
                    depth--
                    if (depth == 0) return labels
                    i++
                }
                else -> i++
            }
        }
        throw AssertionError("backend dispatch `$anchor` is not terminated")
    }
}
