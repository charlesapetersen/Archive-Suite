package com.archiveprocessor.capture.net

import org.junit.Assert.assertArrayEquals
import org.junit.Test
import java.io.File

/**
 * Cross-platform golden byte-check (A7/A8): the Kotlin RelayObjectFormat MUST emit byte-identical canonical
 * JSON to the committed SPEC/relay-golden/ fixtures (generated from the Mac writer, matched by iOS). Guards
 * against silent Swift<->Kotlin escaping/ordering/hex-case divergence. Plain-JVM (RelayObjectFormat has no
 * Android deps), so no emulator/Robolectric.
 */
class RelayObjectFormatTest {

    private fun goldenDir(): File {
        var d: File? = File(System.getProperty("user.dir") ?: ".")
        while (d != null) {
            val g = File(d, "SPEC/relay-golden")
            if (g.isDirectory) return g
            d = d.parentFile
        }
        throw IllegalStateException("SPEC/relay-golden not found upward from ${System.getProperty("user.dir")}")
    }

    private fun golden(name: String): ByteArray = File(goldenDir(), name).readBytes()

    @Test fun sidecarMatchesGolden() {
        val out = RelayObjectFormat.encodeSidecar("TESTTK", "EP1", "g1", 7, "document", "Q1", "1968", "3", null, "X")
        assertArrayEquals("g1__7.json must match golden byte-for-byte", golden("g1__7.json"), out)
    }

    @Test fun nastyUnicodeSidecarMatchesGolden() {
        // U+2019 (right single quote) + U+1F600 (grinning face, as a UTF-16 surrogate pair) + U+0001 (C0 SOH)
        val device = "X’😀"
        val out = RelayObjectFormat.encodeSidecar("TESTTK", "EP1", "nasty", 0, "document", null, null, null, null, device)
        assertArrayEquals("nasty__0.json escaping must match golden byte-for-byte", golden("nasty__0.json"), out)
    }

    @Test fun segmentMatchesGolden() {
        val out = RelayObjectFormat.encodeSegment("TESTTK", "EP1", "g1", "Q1", "1968", "3", "6,7")
        assertArrayEquals("g1.segment.json must match golden byte-for-byte", golden("g1.segment.json"), out)
    }

    @Test fun sessionCompleteMatchesGolden() {
        val out = RelayObjectFormat.encodeSessionComplete("TESTTK", "EP1")
        assertArrayEquals("_session.complete.json must match golden byte-for-byte", golden("_session.complete.json"), out)
    }
}
