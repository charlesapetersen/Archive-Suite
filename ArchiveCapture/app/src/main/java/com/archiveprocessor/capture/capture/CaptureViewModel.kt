package com.archiveprocessor.capture.capture

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.archiveprocessor.capture.data.Prefs
import com.archiveprocessor.capture.data.SessionStore
import com.archiveprocessor.capture.net.MacClient
import com.archiveprocessor.capture.net.MacEndpoint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** Owns the capture session: the paired endpoint, the current group, captured items, on-phone
 *  minimal tagging (priority + date), and the durable-ish upload of each item. */
class CaptureViewModel(app: Application) : AndroidViewModel(app) {
    private val prefs = Prefs(app)
    private val sessionDir: File = File(app.filesDir, "capture").apply { mkdirs() }

    val deviceName: String = android.os.Build.MODEL ?: "Android"

    var endpoint by mutableStateOf(prefs.loadEndpoint())
        private set
    private var client: MacClient? = endpoint?.let { MacClient(it) }

    val items = mutableStateListOf<CapturedItem>()
    var currentGroupId by mutableStateOf(newGroupId())
        private set
    var statusMessage by mutableStateOf("")
        private set

    /** The just-finished document segment awaiting the tag sheet (null = no sheet). */
    var pendingTagGroupId by mutableStateOf<String?>(null)
        private set

    /** Thumbnail selection for the tap → X → delete flow (one item at a time). */
    var selectedItemId by mutableStateOf<Long?>(null)
        private set
    var armed by mutableStateOf(false)   // second tap: delete-armed (shows an X)
        private set

    /** Running count of photos confirmed received by the Mac this session (they then leave the phone). */
    var sentCount by mutableStateOf(0)
        private set
    /** Transient "just sent a segment/marker to the Mac" banner (auto-clears); drives transfer feedback. */
    var transferFlash by mutableStateOf<String?>(null)
        private set
    private var flashJob: kotlinx.coroutines.Job? = null

    private var seqCounter = 0
    private var nextId = 1L

    private fun newGroupId() = "g" + UUID.randomUUID().toString().take(8)

    private val store = SessionStore(app)

    init {
        // Crash resilience: restore any prior session and re-send whatever wasn't confirmed uploaded.
        store.load()?.let { r ->
            items.addAll(r.items)
            seqCounter = r.seq
            nextId = r.nextId
            r.groupId?.let { currentGroupId = it }
            // Items confirmed on the Mac before a crash are durably safe there — drop them so the phone
            // shows only what still needs sending (mirrors the normal post-upload cleanup).
            items.filter { it.state == UploadState.UPLOADED }.toList().forEach { i ->
                runCatching { i.file.delete() }; items.remove(i)
            }
            if (items.isNotEmpty()) statusMessage = "Restored ${items.size} photo(s) from last session"
            resumeUploads()
            // Recovered buffered document pages stay in the current in-progress segment (currentGroupId
            // was restored above) so the operator keeps shooting and taps End segment when ready — we do
            // NOT assume the segment is finished. Re-open the tag card ONLY if the app stopped while the
            // user was actually mid-tagging a segment (pendingTag persisted).
            val tagGroup = r.pendingTagGroupId
            if (tagGroup != null && items.any { it.groupId == tagGroup && it.type == GroupType.DOCUMENT && it.state == UploadState.PENDING }) {
                currentGroupId = tagGroup
                pendingTagGroupId = tagGroup
            }
        }
        startAutoRetry()
    }

    private fun persist() = store.save(items.toList(), seqCounter, nextId, currentGroupId, pendingTagGroupId)

    /** Re-enqueue anything not confirmed uploaded. Idempotent on the Mac (same group+seq → replace). */
    private fun resumeUploads() {
        if (client == null) return
        // Re-send anything not yet on the Mac: in-flight/failed of any kind, plus a PENDING marker
        // (box/folder captured while unpaired — it never got enqueued). Buffered PENDING document pages
        // are intentionally NOT sent here; they wait for "End segment" so they can be tagged first.
        items.filter {
            it.state == UploadState.UPLOADING || it.state == UploadState.FAILED ||
                (it.state == UploadState.PENDING && it.type != GroupType.DOCUMENT)
        }.forEach { enqueueUpload(it) }
    }

    /** Background self-heal: periodically re-send failed uploads so an unplug/replug (or any brief
     *  network blip) recovers automatically — no manual Retry needed. Capture keeps working offline;
     *  photos just sit FAILED and flush once the link is back. Cancelled when the VM is cleared. */
    private fun startAutoRetry() {
        viewModelScope.launch {
            while (true) {
                delay(8_000)
                // Flush failed uploads and any stuck PENDING marker (unpaired capture); leave buffered
                // document pages alone until "End segment".
                val needsSend = items.filter {
                    it.state == UploadState.FAILED ||
                        (it.state == UploadState.PENDING && it.type != GroupType.DOCUMENT)
                }
                if (client != null && needsSend.isNotEmpty()) {
                    needsSend.forEach { enqueueUpload(it) }
                }
            }
        }
    }

