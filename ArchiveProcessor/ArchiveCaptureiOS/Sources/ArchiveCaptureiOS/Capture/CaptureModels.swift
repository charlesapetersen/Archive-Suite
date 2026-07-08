import Foundation

/// Mirrors the Mac's CaptureGroupType (X-Type wire values) and the Android GroupType.
enum GroupType: String, Codable { case document, box, folder }

enum UploadState: String, Codable { case pending, uploading, uploaded, failed }

/// One captured photo: its group, sequence, minimal tags, and upload status.
struct CapturedItem: Identifiable, Codable, Equatable {
    let id: Int64
    let fileURL: URL
    var groupId: String   // mutable: a photo can be reclassified into its own box/folder group
    let seq: Int
    var type: GroupType
    var priority: String? = nil
    var year: Int? = nil
    var month: Int? = nil
    var state: UploadState = .pending
    // When this photo was reclassified into a new group, the group whose (oldGroup, seq) copy the Mac
    // should drop (X-Replaces). Stored on the item so EVERY retry/resume re-sends it until it lands —
    // not just the first attempt — otherwise a failed first upload leaves a stray copy on the Mac.
    var replacesGroupId: String? = nil
    // A field changed (per-page P10 toggle, or a reclassify) WHILE this item's upload was in flight, so the
    // bytes/headers already sent are stale. The upload-completion handler honors this by re-sending with the
    // current fields once the in-flight upload settles — otherwise the change is silently dropped (the
    // in-flight guard suppressed the re-enqueue). Optional so a snapshot written before this field still
    // decodes (missing → nil, treated as false) — a decode failure would strand un-uploaded photos.
    var needsResend: Bool? = nil
}
