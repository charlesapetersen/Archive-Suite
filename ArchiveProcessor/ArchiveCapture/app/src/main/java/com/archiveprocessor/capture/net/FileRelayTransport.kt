package com.archiveprocessor.capture.net

import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * SegmentTransport that writes into a shared directory (offline stand-in for the Google Drive relay).
 * postPhoto returns true ONLY after the Mac's matching-(token,epoch,group,seq,fp) receipt appears — never
 * on write alone (never-lose contract). Adopts the Mac-published epoch from _epoch.json (A2). Blocking
 * (the VM calls transports inside withContext(Dispatchers.IO)). Byte-format via RelayObjectFormat.
 *
 * Constructed directly by tests this milestone (on-device pairing/UI + a SAF/ContentResolver-backed shared
 * dir land with the Drive backend, spec §8), so the shipped HTTP MacClient path stays untouched.
 */
class FileRelayTransport(
    private val sessionDir: File,          // <relayRoot>/<token>/
    private val token: String,
    private val receiptWaitTimeoutMs: Long = 20_000,
    private val receiptPollMs: Long = 500
) : SegmentTransport {

    private fun currentEpoch(): String? {
        val f = File(sessionDir, RelayObjectFormat.EPOCH_MARKER_NAME)
        if (!f.exists()) return null
        return try {
            val o = JSONObject(f.readText())
            if (o.optString("token") == token) o.optString("epoch").ifEmpty { null } else null
        } catch (e: Exception) { null }
    }

    private fun writeAtomic(name: String, data: ByteArray) {
        val finalF = File(sessionDir, name)
        val tmp = File(sessionDir, "." + name + "." + UUID.randomUUID() + ".part")
        try {
            tmp.writeBytes(data)
            if (finalF.exists()) finalF.delete()
            if (!tmp.renameTo(finalF)) { tmp.copyTo(finalF, overwrite = true); tmp.delete() }
        } catch (e: Exception) { tmp.delete() }
    }

    private fun validReceipt(group: String, seq: Int, epoch: String, fp: String): Boolean {
        val f = File(sessionDir, RelayObjectFormat.receiptName(group, seq))
        if (!f.exists()) return false
        return try {
            val o = JSONObject(f.readText())
            // A1: accept ONLY a receipt acking the CURRENT metadata (fp) for THIS run (epoch).
            o.optString("kind") == "receipt" && o.optString("token") == token && o.optString("epoch") == epoch &&
                o.optString("group") == group && o.optString("seq") == seq.toString() && o.optString("fp") == fp
        } catch (e: Exception) { false }
    }

    override fun postPhoto(jpeg: ByteArray, group: String, seq: Int, type: String, quality: String?,
                           year: Int?, month: Int?, device: String, replaces: String?): Boolean {
        val yearS = year?.toString(); val monthS = month?.toString()
        val repl = if (!replaces.isNullOrEmpty()) replaces else null
        val fp = RelayObjectFormat.fingerprint(type, quality, yearS, monthS, repl)
        sessionDir.mkdirs()
        val deadline = System.currentTimeMillis() + receiptWaitTimeoutMs
        var wroteForEpoch: String? = null
        do {
            val epoch = currentEpoch()
            if (epoch == null) { Thread.sleep(receiptPollMs); continue }   // Mac relay not up yet → retry (not a loss)
            if (validReceipt(group, seq, epoch, fp)) return true                          // (a) receipt-first
            if (wroteForEpoch != epoch) {                                                 // (b) write-once per epoch
                writeAtomic(RelayObjectFormat.jpegName(group, seq), jpeg)                 // jpeg FIRST
                writeAtomic(RelayObjectFormat.sidecarName(group, seq),                    // sidecar LAST = commit marker
                    RelayObjectFormat.encodeSidecar(token, epoch, group, seq, type, quality, yearS, monthS, repl, device))
                wroteForEpoch = epoch
            }
            Thread.sleep(receiptPollMs)                                                   // (c) poll
        } while (System.currentTimeMillis() < deadline)
        return false   // timeout → item stays FAILED → auto-retry re-enters at (a); local copy retained
    }

    override fun segmentComplete(group: String, quality: String?, year: Int?, month: Int?, seqs: String?): Boolean {
        val epoch = currentEpoch() ?: return false
        writeAtomic(RelayObjectFormat.segmentName(group),
            RelayObjectFormat.encodeSegment(token, epoch, group, quality, year?.toString(), month?.toString(), seqs))
        return true
    }

    override fun sessionComplete(): Boolean {
        val epoch = currentEpoch() ?: return false
        writeAtomic(RelayObjectFormat.SESSION_COMPLETE_NAME, RelayObjectFormat.encodeSessionComplete(token, epoch))
        return true
    }

    override fun sessionDisconnect(): Boolean = true   // no persistent connection to drop
}
