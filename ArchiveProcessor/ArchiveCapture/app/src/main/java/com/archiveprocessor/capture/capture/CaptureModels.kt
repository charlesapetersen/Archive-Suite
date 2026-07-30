package com.archiveprocessor.capture.capture

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.withContext
import java.io.File

/** Mirrors the Mac's CaptureGroupType (X-Type wire values). */
enum class GroupType(val wire: String) { DOCUMENT("document"), BOX("box"), FOLDER("folder") }

enum class UploadState { PENDING, UPLOADING, UPLOADED, FAILED }

/** True while this photo exists ONLY on the phone: the Mac either hasn't confirmed it, or has confirmed
 *  bytes that a pending metadata resend has since made stale. Deleting such a page locally is
 *  irrecoverable — an archival photo can't be re-taken — so the delete gesture must confirm first. Same
 *  predicate as the un-sent heartbeat below, deliberately: "the Mac still needs this" and "losing this
 *  loses it forever" are the same condition. */
internal fun requiresDeleteConfirmation(item: CapturedItem): Boolean =
    item.state != UploadState.UPLOADED || item.needsResend

/** Count pages the Mac must still expect. FAILED is included because the background retry loop sends it
 * automatically; reporting zero while such a page exists can let the Mac finish a session too early. */
internal fun pendingReportCount(items: Iterable<CapturedItem>): Int =
    items.count { requiresDeleteConfirmation(it) }

/** What a confirmed delete actually did to the local file. */
internal enum class DeleteOutcome {
    /** Copied into the phone's shared gallery, then removed from the queue — recoverable. */
    RETIRED_TO_GALLERY,
    /** Removed outright (the operator chose "Delete permanently", or the Mac already has it). */
    DELETED,
    /** The gallery copy failed, so the photo was KEPT. Never delete the only copy of an un-sent page. */
    KEPT_RETIRE_FAILED
}

/** Retire one capture's local file. When [retire] is supplied (the operator chose the recoverable
 *  "Save to gallery & delete" action) the file is removed ONLY after that copy is confirmed written —
 *  a failed copy keeps the photo, because an un-uploaded page has no other copy anywhere. */
internal fun retireCaptureFile(file: File, retire: ((File) -> Boolean)?): DeleteOutcome {
    if (retire != null) {
        if (!retire(file)) return DeleteOutcome.KEPT_RETIRE_FAILED
        runCatching { file.delete() }
        return DeleteOutcome.RETIRED_TO_GALLERY
    }
    runCatching { file.delete() }
    return DeleteOutcome.DELETED
}

/** Delete a capture safely: cancel its upload and WAIT for that coroutine to finish BEFORE the bytes go
 *  away. The upload opens the file itself, so a delete that wins that race leaves the page nowhere — not
 *  on the phone, not on the Mac. Joining first means the upload either completed (bytes are on the Mac)
 *  or unwound while the file was still readable; either way the loss is a decision, not a race. */
internal suspend fun retireCapture(
    uploadJob: Job?,
    file: File,
    retire: ((File) -> Boolean)?
): DeleteOutcome {
    uploadJob?.cancelAndJoin()
    return withContext(Dispatchers.IO) { retireCaptureFile(file, retire) }
}

/** Which Mac owns an in-flight send (W23.m1). Pairing to a Mac — or unpairing from one — rotates the
 *  generation, so a send stamped with an earlier generation is recognizable as belonging to an endpoint
 *  that is no longer the destination. Main-thread confined, exactly like the queue state it describes. */
internal class PairingGeneration {
    var current: Long = 0L
        private set

    /** A newly paired endpoint, or an unpair. Nothing queued for the previous endpoint may confirm
     *  itself afterwards: the acknowledgement would come from a Mac that is no longer receiving. */
    fun rotate(): Long {
        current += 1
        return current
    }

    fun isCurrent(token: Long): Boolean = token == current
}

/** The sends outstanding right now, each stamped with the pairing generation that started it — keyed by
 *  photo id for uploads, by group id for segment-completion signals. Main-thread confined. */
internal class OutstandingSends<K> {
    private val tokens = mutableMapOf<K, Long>()

