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
    /// Which Mac owns a send (W23.m1's port, W40.i-fix-ios-pairing-generation). Pairing to a Mac, or unpairing from
    /// one, moves it on, so a reply to a send stamped with an earlier pairing came from a Mac that is no longer the
    /// destination: it must not mark the page delivered, which would let the phone delete its only copy. Process-
    /// local, like `generation`. Mirrors Android's `PairingGeneration`.
    private(set) var pairing = 0
    private(set) var currentGroupId: String
    /// Non-nil while the tag sheet is open for that group.
    var pendingTagGroupId: String?
    /// Document segments ended (End segment → Apply/Skip) whose segment-complete signal the Mac hasn't acked.
    private(set) var endedSegments: [String: SegTags] = [:]
    /// Ids uploading right now, so auto-retry, resume and a manual Retry can't send the same item twice at once,
    /// each with the pairing that started it. A send from a retired pairing keeps its claim until it unwinds (only
    /// one task ever holds a photo), and can release only its own (Android's `OutstandingSends`).
    private(set) var inFlightUploads: [Int64: Int] = [:]
    /// Groups whose completion signal is being sent right now, with the pairing that started each.
    private(set) var inFlightSegments: [String: Int] = [:]

    private let newGroupId: () -> String

    init(newGroupId: @escaping () -> String = CaptureQueue.randomGroupId) {
        self.newGroupId = newGroupId
        currentGroupId = newGroupId()
    }

    static func randomGroupId() -> String { "g" + UUID().uuidString.prefix(8) }

    func item(_ id: Int64) -> CapturedItem? { items.first { $0.id == id } }

    /// True while no Clear has happened since a send captured `generation`.
    func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// True while the phone is still paired to the Mac a send stamped with `pairing` was started for.
    func isCurrentPairing(_ pairing: Int) -> Bool { pairing == self.pairing }

    /// A newly paired Mac, or an unpair: nothing sent to the previous one may confirm itself from here on.
    mutating func rotatePairing() { pairing += 1 }

    /// What a send's reply may do, once the pairing it was sent under is taken into account.
    enum SendAck: Equatable {
        /// The Mac that answered is still the paired one and took it: record it delivered.
        case confirm
        /// The reply came from a pairing since left. The Mac paired now never received it, so it goes back in
        /// the queue for that Mac instead of being recorded delivered.
        case requeueStale
        /// Still paired, but the send did not land: leave it for the retry loop.
        case retry
    }

    /// The ownership rule for both kinds of send. Staleness outranks success on purpose: a success from a Mac the
    /// phone has unpaired from is exactly the misroute. Mirrors Android's `sendAck`.
    static func sendAck(ok: Bool, pairingIsCurrent: Bool) -> SendAck {
        if !pairingIsCurrent { return .requeueStale }
        return ok ? .confirm : .retry
    }

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
        // Choosing Box or Folder IS the classification a held recovered page was waiting for, so the hold lifts
        // (W40.i-fix-ios-session-durability). Kept, it would strand the page: Review ends a document segment, and
        // a marker is not a document page.
        items[i].needsReview = nil
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

    // MARK: - Delete (W40.i-fix-ios-delete-confirm, Android's W23.h4)

    /// Whether deleting this page must ask first: it exists only on the phone, because the Mac has not confirmed it
    /// or holds bytes a pending resend has made stale. An archival photo can't be retaken. The same predicate as
    /// the heartbeat, deliberately: "the Mac still needs this" and "losing this loses it forever" are one condition.
    /// It used to be `state != .uploaded` alone, so a page with a resend pending was deleted unasked.
    static func requiresDeleteConfirmation(_ item: CapturedItem) -> Bool { macStillNeeds(item) }

    /// Ids whose delete is running: its upload being stopped, or its copy to Photos being written. While an id is
    /// here no new send of it starts and a confirmed upload does not remove it, so the file the delete is copying
    /// stays put. Process-local, and emptied by Clear.
    private(set) var deleting: Set<Int64> = []

    /// Claims the id for a delete. False if it is gone or a delete of it is already running (a fast re-tap).
    mutating func beginDelete(_ id: Int64) -> Bool { item(id) != nil && deleting.insert(id).inserted }
    mutating func endDelete(_ id: Int64) { deleting.remove(id) }
    func isDeleting(_ id: Int64) -> Bool { deleting.contains(id) }

    /// Drop a page whose delete went through. Guarded by identity (id and file) like `removeConfirmed`, so it can
    /// never evict a different photo. Returns it so the caller can delete its file.
    mutating func removeDeleted(_ item: CapturedItem) -> CapturedItem? {
        guard let i = items.firstIndex(where: { $0.id == item.id && $0.fileURL == item.fileURL }) else { return nil }
        return items.remove(at: i)
    }

    /// A delete that kept the photo (its copy to Photos failed) had still stopped its upload. If the Mac still needs
    /// the page, put it back in the queue with any deferred resend folded in, and return it to send; nil if the
    /// upload landed before the cancel did, so the Mac already has it.
    mutating func requeueAfterKeptDelete(_ id: Int64) -> CapturedItem? {
        guard let page = item(id), Self.macStillNeeds(page) else { return nil }
        return prepareDeferredResend(id)
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
            // W23.m8's port: the one place a recovery hold lifts. The operator has now said what these pages
            // are, so they become sendable with the tags just supplied (Skip included: a deliberate choice).
            items[i].needsReview = nil
            if items[i].state != .uploaded { toUpload.append(items[i]) }
        }
        // Rotate only when the segment just ended IS the open one. A held recovery segment is reviewed while the
        // operator's own segment is still open, and rotating there would abandon the segment being shot into.
        if gid == currentGroupId { startNewGroup() }       // gid is now finalized (differs from currentGroupId)
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

    // MARK: - Recovery (W40.i-fix-ios-session-durability, Android's W23.m8)

    /// Whether a page may go to the Mac now. The one thing that withholds it is an unreviewed recovery: everything
    /// else in the queue has a classification the operator chose. Android's `isSendable`.
    static func isSendable(_ item: CapturedItem) -> Bool { item.needsReview != true }

    /// Recovered pages held until the operator classifies them, and the group the Review button shows. Derived from
    /// the items, so the hold survives a further kill exactly as the per-item flag does; two stale launches leave
    /// two held groups, reviewed one at a time.
    var heldForReviewCount: Int { items.filter { $0.needsReview == true }.count }
    var heldReviewGroupId: String? { items.first { $0.needsReview == true }?.groupId }

    /// Review: put the ordinary tag sheet up on the first held group. Ending it (Apply or Skip) is what releases its
    /// pages; there is no path that releases them silently. Returns false if nothing is held.
    mutating func beginReview() -> Bool {
        guard let group = heldReviewGroupId else { return false }
        pendingTagGroupId = group
        return true
    }

    /// How far a launch against a stale or unreadable session moves the seq counter on. The file's counter may lag
    /// seqs already sent (to the open segment's group, which the file restores as current), and a new page reusing
    /// one would replace that page on the Mac, which keys on (group, seq). A gap is harmless: the Mac accepts any
    /// seq ≥ 0 and orders pages by it.
    static let staleSeqMargin = 10_000

    /// Called once, at a launch whose session file is stale or unreadable, before anything is adopted or shot.
    mutating func skipSeqsAfterStaleRestore() { seqCounter += Self.staleSeqMargin }

    /// Adopt the photos on disk that no item names, in file-name order, as one recovery segment of document pages in
    /// a new group. An archival photo can't be retaken, so an unlisted one is never left invisible; a crash between
    /// writing a photo and saving the session leaves exactly that. What differs is what the adoption may CLAIM.
    /// Against a trustworthy session file the photo is one the last save hadn't caught up with, and a fresh segment
    /// is an honest account of it. Against a stale one (`manifestStale`) the same segment would be a guess standing
    /// in for a classification lost with the unsaved write, so the pages are held for review instead.
    /// `known` names extra files that must not be adopted (the restore's dropped items, whose delete may have
    /// failed: adopted, they would reach the Mac twice under a new group). Returns the adopted items.
    mutating func adoptOrphans(_ filesOnDisk: [URL], known: Set<String> = [], manifestStale: Bool) -> [CapturedItem] {
        let listed = known.union(items.map(\.fileURL.lastPathComponent))
        let orphans = filesOnDisk.filter { !listed.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !orphans.isEmpty else { return [] }
        let group = newGroupId()
        var adopted: [CapturedItem] = []
        for file in orphans {
            seqCounter += 1
            adopted.append(CapturedItem(id: nextId, fileURL: file, groupId: group, seq: seqCounter, type: .document,
                                        needsReview: manifestStale ? true : nil))
            nextId += 1
        }
        items.append(contentsOf: adopted)
        return adopted
    }

    // MARK: - In-flight guards

    /// Claims the id for a send under the current pairing. Returns false if any send for it is outstanding,
    /// including one from a retired pairing that is still unwinding.
    mutating func beginUpload(_ id: Int64) -> Bool {
        guard inFlightUploads[id] == nil else { return false }
        inFlightUploads[id] = pairing
        return true
    }
    /// Releases the claim only if `pairing` made it, so a retired send can never free the current one's guard.
    /// Returns whether it did.
    @discardableResult
    mutating func endUpload(_ id: Int64, pairing: Int) -> Bool {
        guard inFlightUploads[id] == pairing else { return false }
        inFlightUploads[id] = nil
        return true
    }
    func isUploading(_ id: Int64) -> Bool { inFlightUploads[id] != nil }

    /// Returns false if a signal for the group is already being sent, under any pairing.
    mutating func beginSegmentSend(_ group: String) -> Bool {
        guard inFlightSegments[group] == nil else { return false }
        inFlightSegments[group] = pairing
        return true
    }
    @discardableResult
    mutating func endSegmentSend(_ group: String, pairing: Int) -> Bool {
        guard inFlightSegments[group] == pairing else { return false }
        inFlightSegments[group] = nil
        return true
    }

    /// What a send's reply may do: nil when Clear took the session while it ran (record nothing at all), else the
    /// pairing ownership rule. The view model calls this once the network call returns.
    func ackForReply(ok: Bool, generation: Int, pairing: Int) -> SendAck? {
        guard isCurrent(generation) else { return nil }
        return Self.sendAck(ok: ok, pairingIsCurrent: isCurrentPairing(pairing))
    }

    /// What an upload task's end did. `released`: it held the claim (so the caller drops its task handle).
    /// `requeued`: the pairing outlived it, so its page went back to pending for the Mac paired now.
    struct SendEnd: Equatable { let released: Bool; let requeued: Bool }

    /// An upload task ending, for any reason (its defer). Nothing if Clear took the session; otherwise releases
    /// only its own claim, and puts the page back in the queue if the pairing it was sent under has been left.
    mutating func finishUpload(_ id: Int64, generation: Int, pairing: Int) -> SendEnd {
        guard isCurrent(generation), endUpload(id, pairing: pairing) else { return .init(released: false, requeued: false) }
        return .init(released: true, requeued: !isCurrentPairing(pairing) && requeueAfterStaleSend(id))
    }

    /// A segment send ending (its defer). `requeued` here means the pairing outlived it: the segment stays ended
    /// and should be sent to the Mac paired now.
    mutating func finishSegmentSend(_ group: String, generation: Int, pairing: Int) -> SendEnd {
        guard isCurrent(generation), endSegmentSend(group, pairing: pairing) else { return .init(released: false, requeued: false) }
        return .init(released: true, requeued: !isCurrentPairing(pairing))
    }

    /// A send the pairing outlived left its page UPLOADING, which neither resume nor auto-retry sends again: put it
    /// back to pending, any deferred resend folded in, for the Mac paired now. Returns true if it changed.
    mutating func requeueAfterStaleSend(_ id: Int64) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }),
              items[i].state != .pending || items[i].needsResend == true else { return false }
        items[i].state = .pending
        items[i].needsResend = nil
        return true
    }

    // MARK: - Counts and filters

    /// A page the Mac must still receive: not confirmed, or confirmed with bytes a pending resend (a Q3 toggle or
    /// reclassify during its upload) has made stale. Android's `requiresDeleteConfirmation`.
    static func macStillNeeds(_ item: CapturedItem) -> Bool { item.state != .uploaded || item.needsResend == true }

    /// The count heartbeated to the Mac as "phone still has N photos to send": every page it must still receive.
    /// FAILED pages count, because the auto-retry loop sends them again on its own; leaving them out told the Mac 0
    /// while pages were still to come, so Finish could close a partial session (W40.i-fix-ios-heartbeat-count,
    /// Android's `pendingReportCount`). It reaches 0 only when every page left is confirmed and current.
    var heartbeatCount: Int { items.filter(Self.macStillNeeds).count }

    /// Everything the Mac must still receive and may be sent now, re-sent on (re)connect. A held page counts in the
    /// heartbeat above (the Mac must not finish without it) but is never sent until reviewed.
    var resumeCandidates: [CapturedItem] { items.filter { Self.macStillNeeds($0) && Self.isSendable($0) } }

    /// What the auto-retry loop flushes: failed uploads, any still-PENDING page, and any page with a resend pending.
    var autoRetryCandidates: [CapturedItem] {
        items.filter { ($0.state == .failed || $0.state == .pending || $0.needsResend == true) && Self.isSendable($0) }
    }

    /// The Mac confirmed a send whose fields changed while it ran: the bytes it holds are stale, so the page goes
    /// back to pending with the marker folded in, in one step, so no heartbeat in between can count it as
    /// delivered (Android's `prepareDeferredResend`). Returns the page to send again, or nil if it is gone.
    mutating func prepareDeferredResend(_ id: Int64) -> CapturedItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[i].state = .pending
        items[i].needsResend = nil
        return items[i]
    }

    var failedItems: [CapturedItem] { items.filter { $0.state == .failed } }

    var uploadSummary: String {
        let failed = items.filter { $0.state == .failed }.count
        let inflight = items.filter { ($0.state == .pending || $0.state == .uploading) && Self.isSendable($0) }.count
        var parts: [String] = []
        if inflight > 0 { parts.append("\(inflight) queued") }
        if failed > 0 { parts.append("\(failed) failed") }
        if heldForReviewCount > 0 { parts.append("\(heldForReviewCount) held") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Removal, clear, restore

    /// A photo confirmed by the Mac is durably safe there, so it leaves the phone. Guarded by identity + state (ids
    /// are never reused, and the file must match too) so a stale timer can't remove another photo. Document pages of the current,
    /// un-ended segment stay so the operator sees the segment grow. Returns the removed item, or nil.
    mutating func removeConfirmed(_ item: CapturedItem) -> CapturedItem? {
        guard let i = items.firstIndex(where: { $0.id == item.id && $0.fileURL == item.fileURL }),
              items[i].state == .uploaded, !deleting.contains(item.id) else { return nil }
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
        deleting.removeAll()          // a delete still running sees the generation move and records nothing
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
            // A held recovery group was under review: bring its sheet back, but leave the operator's segment current,
            // or ending the review would rotate away from the segment being shot into.
            if !items.contains(where: { $0.groupId == taggingGroup && $0.needsReview == true }) {
                currentGroupId = taggingGroup
            }
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

/// One ordered, conflated writer for the heartbeat (W40.i-fix-ios-heartbeat-count, Android's CONFLATED
/// `statusChannel`). Each report used to go out on its own `Task`, so two could reach the Mac out of order and an
/// older 0 overwrite a newer count. Now one writer sends at a time and only the newest waiting report is kept.
/// The view model offers each report and runs the writer; this holds only the bookkeeping, so the host tests can
/// drive it.
struct HeartbeatMailbox<Report> {
    private(set) var waiting: Report?
    private(set) var writerRunning = false

    /// Keep `report` as the newest, replacing any not yet sent. Returns true if no writer is running, so the caller
    /// must start one.
    mutating func offer(_ report: Report) -> Bool {
        waiting = report
        guard !writerRunning else { return false }
        writerRunning = true
        return true
    }

    /// The writer's next report to send. Nil ends the writer, so the next `offer` starts a new one.
    mutating func take() -> Report? {
        guard let report = waiting else { writerRunning = false; return nil }
        waiting = nil
        return report
    }
}

/// The session file's one ordered writer (W40.i-fix-ios-session-durability, Android's CONFLATED `storeChannel`).
/// Every change used to write the file on the main thread. Now the view model offers each snapshot here and one
/// writer saves off the main thread, keeping only the newest snapshot waiting. A Clear is ordered too: it drops the
/// cleared session's waiting snapshot and runs before any snapshot offered after it, so a save from before Clear
/// can never bring the cleared session back. Bookkeeping only, so the host tests can drive it.
struct SessionWriteMailbox<Snapshot> {
    enum Operation { case save(Snapshot), clear }

    private(set) var waitingSave: Snapshot?
    private(set) var clearWaiting = false
    private(set) var writerRunning = false

    /// Keep `snapshot` as the newest, replacing any not yet written. Returns true if the caller must start a writer.
    mutating func offerSave(_ snapshot: Snapshot) -> Bool {
        waitingSave = snapshot
        return startWriterIfIdle()
    }

    /// Clear the session file once any write in progress ends. A waiting snapshot belongs to the cleared session,
    /// so it is dropped. Returns true if the caller must start a writer.
    mutating func offerClear() -> Bool {
        waitingSave = nil
        clearWaiting = true
        return startWriterIfIdle()
    }

    /// The writer's next operation: a waiting Clear first (any snapshot waiting now was offered after it), then the
    /// newest snapshot. Nil ends the writer, so the next offer starts a new one.
    mutating func take() -> Operation? {
        if clearWaiting { clearWaiting = false; return .clear }
        guard let snapshot = waitingSave else { writerRunning = false; return nil }
        waitingSave = nil
        return .save(snapshot)
    }

    private mutating func startWriterIfIdle() -> Bool {
        guard !writerRunning else { return false }
        writerRunning = true
        return true
    }
}

/// What a confirmed delete settled on, decided before the photo's file is touched (Android's `DeleteOutcome`).
enum DeleteOutcome: Equatable {
    /// Copied into the Photos library, so it may leave the queue: recoverable.
    case savedToPhotos
    /// Removed outright: the operator chose Delete permanently, or the Mac already has it.
    case deleted
    /// The copy to Photos failed, so the photo is KEPT. An unsent page's only copy is never deleted on a failed copy.
    case keptCopyFailed
}

/// Stop a page's upload and WAIT for it to finish before deciding the photo's fate (W40.i-fix-ios-delete-confirm,
/// Android's `retireCapture`). Once the send has unwound, the Mac either has the page or never will from this send,
/// and no late reply can remove the file under the copy. Then `copy`, when the operator chose Save to Photos &
/// delete: only a copy that was written lets the photo go. UI-free so the host tests can drive the ordering.
func stopUploadThenRetire(_ upload: Task<Void, Never>?, copy: (() async -> Bool)?) async -> DeleteOutcome {
    upload?.cancel()
    await upload?.value
    guard let copy else { return .deleted }
    return await copy() ? .savedToPhotos : .keptCopyFailed
}
