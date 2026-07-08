package com.archiveprocessor.capture.capture

import java.io.File

/** Mirrors the Mac's CaptureGroupType (X-Type wire values). */
enum class GroupType(val wire: String) { DOCUMENT("document"), BOX("box"), FOLDER("folder") }

enum class UploadState { PENDING, UPLOADING, UPLOADED, FAILED }

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
    // When this photo was reclassified into a new group, the old group whose (oldGroup, seq) copy the
    // Mac should drop (X-Replaces). Stored on the item so EVERY retry/resume re-sends it until it lands —
    // not just the first attempt — otherwise a failed first upload leaves a stray old copy. Mirrors iOS.
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
