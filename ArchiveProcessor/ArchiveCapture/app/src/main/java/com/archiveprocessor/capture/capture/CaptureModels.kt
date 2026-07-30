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
