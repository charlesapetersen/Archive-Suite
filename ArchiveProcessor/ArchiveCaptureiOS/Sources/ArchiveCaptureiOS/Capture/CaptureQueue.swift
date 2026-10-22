import Foundation

/// The capture session's queue and bookkeeping, kept free of UIKit, AVFoundation, Photos and of all I/O so it
/// compiles and runs on the Mac host with plain `swiftc` (`scripts/test-ios-capture-queue.sh`). The iOS companion
/// has no test target and no simulator runtime to host one (W40.i-fix-ios-testable-core), so this is where its
/// queue, restore and heartbeat logic gets tested.
///
/// `CaptureViewModel` owns one of these and does every side effect itself: deleting photo files, persisting the
/// snapshot, starting uploads and segment signals. Methods that drop items RETURN them so the caller can delete
/// their files; methods that change state the caller must persist return whether they did.
struct CaptureQueue {
    /// The tags a document segment was ended with, sent with its segment-complete signal.
    struct SegTags: Equatable { let quality: String?; let year: Int?; let month: Int?; let seqs: String? }

    /// What ending a segment produced, for the caller to act on.
    struct SegmentEnd {
        let group: String
        let pages: Int
        /// Pages not yet uploaded, now stamped with the segment's tags: (re)send them.
        let toUpload: [CapturedItem]
        /// Pages already confirmed on the Mac: they may leave the strip now.
        let confirmed: [CapturedItem]
    }

    private(set) var items: [CapturedItem] = []
    private(set) var seqCounter = 0
    /// Never reset, not even by Clear, so an id names one photo for the life of the process: a late reply or a
    /// delayed removal from a cleared session can never match a new photo (W40.i-fix-ios-clear-generation).
    private(set) var nextId: Int64 = 1
    /// Bumped by every Clear. A send captures it when it starts and records nothing once it has moved on, so a
    /// reply that outlives Clear cannot touch the new session. Process-local: no send outlives the process, so
    /// it is not persisted. Mirrors Android's `sessionGeneration`.
    private(set) var generation = 0
    private(set) var currentGroupId: String
    /// Non-nil while the tag sheet is open for that group.
    var pendingTagGroupId: String?
    /// Document segments ended (End segment → Apply/Skip) whose segment-complete signal the Mac hasn't acked.
    private(set) var endedSegments: [String: SegTags] = [:]
    /// Ids uploading right now, so auto-retry, resume and a manual Retry can't send the same item twice at once.
    private(set) var inFlightUploads = Set<Int64>()
    /// Groups whose completion signal is being sent right now.
    private(set) var inFlightSegments = Set<String>()

    private let newGroupId: () -> String

    init(newGroupId: @escaping () -> String = CaptureQueue.randomGroupId) {
        self.newGroupId = newGroupId
        currentGroupId = newGroupId()
    }

    static func randomGroupId() -> String { "g" + UUID().uuidString.prefix(8) }

    func item(_ id: Int64) -> CapturedItem? { items.first { $0.id == id } }

    /// True while no Clear has happened since a send captured `generation`.
    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    // MARK: - Capture

    /// Main shutter: a page of the current document segment.
    mutating func addDocument(fileURL: URL) -> CapturedItem {
        seqCounter += 1
        let item = CapturedItem(id: nextId, fileURL: fileURL, groupId: currentGroupId, seq: seqCounter, type: .document)
        items.append(item)
        nextId += 1
        return item
    }

    /// Box/Folder: a single-image marker in its own group.
    mutating func addMarker(fileURL: URL, type: GroupType) -> CapturedItem {
        seqCounter += 1
        let item = CapturedItem(id: nextId, fileURL: fileURL, groupId: newGroupId(), seq: seqCounter, type: type)
        nextId += 1
        items.append(item)
        return item
    }

    func documentPageCount(group: String) -> Int {
        items.filter { $0.groupId == group && $0.type == .document }.count
    }

