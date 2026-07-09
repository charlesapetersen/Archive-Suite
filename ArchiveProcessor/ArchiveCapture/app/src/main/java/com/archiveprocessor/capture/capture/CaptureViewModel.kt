package com.archiveprocessor.capture.capture

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.archiveprocessor.capture.data.PhoneBackup
import com.archiveprocessor.capture.data.Prefs
import com.archiveprocessor.capture.data.SessionStore
import com.archiveprocessor.capture.net.DriveAuth
import com.archiveprocessor.capture.net.DriveClient
import com.archiveprocessor.capture.net.DriveRelayTransport
import com.archiveprocessor.capture.net.MacClient
import com.archiveprocessor.capture.net.SegmentTransport
import com.archiveprocessor.capture.net.MacEndpoint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
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

    /** On-device Google sign-in for the cloud relay; the UI launches its consent flow during pairing. */
    val driveAuth = DriveAuth(app)

    val deviceName: String = android.os.Build.MODEL ?: "Android"

    var endpoint by mutableStateOf(prefs.loadEndpoint())
        private set
    // Abstracted behind SegmentTransport so the durable queue/retry/dedup below never sees the transport:
    // LAN/USB → MacClient (HTTP), cloud → DriveRelayTransport (Google Drive). See transportFor().
    private var client: SegmentTransport? = endpoint?.let { transportFor(it) }

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

    /** Document segments the operator has ended (End segment → Apply/Skip) whose segment-complete signal
     *  the Mac hasn't acked yet, with the tags to send. PERSISTED so an app-kill between End segment and
     *  the ack can't strand the document (the Mac's own "Finish session" is a further backstop — it
     *  force-completes any still-open group). A group's signal is emitted only once ALL its pages are
     *  confirmed uploaded (see [trySendSegmentComplete]) so the Mac can never complete a partial segment,
     *  and is retried until acked. Insertion-ordered so completions send in the order segments ended. */
    private data class SegTags(val priority: String?, val year: Int?, val month: Int?)
    private val endedSegments = LinkedHashMap<String, SegTags>()
    /** Group ids whose completion signal is being sent right now, so the auto-retry loop, the
     *  upload-success hook, and resume can't fire the same one concurrently. */
    private val inFlightSegments = mutableSetOf<String>()

    private fun newGroupId() = "g" + UUID.randomUUID().toString().take(8)

    private val store = SessionStore(app)

    /** Off-main, write-latest-wins session persistence: snapshot on the (cheap) main thread, then
     *  serialize + write on IO so the UI never blocks on disk during capture/upload bursts. */
    private data class SaveSnapshot(val items: List<CapturedItem>, val seq: Int, val nextId: Long, val group: String,
                                    val pendingTag: String?, val ended: List<SessionStore.EndedSeg>)
    private val saveChannel = Channel<SaveSnapshot>(Channel.CONFLATED)

    init {
        // Start the off-main session writer first, so any persist() during restore is handled off the UI thread.
        viewModelScope.launch(Dispatchers.IO) {
            for (snap in saveChannel) store.save(snap.items, snap.seq, snap.nextId, snap.group, snap.pendingTag, snap.ended)
        }
        // Crash resilience: restore any prior session and re-send whatever wasn't confirmed uploaded.
        store.load()?.let { r ->
            items.addAll(r.items)
            seqCounter = r.seq
            nextId = r.nextId
            r.groupId?.let { currentGroupId = it }
            // Restore segments ended-but-not-yet-acked so their completion signal is re-sent below (each
            // still gated on all its pages being uploaded), even across an app kill.
            r.endedSegments.forEach { endedSegments[it.group] = SegTags(it.priority, it.year, it.month) }
            // Items confirmed on the Mac before a crash are durably safe there — drop them so the phone
            // shows only what still needs sending. EXCEPT document pages still in the current (un-ended)
            // segment: those streamed as shot but aren't tagged yet (tags apply at End segment), so keep
            // them so the operator can finish + tag the recovered segment.
            items.filter { it.state == UploadState.UPLOADED &&
                !(it.type == GroupType.DOCUMENT && it.groupId == currentGroupId) }.toList().forEach { i ->
                runCatching { i.file.delete() }; items.remove(i)
            }
            if (items.isNotEmpty()) statusMessage = "Restored ${items.size} photo(s) from last session"
            resumeUploads()
            // Recovered buffered document pages stay in the current in-progress segment (currentGroupId
            // was restored above) so the operator keeps shooting and taps End segment when ready — we do
            // NOT assume the segment is finished. Re-open the tag card ONLY if the app stopped while the
            // user was actually mid-tagging a segment (pendingTag persisted).
            val tagGroup = r.pendingTagGroupId
            if (tagGroup != null && items.any { it.groupId == tagGroup && it.type == GroupType.DOCUMENT }) {
                currentGroupId = tagGroup
                pendingTagGroupId = tagGroup
            }
        }
        // Self-heal orphans: capture files on disk not tracked by the restored session (session.json can
        // lag/corrupt across a crash) would otherwise never be shown, uploaded, or cleaned up. Re-adopt
        // them into a dedicated recovery segment so an un-retakeable image is never silently lost.
        val known = items.map { it.file.path }.toHashSet()
        val orphans = sessionDir.listFiles { f -> f.isFile && f.name.startsWith("img_") && f.path !in known }
            ?.sortedBy { it.name } ?: emptyList()
        if (orphans.isNotEmpty()) {
            val recoveryGroup = newGroupId()
            orphans.forEach { f ->
                seqCounter += 1
                items.add(CapturedItem(id = nextId++, file = f, groupId = recoveryGroup, seq = seqCounter, type = GroupType.DOCUMENT))
            }
            statusMessage = "Recovered ${orphans.size} untracked photo(s)"
            persist()
        }
        startAutoRetry()
    }

    private fun persist() {
        // trySend on a CONFLATED channel never blocks and always keeps the latest snapshot; the IO
        // consumer writes it near-immediately, preserving crash durability without main-thread disk I/O.
        val ended = endedSegments.map { (g, t) -> SessionStore.EndedSeg(g, t.priority, t.year, t.month) }
        saveChannel.trySend(SaveSnapshot(items.toList(), seqCounter, nextId, currentGroupId, pendingTagGroupId, ended))
    }

    /** Re-enqueue anything not confirmed uploaded. Idempotent on the Mac (same group+seq → replace). */
    private fun resumeUploads() {
        if (client == null) return
        // Re-send anything not confirmed on the Mac (in-flight/failed, or still-PENDING). Document pages
        // now stream as shot, so a PENDING doc is simply one captured while unpaired/offline — send it too.
        items.filter { it.state != UploadState.UPLOADED }.forEach { enqueueUpload(it) }
        // Re-drive any ended segment whose completion signal hasn't been acked (each still gated on all
        // its pages being uploaded), so a reconnect flushes them.
        resendEndedSegments()
        sendStatusReport()   // let the Mac know the current un-sent count as soon as we (re)connect
    }

    /** Background self-heal: periodically re-send failed uploads so an unplug/replug (or any brief
     *  network blip) recovers automatically — no manual Retry needed. Capture keeps working offline;
     *  photos just sit FAILED and flush once the link is back. Cancelled when the VM is cleared. */
    private fun startAutoRetry() {
        viewModelScope.launch {
            while (true) {
                delay(8_000)
                // Flush anything not confirmed on the Mac — failed uploads and any still-PENDING page
                // (document pages now stream as shot, so a PENDING doc just hasn't reached the Mac yet).
                val needsSend = items.filter { it.state == UploadState.FAILED || it.state == UploadState.PENDING }
                if (client != null) {
                    if (needsSend.isNotEmpty()) needsSend.forEach { enqueueUpload(it) }
                    // Retry any ended segment whose completion signal hasn't been acked (gated on all its
                    // pages being uploaded), so a transient drop at End segment self-heals.
                    resendEndedSegments()
                    // Heartbeat the un-sent count (incl. 0 when drained) so the Mac's "phone still has N to
                    // send" stays fresh even while the phone is idle.
                    sendStatusReport()
                }
            }
        }
    }

    // ---- Pairing ----

    /** Build the transport for an endpoint: HTTP for LAN/USB, the Google Drive relay for cloud. The
     *  cloud transport pulls a fresh Google access token per call via [DriveAuth]. */
    private fun transportFor(ep: MacEndpoint): SegmentTransport =
        if (ep.isCloud) DriveRelayTransport(DriveClient(token = { driveAuth.accessTokenBlocking() }), ep.token)
        else MacClient(ep)

    fun connect(host: String, port: Int, token: String, name: String = "Mac", onResult: (Boolean) -> Unit) {
        val ep = MacEndpoint(host, port, token, name)
        viewModelScope.launch {
            val r = withContext(Dispatchers.IO) { MacClient(ep).reachability() }
            if (r == com.archiveprocessor.capture.net.Reachability.OK) {
                endpoint = ep
                client = transportFor(ep)
                prefs.saveEndpoint(ep)
                statusMessage = ""   // connection status is owned by the endpoint-bound header; don't duplicate it here (re-pair showed two lines)
                resumeUploads()
            } else {
                // Name the cause + the fix, so the operator isn't left staring at a dead scanner.
                statusMessage = when (r) {
                    com.archiveprocessor.capture.net.Reachability.UNREACHABLE ->
                        "Can't reach the Mac at $host:$port. This Wi-Fi may block device-to-device connections (common on public / guest / hotel Wi-Fi). Try a personal hotspot (join both devices to it), a USB cable, or check Live Capture is running on the Mac."
                    com.archiveprocessor.capture.net.Reachability.REFUSED ->
                        "Reached the network but nothing is listening at $host:$port — is Live Capture started on the Mac?"
                    com.archiveprocessor.capture.net.Reachability.UNAUTHORIZED ->
                        "Reached the Mac but the pairing code was rejected — re-scan the QR (it may be stale)."
                    else -> "Could not reach $host:$port"
                }
            }
            onResult(r == com.archiveprocessor.capture.net.Reachability.OK)
        }
    }

    fun connectFromQr(payload: String, wired: Boolean, onResult: (Boolean) -> Unit) {
        val ep = MacEndpoint.fromQrPayload(payload)
        if (ep == null) { onResult(false); return }
        // Wired: reach the Mac at 127.0.0.1 over the adb-reverse tunnel; keep the QR's port + token.
        val host = if (wired) "127.0.0.1" else ep.host
        connect(host, ep.port, ep.token, ep.name, onResult)
    }

    /** Finish cloud pairing after a successful Google sign-in (the UI drives sign-in, since it needs an
     *  Activity). No HTTP reachability probe: the first postPhoto resolves the Mac's Drive folder + epoch,
     *  and if the Mac's cloud session isn't up yet the upload simply stays FAILED and auto-retries — the
     *  never-lose contract holds, so nothing is ever dropped waiting for the Mac. */
    fun connectCloud(ep: MacEndpoint, onResult: (Boolean) -> Unit) {
        viewModelScope.launch {
            endpoint = ep
            client = transportFor(ep)
            prefs.saveEndpoint(ep)
            statusMessage = "Cloud relay ready — uploading to Google Drive"
            resumeUploads()
            onResult(true)
        }
    }

    fun disconnect() {
        // Best-effort: tell the Mac we're re-pairing so it re-shows the QR (there's no persistent
        // connection for it to notice the drop). Fire before clearing the client; ignore failure.
        client?.let { c -> viewModelScope.launch { withContext(Dispatchers.IO) { runCatching { c.sessionDisconnect() } } } }
        prefs.clearEndpoint()
        endpoint = null
        client = null
    }

    // ---- Capture ----

    // UUID (not just a millisecond timestamp): two captures in the same millisecond must not resolve to
    // the same path, or CameraX would overwrite the first image and one archival page would be lost.
    fun newCaptureFile(): File = File(sessionDir, "img_${System.currentTimeMillis()}_${UUID.randomUUID()}.jpg")

    /** Main shutter: add a page to the current document segment and stream it to the Mac immediately. */
    fun addDocumentPhoto(file: File) {
        clearSelection()
        seqCounter += 1
        val item = CapturedItem(id = nextId++, file = file, groupId = currentGroupId, seq = seqCounter, type = GroupType.DOCUMENT)
        items.add(item)
        val n = items.count { it.groupId == currentGroupId && it.type == GroupType.DOCUMENT }
        statusMessage = "Document · $n page${if (n == 1) "" else "s"}"
        persist()
        // Stream the page to the Mac immediately (DATA SAFETY: a segment can be hundreds of photos, so no
        // page waits for "End segment" — a crash/drop before then must never lose an already-shot page).
        // The icon stays in the strip until End segment (removeConfirmed keeps current-group docs) so the
        // operator watches the segment grow; End segment then sends the segment-complete signal + tags.
        enqueueUpload(item)
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
        val updated = it.copy(priority = if (it.priority == "P10") null else "P10")
        items[i] = updated
        persist()
        // The page may already be on the Mac (pages stream as shot) — re-send it so the P10 override lands
        // (idempotent group+seq replace). The segment-complete signal carries only the group's priority,
        // so a per-page P10 must ride the photo itself. If it's still UPLOADING, defer via needsResend so
        // the toggle isn't dropped (the completion handler re-sends with the current value).
        resendOrEnqueue(updated)
    }

    /** Re-send a just-changed item: enqueue now if it's idle, else flag it to be re-sent when its in-flight
     *  upload settles. This is the fix for a per-page P10 toggle / reclassify racing an in-flight upload —
     *  the `inFlightUploads` guard would otherwise suppress the re-enqueue and silently drop the change. */
    private fun resendOrEnqueue(item: CapturedItem) {
        if (inFlightUploads.contains(item.id)) markNeedsResend(item.id) else enqueueUpload(item)
    }

    private fun markNeedsResend(id: Long) {
        val i = items.indexOfFirst { it.id == id }
        if (i >= 0 && !items[i].needsResend) { items[i] = items[i].copy(needsResend = true); persist() }
    }

    private fun clearNeedsResend(id: Long) {
        val i = items.indexOfFirst { it.id == id }
        if (i >= 0 && items[i].needsResend) { items[i] = items[i].copy(needsResend = false); persist() }
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
        if (i < 0 || items[i].state != UploadState.UPLOADED) return
        // Document pages stream to the Mac as shot, but their icons stay in the strip until "End segment"
        // (while they're still in the current, un-ended group) so the operator sees the segment growing.
        // Markers (complete 1-photo segments) leave as soon as they're confirmed.
        if (items[i].type == GroupType.DOCUMENT && items[i].groupId == currentGroupId) return
        runCatching { items[i].file.delete() }
        items.removeAt(i)
        if (selectedItemId == item.id) clearSelection()
        persist()
    }

    /** Reclassify the selected photo as a single-image box/folder marker (own group) and upload it. */
    fun reclassifySelected(type: GroupType) {
        val id = selectedItemId ?: return
        val i = items.indexOfFirst { it.id == id }
        if (i >= 0) {
            val oldGroupId = items[i].groupId
            // Build the full reclassify chain (SPEC A3): G→H→I carries "G,H" so the Mac tombstones
            // every prior group, not just the immediate predecessor. Append the old group to any
            // existing chain. Persisted on the item so retry/resume/autoRetry keep sending it.
            val chain = items[i].replacesGroupId?.let { "$it,$oldGroupId" } ?: oldGroupId
            val updated = items[i].copy(type = type, groupId = newGroupId(), priority = null,
                state = UploadState.PENDING, replacesGroupId = chain)
            items[i] = updated
            clearSelection()
            persist()
            // Parity with capturing a fresh Box/Folder marker (captureMarker flashes both): the reclassify
            // path was the silent one, so a re-tagged Box gave no confirmation. Display-only banner; the
            // upload/queue/protocol below is unchanged.
            flash(if (type == GroupType.BOX) "Box → Mac" else "Folder → Mac")
            // Tell the Mac to drop the old (oldGroupId, seq) copy if it already has it (idempotent no-op
            // otherwise). If the page's original upload is still in flight, defer via needsResend — the
            // in-flight guard would otherwise swallow this re-enqueue and the reclassify would never send.
            resendOrEnqueue(updated)
        }
    }

    // ---- Grouping / finalize ----

    /** Finish the current document segment → show its tag sheet, then start a fresh document segment. */
    fun finishDocumentSegment() {
        // Any doc page in the current group means there's a segment to tag — regardless of upload state.
        // (Pages stream as shot, so by End segment they're usually already UPLOADED; checking == PENDING
        // here would suppress the tag sheet once uploads finish and skip the segment-complete signal.)
        val hasDocs = items.any { it.groupId == currentGroupId && it.type == GroupType.DOCUMENT }
        if (hasDocs) { pendingTagGroupId = currentGroupId; persist() }
        else {
            // Feedback: tapping End segment with nothing captured yet was silent (looked broken). Tell the
            // operator instead of quietly rotating an empty group.
            statusMessage = "No pages in this segment yet — capture a page first."
            startNewGroup()
        }
    }

    /** Tag sheet → "Apply & continue" or "Skip" (Skip passes nulls): apply the optional pre-fill tags
     *  and end the current document segment. */
    fun applyTagsAndContinue(priority: String?, year: Int?, month: Int?) = finalizeSegment(priority, year, month)

    /** Tag sheet → "Cancel — keep shooting": the operator tapped End segment by mistake. Close the sheet
     *  WITHOUT ending the segment, so the current group stays open and further pages keep accumulating in
     *  the same document (nothing is sent, nothing is stranded). Gesture-dismiss of the sheet is disabled
     *  (see CaptureScreen), so this is only reached by the explicit Cancel button. */
    fun cancelTagSheet() {
        pendingTagGroupId = null
        persist()
    }

    /** End the current document segment. Its pages already streamed to the Mac; stamp the optional
     *  pre-fill tags (so any not-yet-uploaded page carries them), open the next segment, and record the
     *  segment as "ended, awaiting Mac ack". The completion signal — which is what makes the Mac present
     *  this segment's tag card — is then emitted once ALL its pages are confirmed uploaded (never for a
     *  partial segment), and retried until acked. */
    private fun finalizeSegment(priority: String?, year: Int?, month: Int?) {
        val gid = pendingTagGroupId ?: return
        pendingTagGroupId = null            // FIRST (mirrors iOS, where the sheet's dismiss-binding re-fires on nil)
        year?.let { prefs.noteYear(it) }
        val pages = items.count { it.groupId == gid && it.type == GroupType.DOCUMENT }
        for (i in items.indices) {
            val it = items[i]
            if (it.groupId == gid && it.type == GroupType.DOCUMENT) {
                // Stamp the segment's tags so any page not yet uploaded (captured offline) carries them
                // when it uploads; already-uploaded pages get the tags via the segment-complete signal.
                val stamped = it.copy(priority = it.priority ?: priority, year = year, month = month)
                items[i] = stamped
                if (stamped.state != UploadState.UPLOADED) enqueueUpload(stamped)
            }
        }
        startNewGroup()                     // gid is now finalized (differs from the new currentGroupId)
        endedSegments[gid] = SegTags(priority, year, month)
        persist()
        // Already-uploaded pages are done (bytes on the Mac; tags via the signal) → they leave the strip now.
        items.filter { it.groupId == gid && it.type == GroupType.DOCUMENT && it.state == UploadState.UPLOADED }
            .toList().forEach { removeConfirmed(it) }
        trySendSegmentComplete(gid)         // sends now iff all pages already uploaded; else deferred to upload/retry
        // Feedback (display only): a persistent status line + the transient banner so ending a segment is
        // never silent. This changes NOTHING about what End segment sends to the Mac (the completion signal
        // + tags above are untouched).
        statusMessage = "Segment ended · $pages page${if (pages == 1) "" else "s"}"
        if (pages > 0) flash("Segment → Mac · $pages page${if (pages == 1) "" else "s"}")
    }

    /** Emit a group's segment-complete signal — but ONLY once every page of that group is confirmed
     *  uploaded, so the Mac never completes a partial segment (a late page would otherwise be dropped from
     *  the segment's live output). If pages are still in flight this is a no-op; the upload-success path
     *  and the auto-retry loop call it again. Dropped from [endedSegments] only on a true ack. */
    private fun trySendSegmentComplete(group: String) {
        val tags = endedSegments[group] ?: return
        val c = client ?: return
        // Gate: any page of this group not yet UPLOADED (PENDING/UPLOADING/FAILED) → wait for it.
        if (items.any { it.groupId == group && it.state != UploadState.UPLOADED }) return
        if (!inFlightSegments.add(group)) return   // a send for this group is already running
        viewModelScope.launch {
            try {
                var ok = false; var attempt = 0
                while (!ok && attempt < 3) {
                    ok = withContext(Dispatchers.IO) { c.segmentComplete(group, tags.priority, tags.year, tags.month) }
                    attempt++
                }
                if (ok) { endedSegments.remove(group); persist() }
            } finally {
                inFlightSegments.remove(group)
            }
        }
    }

    /** Retry every ended-but-unacked segment (each still gated on all its pages being uploaded). */
    private fun resendEndedSegments() {
        if (client == null) return
        endedSegments.keys.toList().forEach { trySendSegmentComplete(it) }
    }

    /** Heartbeat the count of photos still IN FLIGHT to the Mac (PENDING/UPLOADING) so the Mac can surface
     *  "phone still has N photos to send" and hold Finish until they arrive — reaching 0 once they settle.
     *  FAILED pages are deliberately EXCLUDED: they need a manual Retry and won't arrive on their own, so
     *  they must not block Finish forever (the operator sees + retries them in the phone's strip). */
    private fun sendStatusReport() {
        val c = client ?: return
        val pending = items.count { it.state == UploadState.PENDING || it.state == UploadState.UPLOADING }
        viewModelScope.launch { withContext(Dispatchers.IO) { runCatching { c.reportStatus(pending) } } }
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

    private fun enqueueUpload(item: CapturedItem) {
        val c = client ?: return
        if (!inFlightUploads.add(item.id)) return   // already uploading this id — don't double-send
        // Durable on the item, so retry / resume / autoRetry keep sending X-Replaces until it lands.
        val replaces = item.replacesGroupId
        setState(item.id, UploadState.UPLOADING)
        sendStatusReport()   // reflect a just-captured/enqueued page on the Mac immediately (not only every 8s)
        viewModelScope.launch {
            var resendItem: CapturedItem? = null
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
                    // A field changed while this upload was in flight (per-page P10 / reclassify): the bytes
                    // just sent are stale. Re-send with the CURRENT fields instead of confirming — do NOT
                    // removeConfirmed (that would drop the photo having sent only the old value). The
                    // re-enqueue runs AFTER finally releases the in-flight guard so enqueueUpload can re-add
                    // the ID (previously it launched inside try, where inFlightUploads still held the old ID,
                    // causing the re-enqueue to silently no-op).
                    val cur = items.firstOrNull { it.id == item.id }
                    if (cur != null && cur.needsResend) {
                        clearNeedsResend(item.id)
                        resendItem = items.firstOrNull { it.id == item.id }
                    } else {
                        // Confirmed durably on the Mac → drop it from the phone shortly after (the brief delay
                        // lets the strip animate it out), so photos transfer in segments instead of piling up.
                        viewModelScope.launch { delay(650); removeConfirmed(item) }
                        // If this was the last outstanding page of an ended segment, its completion signal was
                        // gated waiting for this upload — try it now (no-op if other pages are still in flight).
                        if (endedSegments.containsKey(item.groupId)) trySendSegmentComplete(item.groupId)
                    }
                }
                statusMessage = uploadSummary()
                sendStatusReport()   // reflect the new un-sent count promptly (this upload just settled)
            } finally {
                inFlightUploads.remove(item.id)
            }
            resendItem?.let { enqueueUpload(it) }
        }
    }

    fun retryFailed() {
        items.filter { it.state == UploadState.FAILED }.forEach { enqueueUpload(it) }
    }

    /** Backup: copy every photo still on the phone into the shared gallery (Pictures/Archive Capture), so
     *  the operator can retrieve the originals if they won't transfer to the Mac. Independent of the
     *  transfer queue — these copies survive Clear and a failed session. (On API ≤28 the caller must have
     *  obtained WRITE_EXTERNAL_STORAGE first; on API 29+ no permission is needed.) */
    fun saveToPhone() {
        val app = getApplication<Application>()
        val toSave = items.toList()
        if (toSave.isEmpty()) { statusMessage = "No photos to save"; return }
        statusMessage = "Saving ${toSave.size} photo(s) to your gallery…"
        viewModelScope.launch {
            // Save off-main; collect which items landed in the gallery.
            val savedIds = withContext(Dispatchers.IO) {
                toSave.filter { PhoneBackup.saveJpegToGallery(app, it.file) }.map { it.id }.toHashSet()
            }
            // DISPLAY-ONLY: flag saved thumbnails so they read as "safe on phone", not "failed". This does
            // NOT touch upload state / the queue / dedup — a saved page still uploads (or retries) exactly
            // as before; only the thumbnail's indicator changes.
            var changed = false
            savedIds.forEach { id ->
                val i = items.indexOfFirst { it.id == id }
                if (i >= 0 && !items[i].savedToPhone) { items[i] = items[i].copy(savedToPhone = true); changed = true }
            }
            if (changed) persist()
            val saved = savedIds.size
            statusMessage = if (saved == toSave.size) "Saved $saved photo(s) to your gallery (Pictures/Archive Capture)"
                            else "Saved $saved of ${toSave.size} — some couldn't be written to the gallery"
            flash("Saved $saved to gallery")
        }
    }

    /** Delete every captured photo (files + persisted session) and start a clean session. */
    fun clearSession() {
        for (item in items) { runCatching { item.file.delete() } }
        items.clear()
        endedSegments.clear()
        inFlightSegments.clear()
        inFlightUploads.clear()
        seqCounter = 0
        nextId = 1L
        currentGroupId = newGroupId()
        pendingTagGroupId = null
        clearSelection()
        sentCount = 0
        transferFlash = null
        statusMessage = ""
        viewModelScope.launch(Dispatchers.IO) { store.clear() }
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

    override fun onCleared() {
        driveAuth.dispose()   // release AppAuth's Custom Tabs service binding
        super.onCleared()
    }
}
