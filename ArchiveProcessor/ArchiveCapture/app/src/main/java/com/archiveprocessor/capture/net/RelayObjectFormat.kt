package com.archiveprocessor.capture.net

import java.security.MessageDigest

/**
 * Pure-Kotlin (no Android API) mirror of the Mac/iOS `RelayObjectFormat`. MUST produce byte-identical
 * canonical JSON so the Mac receiver reads what this writes — guarded by the golden byte-check against
 * `SPEC/relay-golden/`. Keep in lockstep with `ArchiveProcessor/.../Net/RelayObjectFormat.swift` and
 * `ArchiveCaptureiOS/.../Net/RelayObjectFormat.swift`. Spec: `LIVE_CAPTURE_FILERELAY_SPEC.md` (v2 binds).
 *
 * No `org.json` here (keeps it JVM-unit-testable); the transport does its own receipt/epoch parsing.
 */
object RelayObjectFormat {
    fun jpegName(group: String, seq: Int) = "${group}__${seq}.jpg"
    fun sidecarName(group: String, seq: Int) = "${group}__${seq}.json"
    fun receiptName(group: String, seq: Int) = "${group}__${seq}.receipt.json"
    fun segmentName(group: String) = "${group}.segment.json"
    const val SESSION_COMPLETE_NAME = "_session.complete.json"
    const val EPOCH_MARKER_NAME = "_epoch.json"

    /** Canonical JSON: nil-omitted, keys ascending (fixed lowercase-ASCII keys → same sort as Swift),
     *  fixed escape table, UTF-8 encoded once at the end (astral scalars stay identical UTF-8 sequences). */
    fun canonicalJson(map: Map<String, String?>): ByteArray {
        val pairs = map.entries.filter { it.value != null }.sortedBy { it.key }
        val sb = StringBuilder("{")
        for ((i, e) in pairs.withIndex()) {
            if (i > 0) sb.append(',')
            sb.append('"').append(escape(e.key)).append("\":\"").append(escape(e.value!!)).append('"')
        }
        sb.append('}')
        return sb.toString().toByteArray(Charsets.UTF_8)
    }

    /** Matches the Swift escape table exactly: only `"` `\` and C0 controls are escaped (short forms for
     *  BS/TAB/LF/FF/CR, `\u00xx` lowercase for the rest); `/` and all non-ASCII emitted verbatim. */
    private fun escape(s: String): String {
        val sb = StringBuilder(s.length)
        for (c in s) {
            when {
                c == '"' -> sb.append("\\\"")
                c == '\\' -> sb.append("\\\\")
                c.code == 0x08 -> sb.append("\\b")
                c.code == 0x09 -> sb.append("\\t")
                c.code == 0x0A -> sb.append("\\n")
                c.code == 0x0C -> sb.append("\\f")
                c.code == 0x0D -> sb.append("\\r")
                c.code < 0x20 -> sb.append("\\u%04x".format(c.code))
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }

    /** fp = SHA-256(canonicalJSON of the ingest-relevant metadata) → first 16 hex. Same fn+inputs as the
     *  Swift side → identical fp. Excludes `device` (a device-name change must not force a re-ingest, A1). */
    fun fingerprint(type: String, priority: String?, year: String?, month: String?, replaces: String?): String {
        val m = mapOf("type" to type, "priority" to priority, "year" to year, "month" to month, "replaces" to replaces)
        val digest = MessageDigest.getInstance("SHA-256").digest(canonicalJson(m))
        return digest.copyOfRange(0, 8).joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }

    fun encodeSidecar(token: String, epoch: String, group: String, seq: Int, type: String,
                      priority: String?, year: String?, month: String?, replaces: String?, device: String? = null): ByteArray {
        val fp = fingerprint(type, priority, year, month, replaces)
        return canonicalJson(mapOf("kind" to "photo", "token" to token, "epoch" to epoch, "group" to group,
            "seq" to seq.toString(), "type" to type, "priority" to priority, "year" to year, "month" to month,
            "replaces" to replaces, "device" to device, "fp" to fp))
    }

    fun encodeSegment(token: String, epoch: String, group: String,
                      priority: String?, year: String?, month: String?, seqs: String?): ByteArray =
        canonicalJson(mapOf("kind" to "segment-complete", "token" to token, "epoch" to epoch, "group" to group,
            "priority" to priority, "year" to year, "month" to month, "seqs" to seqs))

    fun encodeSessionComplete(token: String, epoch: String): ByteArray =
        canonicalJson(mapOf("kind" to "session-complete", "token" to token, "epoch" to epoch))
}