    // ---- Pairing ----

    fun connect(host: String, port: Int, token: String, name: String = "Mac", onResult: (Boolean) -> Unit) {
        val ep = MacEndpoint(host, port, token, name)
        viewModelScope.launch {
            val ok = withContext(Dispatchers.IO) { MacClient(ep).ping() }
            if (ok) {
                endpoint = ep
                client = MacClient(ep)
                prefs.saveEndpoint(ep)
                statusMessage = "Connected to ${ep.name}"
                resumeUploads()
            } else {
                statusMessage = "Could not reach $host:$port"
            }
            onResult(ok)
        }
    }

    fun connectFromQr(payload: String, wired: Boolean, onResult: (Boolean) -> Unit) {
        val ep = MacEndpoint.fromQrPayload(payload)
        if (ep == null) { onResult(false); return }
        // Wired: reach the Mac at 127.0.0.1 over the adb-reverse tunnel; keep the QR's port + token.
        val host = if (wired) "127.0.0.1" else ep.host
        connect(host, ep.port, ep.token, ep.name, onResult)
    }

    fun disconnect() {
        prefs.clearEndpoint()
        endpoint = null
        client = null
    }

    // ---- Capture ----

    fun newCaptureFile(): File = File(sessionDir, "img_${System.currentTimeMillis()}.jpg")

    /** Main shutter: add a page to the current document segment (buffered until finalized). */
    fun addDocumentPhoto(file: File) {
        clearSelection()
        seqCounter += 1
        items.add(CapturedItem(id = nextId++, file = file, groupId = currentGroupId, seq = seqCounter, type = GroupType.DOCUMENT))
        val n = items.count { it.groupId == currentGroupId && it.type == GroupType.DOCUMENT }
        statusMessage = "Document · $n page${if (n == 1) "" else "s"}"
        persist()
    }

    /** Box/Folder: a single-image marker (never a multi-page segment) — its own group; uploads now. */
    fun captureMarker(file: File, type: GroupType) {
        clearSelection()
        seqCounter += 1
        val item = CapturedItem(id = nextId++, file = file, groupId = newGroupId(), seq = seqCounter, type = type)
        items.add(item)
        statusMessage = if (type == GroupType.BOX) "Box captured" else "Folder captured"
        persist()
        enqueueUpload(item)
        flash(if (type == GroupType.BOX) "Box → Mac" else "Folder → Mac")
    }

    /** Surface a failed camera capture so the operator knows to re-shoot — an archival photo can't be
     *  re-taken, so a silent drop is unacceptable. */
    fun reportCaptureError(message: String) {
        statusMessage = message
    }

    /** Long-press a page thumbnail to toggle a per-page P10 override. */
    fun toggleP10(itemId: Long) {
        val i = items.indexOfFirst { it.id == itemId }
        if (i < 0) return
        val it = items[i]
        items[i] = it.copy(priority = if (it.priority == "P10") null else "P10")
        persist()
    }

    private fun clearSelection() { selectedItemId = null; armed = false }

    /** Show a brief transfer banner (auto-clears after a couple of seconds). */
    private fun flash(message: String) {
        transferFlash = message
        flashJob?.cancel()
        flashJob = viewModelScope.launch { delay(2500); transferFlash = null }
    }

    /** Tap cycle on a thumbnail: select → arm (show X) → delete. */
    fun tapItem(id: Long) {
        when {
            selectedItemId != id -> { selectedItemId = id; armed = false }
            !armed -> armed = true
            else -> deleteItem(id)
        }
    }

    fun deleteItem(id: Long) {
        val i = items.indexOfFirst { it.id == id }
        if (i >= 0) {
            runCatching { items[i].file.delete() }
            items.removeAt(i)
        }
        clearSelection()
        persist()
    }

    /** A photo confirmed received by the Mac is durably safe there, so remove it from the phone
     *  (frees storage; keeps the strip showing only in-flight/queued pages, never a growing pile). */
    private fun removeConfirmed(item: CapturedItem) {
        // Guard by identity + state so a stale delayed-removal can never delete a different/newer photo
        // that reused this id (e.g. after Clear resets the id counter) — only the same, still-UPLOADED file.
        val i = items.indexOfFirst { it.id == item.id && it.file == item.file }
        if (i >= 0 && items[i].state == UploadState.UPLOADED) {
            runCatching { items[i].file.delete() }
            items.removeAt(i)
            if (selectedItemId == item.id) clearSelection()
            persist()
        }
    }

