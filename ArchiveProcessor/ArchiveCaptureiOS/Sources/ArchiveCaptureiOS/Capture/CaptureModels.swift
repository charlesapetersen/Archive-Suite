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
    var quality: String? = nil
    var year: Int? = nil
    var month: Int? = nil
    var state: UploadState = .pending
    // The full comma-joined reclassify chain (SPEC A3): if a page goes G→H→I, this is "G,H" so the
    // Mac tombstones every prior group. Stored on the item so EVERY retry/resume re-sends it until it
    // lands — not just the first attempt — otherwise a failed first upload leaves a stray copy on the Mac.
    var replacesGroupId: String? = nil
    // A field changed (per-page Q3 toggle, or a reclassify) WHILE this item's upload was in flight, so the
    // bytes/headers already sent are stale. The upload-completion handler honors this by re-sending with the
    // current fields once the in-flight upload settles — otherwise the change is silently dropped (the
    // in-flight guard suppressed the re-enqueue).
    var needsResend: Bool? = nil
    // W23.m8's port (W40.i-fix-ios-session-durability): recovered from disk against a session file known to be
    // older than the state that produced it, so the box/folder, group boundary and tags this page carried are
    // gone. HELD on the phone (never sent) until the operator says what it is, and persisted, so a further kill
    // can't release it to the Mac under a classification nobody chose. Mirrors Android's `needsReview`.
    var needsReview: Bool? = nil
    // Display only: copied to the Photos library by Save to phone, so the thumbnail reads as safe, not failed. It
    // changes nothing about upload state, the queue or the phone↔Mac protocol. Mirrors Android's `savedToPhone`.
    var savedToPhone: Bool? = nil
}

extension CapturedItem {
    /// The decoder's photo directory: a persisted item stores only its file NAME, resolved against this on load.
    /// The app container's absolute path changes on reinstall (a free-account install is reinstalled every
    /// seven days), so a stored absolute path would point at nothing (W40.i-fix-ios-photo-storage).
    static let photoDirectoryKey = CodingUserInfoKey(rawValue: "capturePhotoDirectory")!

    private enum CodingKeys: String, CodingKey {
        case id, fileName, groupId, seq, type, quality, year, month, state, replacesGroupId, needsResend, needsReview, savedToPhone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let dir = decoder.userInfo[Self.photoDirectoryKey] as? URL else {
            throw DecodingError.dataCorruptedError(forKey: .fileName, in: c, debugDescription: "no photo directory")
        }
        let name = try c.decode(String.self, forKey: .fileName)
        // A bare name only: anything with a path separator can't be a file this app wrote.
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw DecodingError.dataCorruptedError(forKey: .fileName, in: c, debugDescription: "not a file name")
        }
        self.init(id: try c.decode(Int64.self, forKey: .id),
                  fileURL: dir.appendingPathComponent(name, isDirectory: false),
                  groupId: try c.decode(String.self, forKey: .groupId),
                  seq: try c.decode(Int.self, forKey: .seq),
                  type: try c.decode(GroupType.self, forKey: .type),
                  quality: try c.decodeIfPresent(String.self, forKey: .quality),
                  year: try c.decodeIfPresent(Int.self, forKey: .year),
                  month: try c.decodeIfPresent(Int.self, forKey: .month),
                  state: try c.decode(UploadState.self, forKey: .state),
                  replacesGroupId: try c.decodeIfPresent(String.self, forKey: .replacesGroupId),
                  needsResend: try c.decodeIfPresent(Bool.self, forKey: .needsResend),
                  needsReview: try c.decodeIfPresent(Bool.self, forKey: .needsReview),
                  savedToPhone: try c.decodeIfPresent(Bool.self, forKey: .savedToPhone))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fileURL.lastPathComponent, forKey: .fileName)
        try c.encode(groupId, forKey: .groupId)
        try c.encode(seq, forKey: .seq)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(quality, forKey: .quality)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(month, forKey: .month)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(replacesGroupId, forKey: .replacesGroupId)
        try c.encodeIfPresent(needsResend, forKey: .needsResend)
        try c.encodeIfPresent(needsReview, forKey: .needsReview)
        try c.encodeIfPresent(savedToPhone, forKey: .savedToPhone)
    }
}