    /// Toggle a per-page Q3 override; returns the updated item.
    mutating func toggleQ3(_ id: Int64) -> CapturedItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[i].quality = (items[i].quality == "Q3") ? nil : "Q3"
        return items[i]
    }

    /// Reclassify a photo as a single-image box/folder marker in a new group; returns the updated item.
    mutating func reclassify(_ id: Int64, to type: GroupType) -> CapturedItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        let oldGroupId = items[i].groupId
        items[i].type = type
        items[i].groupId = newGroupId()
        items[i].quality = nil
        items[i].state = .pending
        // Build the full reclassify chain (SPEC A3): G→H→I carries "G,H" so the Mac tombstones every
        // prior group, not just the immediate predecessor. Append the old group to any existing chain.
        if let existing = items[i].replacesGroupId {
            items[i].replacesGroupId = "\(existing),\(oldGroupId)"
        } else {
            items[i].replacesGroupId = oldGroupId
        }
        return items[i]
    }

    /// Remove an item outright (the operator deleted it); returns it so the caller can delete its file.
    mutating func remove(_ id: Int64) -> CapturedItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    /// Flag an item whose fields changed while its upload was in flight. Returns true if the flag changed.
    mutating func markNeedsResend(_ id: Int64) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].needsResend != true else { return false }
        items[i].needsResend = true
        return true
    }

    /// Returns true if the flag changed.
    mutating func clearNeedsResend(_ id: Int64) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].needsResend == true else { return false }
        items[i].needsResend = false
        return true
    }

    /// Returns true if an item with that id exists (and so changed).
    @discardableResult
    mutating func setState(_ id: Int64, _ state: UploadState) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        items[i].state = state
        return true
    }

    // MARK: - Segments

    mutating func startNewGroup() { currentGroupId = newGroupId() }

    /// End the segment whose tag sheet is open, stamping its pages with the tags, opening the next segment and
    /// recording the segment as ended-awaiting-ack. Nil if no tag sheet is open.
    mutating func endSegment(quality: String?, year: Int?, month: Int?) -> SegmentEnd? {
        guard let gid = pendingTagGroupId else { return nil }
        pendingTagGroupId = nil
        var toUpload: [CapturedItem] = []
        for i in items.indices where items[i].groupId == gid && items[i].type == .document {
            // Stamp the segment's tags so any page not yet uploaded (captured offline) carries them when it
            // uploads; already-uploaded pages get the tags via the segment-complete signal.
            items[i].quality = items[i].quality ?? quality
            items[i].year = year
            items[i].month = month
            if items[i].state != .uploaded { toUpload.append(items[i]) }
        }
        startNewGroup()                                    // gid is now finalized (differs from currentGroupId)
        let pages = items.filter { $0.groupId == gid && $0.type == .document }
        // SPEC A5: snapshot page seqs at End-segment so the Mac can verify all pages arrived.
        let seqs = pages.map { String($0.seq) }.joined(separator: ",")
        endedSegments[gid] = SegTags(quality: quality, year: year, month: month, seqs: seqs.isEmpty ? nil : seqs)
        return SegmentEnd(group: gid, pages: pages.count, toUpload: toUpload,
                          confirmed: pages.filter { $0.state == .uploaded })
    }

    /// The tags to send for an ended segment — but only once every page of that group is confirmed uploaded, so
    /// the Mac never completes a partial segment. Nil while any page is pending, uploading or failed.
    func readySegment(_ group: String) -> SegTags? {
        guard let tags = endedSegments[group] else { return nil }
        if items.contains(where: { $0.groupId == group && $0.state != .uploaded }) { return nil }
        return tags
    }

    /// The Mac acked the group's segment-complete signal.
    mutating func acknowledgeSegment(_ group: String) { endedSegments[group] = nil }

    // MARK: - In-flight guards

    /// Returns false if the id is already uploading.
    mutating func beginUpload(_ id: Int64) -> Bool { inFlightUploads.insert(id).inserted }
    mutating func endUpload(_ id: Int64) { inFlightUploads.remove(id) }
    func isUploading(_ id: Int64) -> Bool { inFlightUploads.contains(id) }

    /// Returns false if a signal for the group is already being sent.
    mutating func beginSegmentSend(_ group: String) -> Bool { inFlightSegments.insert(group).inserted }
    mutating func endSegmentSend(_ group: String) { inFlightSegments.remove(group) }

    // MARK: - Counts and filters

    /// The count heartbeated to the Mac as "phone still has N photos to send": pending and uploading pages.
    /// FAILED pages are deliberately EXCLUDED: they need a manual Retry and won't arrive on their own, so
    /// they must not block Finish forever (the operator sees + retries them in the phone's strip).
    var heartbeatCount: Int { items.filter { $0.state == .pending || $0.state == .uploading }.count }

    /// Everything not confirmed on the Mac, re-sent on (re)connect.
    var resumeCandidates: [CapturedItem] { items.filter { $0.state != .uploaded } }

    /// What the auto-retry loop flushes: failed uploads and any still-PENDING page.
    var autoRetryCandidates: [CapturedItem] { items.filter { $0.state == .failed || $0.state == .pending } }

    var failedItems: [CapturedItem] { items.filter { $0.state == .failed } }

    var uploadSummary: String {
        let failed = items.filter { $0.state == .failed }.count
        let inflight = items.filter { $0.state == .pending || $0.state == .uploading }.count
        var parts: [String] = []
        if inflight > 0 { parts.append("\(inflight) queued") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Removal, clear, restore

    /// A photo confirmed by the Mac is durably safe there, so it leaves the phone. Guarded by identity + state (ids
    /// are never reused, and the file must match too) so a stale timer can't remove another photo. Document pages of the current,
    /// un-ended segment stay so the operator sees the segment grow. Returns the removed item, or nil.
    mutating func removeConfirmed(_ item: CapturedItem) -> CapturedItem? {
        guard let i = items.firstIndex(where: { $0.id == item.id && $0.fileURL == item.fileURL }),
              items[i].state == .uploaded else { return nil }
        if items[i].type == .document && items[i].groupId == currentGroupId { return nil }
        return items.remove(at: i)
    }

    /// Start clean. Returns every item so the caller can delete its file. Moves the generation on and keeps
    /// `nextId` running (it used to restart at 1, so a reply to an upload still running marked the new photo
    /// with the same id as sent: it was never sent, and the next restore deleted it). Seqs restart, which is safe
    /// because the new session's groups are fresh ids, so (group, seq) on the Mac stays unique.
    mutating func clear() -> [CapturedItem] {
        let removed = items
        generation += 1
        items.removeAll()
        inFlightUploads.removeAll()   // the old sends are stale now; their ids can never come back
        endedSegments.removeAll()
        inFlightSegments.removeAll()
        seqCounter = 0
        currentGroupId = newGroupId()
        pendingTagGroupId = nil
        return removed
    }

    /// What restoring a persisted session left for the caller.
    struct Restored {
        /// Confirmed on the Mac before the app stopped: the caller deletes their files.
        let dropped: [CapturedItem]
        /// Listed in the session but their photo is gone from disk: nothing to send, so skipped. The caller
        /// tells the operator, since these pages never reached the Mac.
        let missing: [CapturedItem]
    }

    /// Load a persisted session. Items whose photo file is gone are skipped and reported (as Android's
    /// SessionStore does). A page with a resend pending is restored as pending, even if a save recorded it
    /// uploaded: the Mac holds only its stale fields (Android's normalizeForRestore). Items confirmed on the Mac
    /// are dropped — EXCEPT document pages of the current, un-ended segment, which aren't tagged yet. The tag
    /// sheet re-opens only if the app stopped mid-tagging a group that still has document pages.
    mutating func restore(_ snap: SessionStore.Snapshot, fileExists: (CapturedItem) -> Bool) -> Restored {
        let missing = snap.items.filter { !fileExists($0) }
        items = snap.items.filter(fileExists).map { item in
            var item = item
            if item.needsResend == true { item.state = .pending; item.needsResend = nil }
            return item
        }
        seqCounter = snap.seq
        nextId = snap.nextId
        if let g = snap.groupId { currentGroupId = g }
        for e in snap.endedSegments ?? [] {
            endedSegments[e.group] = SegTags(quality: e.quality, year: e.year, month: e.month, seqs: e.seqs)
        }
        let keep: (CapturedItem) -> Bool = { [currentGroupId] in
            !($0.state == .uploaded && !($0.type == .document && $0.groupId == currentGroupId))
        }
        let dropped = items.filter { !keep($0) }
        items.removeAll { !keep($0) }
        if let taggingGroup = snap.pendingTagGroupId,
           items.contains(where: { $0.groupId == taggingGroup && $0.type == .document }) {
            currentGroupId = taggingGroup
            pendingTagGroupId = taggingGroup
        }
        return Restored(dropped: dropped, missing: missing)
    }

    func snapshot() -> SessionStore.Snapshot {
        let ended = endedSegments.map { SessionStore.EndedSeg(group: $0.key, quality: $0.value.quality,
                                                              year: $0.value.year, month: $0.value.month, seqs: $0.value.seqs) }
        return .init(items: items, seq: seqCounter, nextId: nextId, groupId: currentGroupId,
                     pendingTagGroupId: pendingTagGroupId, endedSegments: ended)
    }
}