    /** Claim the right to send [key]. Refused while ANY send for that key is outstanding, including one
     *  belonging to a retired pairing: two coroutines must never hold the same photo file at once (the
     *  invariant the delete join in [retireCapture] depends on). The retired send releases its own claim
     *  as it unwinds, which is what re-opens the key for the current endpoint. */
    fun claim(key: K, generation: Long): Boolean {
        if (tokens.containsKey(key)) return false
        tokens[key] = generation
        return true
    }

    /** Release only OUR claim. A send from a retired pairing must never free the guard the current
     *  endpoint's send is holding — that would let a second coroutine send (and then delete) the page. */
    fun release(key: K, generation: Long): Boolean {
        if (tokens[key] != generation) return false
        tokens.remove(key)
        return true
    }

    fun contains(key: K): Boolean = tokens.containsKey(key)

    fun clear() = tokens.clear()
}

/** What a send's outcome is allowed to do, once endpoint ownership is taken into account. */
internal enum class SendAck {
    /** The Mac that answered is still the paired one and took it → record it as delivered. */
    CONFIRM,
    /** The answer came from a pairing we have since left. The Mac paired NOW never received this, so it
     *  must not be recorded as delivered (a delivered page is one the phone is allowed to delete) —
     *  it goes back in the queue for the current endpoint instead. */
    REQUEUE_STALE,
    /** Current endpoint, but the send did not land → leave it failed for the auto-retry loop. */
    RETRY
}

/** The endpoint-ownership rule, in one place, for BOTH kinds of send (a photo upload and a segment's
 *  completion signal). Staleness outranks success deliberately: a success reported by a Mac we are no
 *  longer paired with is precisely the misroute — confirming it would mark a page uploaded, and thus
 *  deletable from the phone, when the Mac that is actually paired never received it. */
internal fun sendAck(ok: Boolean, tokenIsCurrent: Boolean): SendAck = when {
    !tokenIsCurrent -> SendAck.REQUEUE_STALE
    ok -> SendAck.CONFIRM
    else -> SendAck.RETRY
}

/** Atomically expose a deferred metadata resend as pending before the next drain heartbeat is emitted. */
internal fun CapturedItem.prepareDeferredResend(): CapturedItem =
    copy(state = UploadState.PENDING, needsResend = false)

/** A persisted resend marker is authoritative across a crash, even if an earlier save recorded UPLOADED. */
internal fun CapturedItem.normalizeForRestore(): CapturedItem =
    if (needsResend) prepareDeferredResend() else this

/** Camera callbacks are asynchronous. A token captured at shutter time is valid only for that session. */
internal fun captureStartToken(generation: Long, isClearing: Boolean): Long? =
    generation.takeUnless { isClearing }

internal fun captureTokenIsCurrent(token: Long, generation: Long, isClearing: Boolean): Boolean =
    !isClearing && token == generation

/** One captured photo: its group, sequence, minimal tags, and upload status. Immutable — replace
 *  the element in the state list to update (so Compose recomposes). */
data class CapturedItem(
    val id: Long,
    val file: File,
    val groupId: String,
    val seq: Int,
    val type: GroupType,
    val priority: String? = null,   // per-page P10 override, or the segment default at finalize
    val year: Int? = null,
    val month: Int? = null,
    val state: UploadState = UploadState.PENDING,
    // The full comma-joined reclassify chain (SPEC A3): if a page goes G→H→I, this is "G,H" so the
    // Mac tombstones every prior group. Stored on the item so EVERY retry/resume re-sends it until it
    // lands — not just the first attempt — otherwise a failed first upload leaves a stray old copy.
    val replacesGroupId: String? = null,
    // A field changed (per-page P10 toggle, or a reclassify) WHILE this item's upload was in flight, so the
    // bytes/headers already sent are stale. The upload-completion handler honors this by re-sending with the
    // current fields once the in-flight upload settles — otherwise the change is silently dropped (the
    // in-flight guard suppressed the re-enqueue). Persisted so the intent survives an app kill. Mirrors iOS.
    val needsResend: Boolean = false,
    // DISPLAY-ONLY: this photo has been copied to the phone's gallery via "Save to phone". Purely a UI cue
    // (so a saved photo's thumbnail no longer reads as "failed"); it does NOT affect the upload/queue/dedup
    // state or the phone↔Mac protocol in any way.
    val savedToPhone: Boolean = false
)