    /** Reclassify the selected photo as a single-image box/folder marker (own group) and upload it. */
    fun reclassifySelected(type: GroupType) {
        val id = selectedItemId ?: return
        val i = items.indexOfFirst { it.id == id }
        if (i >= 0) {
            val oldGroupId = items[i].groupId
            val updated = items[i].copy(type = type, groupId = newGroupId(), priority = null, state = UploadState.PENDING)
            items[i] = updated
            clearSelection()
            persist()
            // Tell the Mac to drop the old (oldGroupId, seq) copy if it already has it (idempotent no-op otherwise).
            enqueueUpload(updated, replaces = oldGroupId)
        }
    }

    // ---- Grouping / finalize ----

    /** Finish the current document segment → show its tag sheet, then start a fresh document segment. */
    fun finishDocumentSegment() {
        val hasDocs = items.any { it.groupId == currentGroupId && it.type == GroupType.DOCUMENT && it.state == UploadState.PENDING }
        if (hasDocs) { pendingTagGroupId = currentGroupId; persist() } else startNewGroup()
    }

    /** Stamp the tag sheet onto the pending segment's photos, enqueue them, then open the next segment. */
    fun applyTagsAndContinue(priority: String?, year: Int?, month: Int?) {
        val gid = pendingTagGroupId ?: return
        year?.let { prefs.noteYear(it) }
        var n = 0
        for (i in items.indices) {
            val it = items[i]
            if (it.groupId == gid && it.type == GroupType.DOCUMENT && it.state == UploadState.PENDING) {
                val stamped = it.copy(priority = it.priority ?: priority, year = year, month = month)
                items[i] = stamped
                enqueueUpload(stamped)
                n++
            }
        }
        if (n > 0) flash("Segment → Mac · $n page${if (n == 1) "" else "s"}")
        pendingTagGroupId = null
        startNewGroup()
        persist()
    }

    fun cancelTagSheet() {
        pendingTagGroupId = null
        persist()
    }

    private fun startNewGroup() {
        currentGroupId = newGroupId()
        persist()
    }

    fun recentYears(): List<Int> = prefs.recentYears()

    // ---- Upload ----

    /** Ids currently being uploaded, so the auto-retry loop and a manual Retry can't both fire the same
     *  item concurrently (double bandwidth + a racing ingest of the same filename on the Mac). */
    private val inFlightUploads = mutableSetOf<Long>()

    private fun enqueueUpload(item: CapturedItem, replaces: String? = null) {
        val c = client ?: return
        if (!inFlightUploads.add(item.id)) return   // already uploading this id — don't double-send
        setState(item.id, UploadState.UPLOADING)
        viewModelScope.launch {
            try {
                val bytes = withContext(Dispatchers.IO) { runCatching { item.file.readBytes() }.getOrNull() }
                var ok = false
                if (bytes != null) {
                    var attempt = 0
                    while (!ok && attempt < 3) {
                        ok = withContext(Dispatchers.IO) {
                            c.postPhoto(bytes, item.groupId, item.seq, item.type.wire,
                                item.priority, item.year, item.month, deviceName, replaces)
                        }
                        attempt++
                    }
                }
                setState(item.id, if (ok) UploadState.UPLOADED else UploadState.FAILED)
                if (ok) {
                    sentCount += 1
                    // Confirmed durably on the Mac → drop it from the phone shortly after (the brief delay
                    // lets the strip animate it out), so photos transfer in segments instead of piling up.
                    viewModelScope.launch { delay(650); removeConfirmed(item) }
                }
                statusMessage = uploadSummary()
            } finally {
                inFlightUploads.remove(item.id)
            }
        }
    }

    fun retryFailed() {
        items.filter { it.state == UploadState.FAILED }.forEach { enqueueUpload(it) }
    }

    fun finishSession() {
        val c = client ?: return
        viewModelScope.launch { withContext(Dispatchers.IO) { c.sessionComplete() } }
    }

    /** Delete every captured photo (files + persisted session) and start a clean session. */
    fun clearSession() {
        for (item in items) { runCatching { item.file.delete() } }
        items.clear()
        seqCounter = 0
        nextId = 1L
        currentGroupId = newGroupId()
        pendingTagGroupId = null
        clearSelection()
        sentCount = 0
        transferFlash = null
        statusMessage = ""
        store.clear()
    }

    private fun setState(id: Long, state: UploadState) {
        val i = items.indexOfFirst { it.id == id }
        if (i >= 0) {
            items[i] = items[i].copy(state = state)
            persist()
        }
    }

    private fun uploadSummary(): String {
        val failed = items.count { it.state == UploadState.FAILED }
        val inflight = items.count { it.state == UploadState.PENDING || it.state == UploadState.UPLOADING }
        return buildString {
            if (inflight > 0) append("$inflight queued")
            if (failed > 0) {
                if (isNotEmpty()) append(" · ")
                append("$failed failed")
            }
        }
    }
}
