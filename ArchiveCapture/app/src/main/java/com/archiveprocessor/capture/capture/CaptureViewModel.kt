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
            if (items.isNotEmpty()) statusMessage = "Restored ${items.size} photo(s) from last session"
            resumeUploads()
        }
    }

    private fun persist() = store.save(items.toList(), seqCounter, nextId, currentGroupId)

    /** Re-enqueue anything not confirmed uploaded. Idempotent on the Mac (same group+seq → replace). */
    private fun resumeUploads() {
        if (client == null) return
        items.filter { it.state == UploadState.UPLOADING || it.state == UploadState.FAILED }
            .forEach { enqueueUpload(it) }
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
        seqCounter += 1
        items.add(CapturedItem(id = nextId++, file = file, groupId = currentGroupId, seq = seqCounter, type = GroupType.DOCUMENT))
        val n = items.count { it.groupId == currentGroupId && it.type == GroupType.DOCUMENT }
        statusMessage = "Document · $n page${if (n == 1) "" else "s"}"
        persist()
    }

    /** Box/Folder: a single-image marker (never a multi-page segment) — its own group; uploads now. */
    fun captureMarker(file: File, type: GroupType) {
        seqCounter += 1
        val item = CapturedItem(id = nextId++, file = file, groupId = newGroupId(), seq = seqCounter, type = type)
        items.add(item)
        statusMessage = if (type == GroupType.BOX) "Box captured" else "Folder captured"
        persist()
        enqueueUpload(item)
    }

    /** Long-press a page thumbnail to toggle a per-page P10 override. */
    fun toggleP10(itemId: Long) {
        val i = items.indexOfFirst { it.id == itemId }
        if (i < 0) return
        val it = items[i]
        items[i] = it.copy(priority = if (it.priority == "P10") null else "P10")
        persist()
    }

    // ---- Grouping / finalize ----

    /** Finish the current document segment → show its tag sheet, then start a fresh document segment. */
    fun finishDocumentSegment() {
        val hasDocs = items.any { it.groupId == currentGroupId && it.type == GroupType.DOCUMENT && it.state == UploadState.PENDING }
        if (hasDocs) pendingTagGroupId = currentGroupId else startNewGroup()
    }

    /** Stamp the tag sheet onto the pending segment's photos, enqueue them, then open the next segment. */
    fun applyTagsAndContinue(priority: String?, year: Int?, month: Int?) {
        val gid = pendingTagGroupId ?: return
        year?.let { prefs.noteYear(it) }
        for (i in items.indices) {
            val it = items[i]
            if (it.groupId == gid && it.type == GroupType.DOCUMENT && it.state == UploadState.PENDING) {
                val stamped = it.copy(priority = it.priority ?: priority, year = year, month = month)
                items[i] = stamped
                enqueueUpload(stamped)
            }
        }
        pendingTagGroupId = null
        startNewGroup()
        persist()
    }

    fun cancelTagSheet() {
        pendingTagGroupId = null
    }

    private fun startNewGroup() {
        currentGroupId = newGroupId()
        persist()
    }

    fun recentYears(): List<Int> = prefs.recentYears()

    // ---- Upload ----

    private fun enqueueUpload(item: CapturedItem) {
        val c = client ?: return
        setState(item.id, UploadState.UPLOADING)
        viewModelScope.launch {
            val bytes = withContext(Dispatchers.IO) { runCatching { item.file.readBytes() }.getOrNull() }
            var ok = false
            if (bytes != null) {
                var attempt = 0
                while (!ok && attempt < 3) {
                    ok = withContext(Dispatchers.IO) {
                        c.postPhoto(bytes, item.groupId, item.seq, item.type.wire,
                            item.priority, item.year, item.month, deviceName)
                    }
                    attempt++
                }
            }
            setState(item.id, if (ok) UploadState.UPLOADED else UploadState.FAILED)
            statusMessage = uploadSummary()
        }
    }

    fun retryFailed() {
        items.filter { it.state == UploadState.FAILED }.forEach { enqueueUpload(it) }
    }

    fun finishSession() {
        val c = client ?: return
        viewModelScope.launch { withContext(Dispatchers.IO) { c.sessionComplete() } }
    }

    private fun setState(id: Long, state: UploadState) {
        val i = items.indexOfFirst { it.id == id }
        if (i >= 0) {
            items[i] = items[i].copy(state = state)
            persist()
        }
    }

    private fun uploadSummary(): String {
        val up = items.count { it.state == UploadState.UPLOADED }
        val failed = items.count { it.state == UploadState.FAILED }
        return "$up uploaded" + if (failed > 0) ", $failed failed" else ""
    }
}
