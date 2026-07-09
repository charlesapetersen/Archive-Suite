package com.archiveprocessor.capture.net

import org.json.JSONObject

/**
 * A [SegmentTransport] that uploads to Google Drive (the production cloud relay) — the same receipt-wait
 * never-lose contract as [FileRelayTransport], but over Drive REST via [DriveClient]. `postPhoto` returns
 * `true` ONLY after the Mac's matching-`(token,epoch,group,seq,fp)` receipt appears, never on a write alone.
 * Adopts the Mac-published epoch from `_epoch.json` in the shared Drive folder.
 *
 * Uses query-or-update (find by `appProperties.relayName` → update, else create) so it stores NO fileId —
 * side-stepping the coexisting-duplicate hazard at the source (the Mac's reap is the backstop). Blocking
 * (called inside `withContext(Dispatchers.IO)`). Byte-format via [RelayObjectFormat]; parses the small
 * receipt/epoch objects with org.json. Kotlin mirror of the iOS `DriveRelayTransport`. `client`'s token
 * provider is a Google OAuth access token for the SAME account as the Mac (device sign-in supplies it).
 */
class DriveRelayTransport(
    private val client: DriveClient,
    private val token: String,
    private val receiptWaitTimeoutMs: Long = 20_000,
    private val receiptPollMs: Long = 500
) : SegmentTransport {

    private fun esc(s: String) = s.replace("'", "\\'")

    private fun folderId(): String? = try {
        client.listFiles("mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='relayToken' and value='${esc(token)}' } and trashed = false").firstOrNull()?.id
    } catch (e: Exception) { null }

    private fun fileId(folder: String, name: String): String? = try {
        client.listFiles("'${esc(folder)}' in parents and appProperties has { key='relayName' and value='${esc(name)}' } and trashed = false").firstOrNull()?.id
    } catch (e: Exception) { null }

    private fun upsert(folder: String, name: String, data: ByteArray, mime: String) {
        try {
            val id = fileId(folder, name)
            if (id != null) client.updateMedia(id, data, mime)
            else client.createFile(name, listOf(folder), mapOf("relayName" to name, "relayToken" to token), data, mime)
        } catch (e: Exception) { /* best-effort: no receipt → phone's receipt-wait times out + retries; never a loss */ }
    }

    private fun read(folder: String, name: String): ByteArray? = try {
        val id = fileId(folder, name); if (id != null) client.getMedia(id) else null
    } catch (e: Exception) { null }

    private fun epoch(folder: String): String? {
        val d = read(folder, RelayObjectFormat.EPOCH_MARKER_NAME) ?: return null
        return try {
            val o = JSONObject(String(d, Charsets.UTF_8))
            if (o.optString("token") == token) o.optString("epoch").ifEmpty { null } else null
        } catch (e: Exception) { null }
    }

    private fun validReceipt(folder: String, group: String, seq: Int, epoch: String, fp: String): Boolean {
        val d = read(folder, RelayObjectFormat.receiptName(group, seq)) ?: return false
        return try {
            val o = JSONObject(String(d, Charsets.UTF_8))
            o.optString("kind") == "receipt" && o.optString("token") == token && o.optString("epoch") == epoch &&
                o.optString("group") == group && o.optString("seq") == seq.toString() && o.optString("fp") == fp
        } catch (e: Exception) { false }
    }

    override fun postPhoto(jpeg: ByteArray, group: String, seq: Int, type: String, priority: String?,
                           year: Int?, month: Int?, device: String, replaces: String?): Boolean {
        val yearS = year?.toString(); val monthS = month?.toString()
        val repl = if (!replaces.isNullOrEmpty()) replaces else null
        val fp = RelayObjectFormat.fingerprint(type, priority, yearS, monthS, repl)
        val deadline = System.currentTimeMillis() + receiptWaitTimeoutMs
        var folder: String? = null; var wroteForEpoch: String? = null
        do {
            if (folder == null) folder = folderId()
            if (folder == null) { Thread.sleep(1000); continue }          // Mac relay not up yet
            val f = folder!!
            val e = epoch(f)                                              // re-read each iteration (epoch may change on Mac restart)
            if (e == null) { Thread.sleep(1000); continue }               // no epoch yet
            if (validReceipt(f, group, seq, e, fp)) return true           // receipt-first
            if (wroteForEpoch != e) {                                     // write-once per epoch (re-write if epoch changes)
                upsert(f, RelayObjectFormat.jpegName(group, seq), jpeg, "image/jpeg")
                upsert(f, RelayObjectFormat.sidecarName(group, seq),
                    RelayObjectFormat.encodeSidecar(token, e, group, seq, type, priority, yearS, monthS, repl, device), "application/json")
                wroteForEpoch = e
            }
            Thread.sleep(receiptPollMs)
        } while (System.currentTimeMillis() < deadline)
        return false   // timeout → item stays FAILED → auto-retry re-enters (re-resolves epoch); local copy retained
    }

    override fun segmentComplete(group: String, priority: String?, year: Int?, month: Int?, seqs: String?): Boolean {
        val f = folderId() ?: return false; val e = epoch(f) ?: return false
        upsert(f, RelayObjectFormat.segmentName(group),
            RelayObjectFormat.encodeSegment(token, e, group, priority, year?.toString(), month?.toString(), seqs), "application/json")
        return true
    }

    override fun sessionComplete(): Boolean {
        val f = folderId() ?: return false; val e = epoch(f) ?: return false
        upsert(f, RelayObjectFormat.SESSION_COMPLETE_NAME, RelayObjectFormat.encodeSessionComplete(token, e), "application/json")
        return true
    }

    override fun sessionDisconnect(): Boolean = true
}
