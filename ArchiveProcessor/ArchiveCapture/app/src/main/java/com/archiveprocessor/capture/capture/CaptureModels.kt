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
    val replacesGroupId: String? = null
)
