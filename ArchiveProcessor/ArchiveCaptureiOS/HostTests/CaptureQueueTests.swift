import Foundation
import Security

// Host tests for the iOS companion's CaptureQueue, compiled with swiftc against the app's real
// Capture/CaptureQueue.swift, CaptureModels.swift and SessionStore.swift, and Net/DriveTokenStore.swift (scripts/test-ios-capture-queue.sh).
// The iOS app has no test target and no simulator runtime to host one (W40.i-fix-ios-testable-core).
//
// Tests marked CURRENT pin today's behaviour where a queued fix will change it; that fix flips the assertion
// first, so it fails before the fix and passes after (rule 8).

var failures = 0, passes = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passes += 1 } else { failures += 1; print("  [FAIL] line \(line): \(what)") }
}
func test(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch { failures += 1; print("  [FAIL] \(name): threw \(error)") }
    print(failures == before ? "  [PASS] \(name)" : "  [FAIL] \(name)")
}

/// Deterministic group ids: g1, g2, …
func makeQueue() -> CaptureQueue {
    var n = 0
    return CaptureQueue(newGroupId: { n += 1; return "g\(n)" })
}
func url(_ name: String) -> URL { URL(fileURLWithPath: "/scratch/\(name).jpg") }

test("document pages share the current group with rising ids and seqs") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a")), b = q.addDocument(fileURL: url("b"))
    check(a.groupId == "g1" && b.groupId == "g1", "both in g1")
    check(a.id == 1 && b.id == 2 && a.seq == 1 && b.seq == 2, "ids and seqs 1,2")
    check(q.documentPageCount(group: "g1") == 2, "two pages")
    check(a.state == .pending, "new page is pending")
}

test("a marker gets its own group and shares the seq and id counters") {
    var q = makeQueue()
    _ = q.addDocument(fileURL: url("a"))
    let m = q.addMarker(fileURL: url("box"), type: .box)
    check(m.groupId == "g2" && m.type == .box, "own group")
    check(m.id == 2 && m.seq == 2, "counters continue")
    check(q.currentGroupId == "g1", "current document group unchanged")
    check(q.documentPageCount(group: "g1") == 1, "marker is not a document page")
}

test("toggleQ3 flips the override on and off") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a"))
    check(q.toggleQ3(a.id)?.quality == "Q3", "on")
    check(q.toggleQ3(a.id)?.quality == nil, "off")
    check(q.toggleQ3(99) == nil, "unknown id")
}

test("reclassify builds the full replaces chain (SPEC A3) and resets the page to pending") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a"))
    q.setState(a.id, .uploaded)
    _ = q.toggleQ3(a.id)
    let r1 = q.reclassify(a.id, to: .box)!
    check(r1.groupId == "g2" && r1.replacesGroupId == "g1", "G→H carries G")
    check(r1.state == .pending && r1.quality == nil && r1.type == .box, "reset")
    let r2 = q.reclassify(a.id, to: .folder)!
    check(r2.groupId == "g3" && r2.replacesGroupId == "g1,g2", "G→H→I carries G,H")
}

test("needsResend flags report whether they changed") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a"))
    check(q.markNeedsResend(a.id), "first mark changes")
    check(!q.markNeedsResend(a.id), "second mark does not")
    check(q.clearNeedsResend(a.id), "clear changes")
    check(!q.clearNeedsResend(a.id), "second clear does not")
    check(!q.markNeedsResend(99), "unknown id")
}

test("in-flight guards refuse a second concurrent send") {
    var q = makeQueue()
    check(q.beginUpload(1) && !q.beginUpload(1) && q.isUploading(1), "upload guard")
    q.endUpload(1, pairing: q.pairing)
    check(!q.isUploading(1) && q.beginUpload(1), "released")
    check(q.beginSegmentSend("g1") && !q.beginSegmentSend("g1"), "segment guard")
    q.endSegmentSend("g1", pairing: q.pairing)
    check(q.beginSegmentSend("g1"), "segment released")
}

test("endSegment stamps tags, opens a new group, records seqs and splits uploaded from not") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a")), b = q.addDocument(fileURL: url("b"))
    _ = q.addMarker(fileURL: url("box"), type: .box)           // g2, not part of the segment
    let c = q.addDocument(fileURL: url("c"))
    q.setState(a.id, .uploaded)
    _ = q.toggleQ3(c.id)
    check(q.endSegment(quality: "Q1", year: 1968, month: 3) == nil, "no tag sheet open → nil")
    q.pendingTagGroupId = "g1"
    let end = q.endSegment(quality: "Q1", year: 1968, month: 3)!
    check(q.pendingTagGroupId == nil, "tag sheet consumed")
    check(end.group == "g1" && end.pages == 3, "three pages in g1")
    check(q.currentGroupId == "g3", "next segment opened")
    check(end.toUpload.map(\.id) == [b.id, c.id], "non-uploaded pages to send")
    check(end.confirmed.map(\.id) == [a.id], "uploaded page confirmed")
    check(q.item(b.id)?.quality == "Q1" && q.item(b.id)?.year == 1968 && q.item(b.id)?.month == 3, "stamped")
    check(q.item(c.id)?.quality == "Q3", "per-page Q3 kept")
    check(q.endedSegments["g1"] == .init(quality: "Q1", year: 1968, month: 3, seqs: "1,2,4"), "seqs snapshotted (A5)")
}

test("a segment is ready only once every page is uploaded, and leaves on ack") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a")), b = q.addDocument(fileURL: url("b"))
    check(q.readySegment("g1") == nil, "not ended")
    q.pendingTagGroupId = "g1"
    _ = q.endSegment(quality: nil, year: nil, month: nil)
    q.setState(a.id, .uploaded); q.setState(b.id, .failed)
    check(q.readySegment("g1") == nil, "a failed page blocks it")
    q.setState(b.id, .uploading)
    check(q.readySegment("g1") == nil, "an uploading page blocks it")
    q.setState(b.id, .uploaded)
    check(q.readySegment("g1")?.seqs == "1,2", "ready")
    q.acknowledgeSegment("g1")
    check(q.readySegment("g1") == nil && q.endedSegments.isEmpty, "acked")
}

test("removeConfirmed keeps the open segment's pages and checks identity and state") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a"))
    let m = q.addMarker(fileURL: url("box"), type: .box)
    check(q.removeConfirmed(m) == nil, "marker not yet uploaded stays")
    q.setState(m.id, .uploaded); q.setState(a.id, .uploaded)
    check(q.removeConfirmed(a) == nil, "uploaded page of the open segment stays")
    let stale = CapturedItem(id: m.id, fileURL: url("other"), groupId: m.groupId, seq: m.seq, type: .box)
    check(q.removeConfirmed(stale) == nil, "same id, different file → not removed")
    check(q.removeConfirmed(m)?.id == m.id, "confirmed marker leaves")
    q.startNewGroup()
    check(q.removeConfirmed(a)?.id == a.id, "page leaves once its segment is no longer current")
    check(q.items.isEmpty, "empty")
}

test("counts and filters by state") {
    var q = makeQueue()
    let ids = (0..<4).map { q.addDocument(fileURL: url("p\($0)")).id }
    q.setState(ids[1], .uploading); q.setState(ids[2], .uploaded); q.setState(ids[3], .failed)
    check(q.resumeCandidates.map(\.id) == [ids[0], ids[1], ids[3]], "resume = not uploaded")
    check(q.autoRetryCandidates.map(\.id) == [ids[0], ids[3]], "auto-retry = pending + failed")
    check(q.failedItems.map(\.id) == [ids[3]], "failed")
    check(q.uploadSummary == "2 queued · 1 failed", "summary")
    check(q.heartbeatCount == 3, "heartbeat = every page not confirmed, failed included")
}

test("a failed page keeps the Mac waiting: the heartbeat reaches 0 only when all are confirmed") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a")), b = q.addDocument(fileURL: url("b"))
    q.setState(a.id, .uploaded); q.setState(b.id, .failed)
    check(q.heartbeatCount == 1, "the failed page still counts, since auto-retry will send it")
    check(q.autoRetryCandidates.map(\.id) == [b.id], "and auto-retry does send it")
    q.setState(b.id, .uploaded)
    check(q.heartbeatCount == 0, "drained")
}

test("a page with a resend pending counts, and is resent by auto-retry and resume") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a")), b = q.addDocument(fileURL: url("b"))
    q.setState(a.id, .uploaded); q.setState(b.id, .uploaded)
    _ = q.markNeedsResend(a.id)                  // the Mac holds a's stale fields
    check(q.heartbeatCount == 1, "the Mac must still receive a's current fields")
    check(q.autoRetryCandidates.map(\.id) == [a.id], "auto-retry resends it")
    check(q.resumeCandidates.map(\.id) == [a.id], "a reconnect resends it")
}

test("a confirmed send with a resend pending goes straight back to pending") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a"))
    q.setState(a.id, .uploading)
    _ = q.markNeedsResend(a.id)                  // a Q3 toggle while the upload ran
    let next = q.prepareDeferredResend(a.id)
    check(next?.state == .pending && next?.needsResend == nil, "pending, marker folded in")
    check(q.heartbeatCount == 1, "never counted as delivered in between")
    check(q.prepareDeferredResend(99) == nil, "unknown id")
}

test("the heartbeat mailbox runs one writer and sends only the newest waiting report") {
    var m = HeartbeatMailbox<Int>()
    check(m.offer(3), "first offer starts the writer")
    check(!m.offer(2) && !m.offer(0), "later offers join the running writer")
    check(m.take() == 0, "the writer sends only the newest, so the older 3 and 2 never land after it")
    check(!m.offer(1), "an offer while the 0 is on the wire waits for the same writer")
    check(m.take() == 1, "and goes out after it, in order")
    check(m.take() == nil && !m.writerRunning, "nothing waiting ends the writer")
    check(m.offer(4) && m.take() == 4, "the next offer starts a new writer")
}

test("clear empties the session, restarts seqs and never reuses an id") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a")), b = q.addDocument(fileURL: url("b"))
    _ = q.beginUpload(a.id)
    q.pendingTagGroupId = "g1"
    _ = q.endSegment(quality: nil, year: nil, month: nil)
    _ = q.beginSegmentSend("g1")
    let removed = q.clear()
    check(removed.map(\.id) == [a.id, b.id], "every item returned for file deletion")
    check(q.items.isEmpty && q.endedSegments.isEmpty && q.inFlightUploads.isEmpty && q.inFlightSegments.isEmpty, "empty")
    check(q.pendingTagGroupId == nil && q.currentGroupId == "g3", "fresh group")
    let c = q.addDocument(fileURL: url("c"))
    check(c.id == 3, "ids carry on after Clear: an old upload's id can never name a new photo")
    check(c.seq == 1, "seqs restart: the new session's groups are fresh, so (group, seq) stays unique")
}

test("a reply to an upload Clear outlived does not touch the new session") {
    var q = makeQueue()
    let old = q.addDocument(fileURL: url("old"))
    let started = q.generation               // what enqueueUpload captures before the network call
    check(q.beginUpload(old.id), "upload begins")
    _ = q.clear()
    check(!q.isCurrent(started), "Clear moves the generation on")
    let fresh = q.addDocument(fileURL: url("fresh"))
    check(fresh.id != old.id, "the new photo has a new id")
    // The late reply: the view model records nothing when ackForReply is nil.
    check(q.ackForReply(ok: true, generation: started, pairing: q.pairing) == nil, "Clear outlived it: record nothing")
    check(q.item(fresh.id)?.state == .pending, "the new photo is still pending, so it is still sent")
    // Even without the generation check, the old id names nothing now.
    check(!q.setState(old.id, .uploaded), "the old id matches no item")
    check(q.item(fresh.id)?.state == .pending, "still pending")
    check(q.finishUpload(old.id, generation: started, pairing: q.pairing) == .init(released: false, requeued: false),
          "the old task's defer touches nothing")
    check(q.beginUpload(fresh.id), "the new photo can upload")
    check(q.isCurrent(q.generation), "a send started now is current")
}

test("ids stay unique across Clear and a restored session") {
    var q = makeQueue()
    _ = q.addDocument(fileURL: url("a")); _ = q.addDocument(fileURL: url("b"))
    _ = q.clear()
    let c = q.addDocument(fileURL: url("c"))
    var r = makeQueue()
    _ = r.restore(q.snapshot()) { _ in true }
    check(c.id == 3, "Clear kept the counter running")
    check(r.addDocument(fileURL: url("d")).id == 4, "the snapshot carries the id counter past Clear")
}

test("snapshot round-trips through SessionStore and restore drops confirmed items except the open segment's") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cq-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(url: dir.appendingPathComponent("capture-session.json"), photoDirectory: url("x").deletingLastPathComponent())

    var q = makeQueue()
    let old = q.addDocument(fileURL: url("old"))                // g1, ended + uploaded → dropped
    q.setState(old.id, .uploaded)
    q.pendingTagGroupId = "g1"
    _ = q.endSegment(quality: "Q2", year: 1970, month: nil)    // current → g2
    let m = q.addMarker(fileURL: url("box"), type: .box)       // g3, uploaded → dropped
    q.setState(m.id, .uploaded)
    let f = q.addMarker(fileURL: url("folder"), type: .folder) // g4, failed → kept
    q.setState(f.id, .failed)
    let open = q.addDocument(fileURL: url("open"))             // g2, uploaded but open segment → kept
    q.setState(open.id, .uploaded)
    let pend = q.addDocument(fileURL: url("pend"))             // g2, pending → kept
    check(store.save(q.snapshot()), "saved")

    var r = makeQueue()
    let dropped = r.restore(try XCTUnwrap(store.load()), fileExists: { _ in true }).dropped
    check(Set(dropped.map(\.id)) == [old.id, m.id], "confirmed items outside the open segment dropped")
    check(r.items.map(\.id) == [f.id, open.id, pend.id], "kept in order")
    check(r.currentGroupId == "g2" && r.pendingTagGroupId == nil, "open segment restored, no tag sheet")
    check(r.nextId == q.nextId && r.seqCounter == q.seqCounter, "counters restored")
    check(r.endedSegments["g1"] == .init(quality: "Q2", year: 1970, month: nil, seqs: "1"), "ended segment restored")
    check(r.addDocument(fileURL: url("next")).id == pend.id + 1, "ids continue")
}

test("restore re-opens the tag sheet only for a group that still has document pages") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a"))
    q.setState(a.id, .uploaded)
    q.pendingTagGroupId = "g1"
    var r = makeQueue()
    _ = r.restore(q.snapshot(), fileExists: { _ in true })
    check(r.pendingTagGroupId == "g1" && r.currentGroupId == "g1", "mid-tagging → sheet re-opens")

    var s = q.snapshot()
    s.pendingTagGroupId = "gone"
    var r2 = makeQueue()
    _ = r2.restore(s, fileExists: { _ in true })
    check(r2.pendingTagGroupId == nil && r2.currentGroupId == "g1", "no pages in that group → no sheet")
}

// W40.i-fix-ios-photo-storage: photos are restored by file NAME against the photo directory, a missing file is
// skipped and reported, and a pending resend survives an uploaded state.

/// A scratch session store with its own photo directory, removed when `body` returns.
func withScratchStore(_ body: (SessionStore, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cq-\(UUID().uuidString)")
    let photos = root.appendingPathComponent("capture", isDirectory: true)
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(SessionStore(url: root.appendingPathComponent("capture-session.json"), photoDirectory: photos), photos)
}

test("the session file stores file names only, never an absolute path") {
    try withScratchStore { store, photos in
        var q = makeQueue()
        _ = q.addDocument(fileURL: photos.appendingPathComponent("img_A.jpg"))
        check(store.save(q.snapshot()), "saved")
        let json = try String(contentsOf: photos.deletingLastPathComponent().appendingPathComponent("capture-session.json"), encoding: .utf8)
        check(json.contains("\"fileName\":\"img_A.jpg\""), "name stored")
        check(!json.contains(photos.path.replacingOccurrences(of: "/", with: "\\/")) && !json.contains(photos.path),
              "no directory in the file")
    }
}

test("a photo saved under one container path restores under the new one (reinstall)") {
    try withScratchStore { oldStore, oldPhotos in
        var q = makeQueue()
        _ = q.addDocument(fileURL: oldPhotos.appendingPathComponent("img_A.jpg"))
        check(oldStore.save(q.snapshot()), "saved")
        // Same session file, but the container moved: the photo directory is now somewhere else.
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("cq-moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moved) }
        try Data([0xFF, 0xD8]).write(to: moved.appendingPathComponent("img_A.jpg"))
        let newStore = SessionStore(url: oldPhotos.deletingLastPathComponent().appendingPathComponent("capture-session.json"),
                                    photoDirectory: moved)
        let snap = try XCTUnwrap(newStore.load())
        check(snap.items.first?.fileURL.standardizedFileURL == moved.appendingPathComponent("img_A.jpg").standardizedFileURL,
              "resolved against the new directory")
        var r = makeQueue()
        let res = r.restore(snap) { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        check(r.items.count == 1 && res.missing.isEmpty, "found and kept")
    }
}

test("restore skips and reports a photo whose file is gone") {
    try withScratchStore { store, photos in
        var q = makeQueue()
        let here = q.addDocument(fileURL: photos.appendingPathComponent("img_here.jpg"))
        let gone = q.addMarker(fileURL: photos.appendingPathComponent("img_gone.jpg"), type: .box)
        try Data([0xFF, 0xD8]).write(to: here.fileURL)
        check(store.save(q.snapshot()), "saved")
        var r = makeQueue()
        let res = r.restore(try XCTUnwrap(store.load())) { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        check(r.items.map(\.id) == [here.id], "only the photo on disk is restored")
        check(res.missing.map(\.id) == [gone.id], "the missing one is reported")
        check(res.dropped.isEmpty, "a missing photo is not reported as confirmed")
        check(r.nextId == q.nextId && r.seqCounter == q.seqCounter, "counters still restored, so no id or seq is reused")
    }
}

test("a page whose resend is pending is kept as pending, not pruned as uploaded") {
    var q = makeQueue()
    let a = q.addMarker(fileURL: url("a"), type: .box)   // a marker: an uploaded one is normally pruned
    q.setState(a.id, .uploaded)
    _ = q.markNeedsResend(a.id)                          // the app stopped between "uploaded" and the resend
    let b = q.addMarker(fileURL: url("b"), type: .folder)
    q.setState(b.id, .uploaded)
    var r = makeQueue()
    let res = r.restore(q.snapshot(), fileExists: { _ in true })
    check(r.item(a.id)?.state == .pending, "resend page restored as pending")
    check(r.item(a.id)?.needsResend != true, "the marker is consumed: the pending send carries the current fields")
    check(r.resumeCandidates.map(\.id) == [a.id], "resume re-sends it")
    check(res.dropped.map(\.id) == [b.id], "a plain uploaded marker is still pruned")
}

test("a session file naming a path rather than a file name is rejected") {
    try withScratchStore { store, photos in
        let file = photos.deletingLastPathComponent().appendingPathComponent("capture-session.json")
        for bad in ["../escape.jpg", "/abs/img.jpg", "", ".."] {
            let json = #"{"items":[{"id":1,"fileName":"\#(bad)","groupId":"g1","seq":1,"type":"document","state":"pending"}],"seq":1,"nextId":2}"#
            try json.write(to: file, atomically: true, encoding: .utf8)
            check(store.load() == nil, "rejected: \(bad)")
        }
        let good = #"{"items":[{"id":1,"fileName":"img_A.jpg","groupId":"g1","seq":1,"type":"document","state":"pending"}],"seq":1,"nextId":2}"#
        try good.write(to: file, atomically: true, encoding: .utf8)
        check(store.load()?.items.first?.fileURL.lastPathComponent == "img_A.jpg", "a bare name loads")
    }
}

struct Missing: Error {}
func XCTUnwrap<T>(_ v: T?) throws -> T { guard let v else { throw Missing() }; return v }


// W40.i-fix-ios-pairing-generation: Android's W23.m1 (CapturePairingGenerationTest), ported.

test("a success reported by a Mac the phone has unpaired from is never a confirmation") {
    check(CaptureQueue.sendAck(ok: true, pairingIsCurrent: true) == .confirm, "current, ok → confirm")
    check(CaptureQueue.sendAck(ok: false, pairingIsCurrent: true) == .retry, "current, failed → retry")
    check(CaptureQueue.sendAck(ok: true, pairingIsCurrent: false) == .requeueStale, "the misroute → requeue")
    check(CaptureQueue.sendAck(ok: false, pairingIsCurrent: false) == .requeueStale, "stale, failed → requeue")
}

test("rotating the pairing invalidates every send stamped before it") {
    var q = makeQueue()
    let before = q.pairing
    check(q.isCurrentPairing(before), "current at first")
    q.rotatePairing()
    let after = q.pairing
    check(!q.isCurrentPairing(before) && q.isCurrentPairing(after), "re-pair retires the old stamp")
    q.rotatePairing()                        // unpair, then pair again
    check(!q.isCurrentPairing(before) && !q.isCurrentPairing(after), "both stale")
    check(q.isCurrent(q.generation), "a re-pair is not a Clear")
}

test("only one send per page is outstanding across a re-pair, and a retired one frees only its own claim") {
    var q = makeQueue()
    let old = q.pairing
    check(q.beginUpload(1), "the old Mac's send claims page 1")
    q.rotatePairing()
    check(!q.beginUpload(1), "the new Mac can't send it while the old send still holds the photo")
    check(q.endUpload(1, pairing: old), "the retired send releases its own claim as it unwinds")
    check(q.beginUpload(1), "now the new Mac's send claims it")
    check(!q.endUpload(1, pairing: old), "a second release from the retired send frees nothing")
    check(q.isUploading(1), "the current send keeps its guard")
    check(q.endUpload(1, pairing: q.pairing) && !q.isUploading(1), "the current send releases it")
    let seg = q.pairing
    check(q.beginSegmentSend("g1"), "segment claim")
    q.rotatePairing()
    check(!q.beginSegmentSend("g1"), "segment refused while the retired send runs")
    check(!q.endSegmentSend("g1", pairing: q.pairing), "the current pairing did not make that claim")
    check(q.endSegmentSend("g1", pairing: seg) && q.beginSegmentSend("g1"), "released by its owner, then reclaimed")
}

test("the old Mac's reply cannot mark a page delivered, and the page goes back in the queue") {
    var q = makeQueue()
    let page = q.addDocument(fileURL: url("p"))
    _ = q.addDocument(fileURL: url("next"))
    // enqueueUpload under the old pairing:
    let gen = q.generation, stamp = q.pairing
    check(q.beginUpload(page.id), "send begins")
    q.setState(page.id, .uploading)
    q.rotatePairing()                        // the operator re-pairs while it is on the wire
    // The old Mac answers ok; the view model returns at once on requeueStale, before any state change.
    check(q.ackForReply(ok: true, generation: gen, pairing: stamp) == .requeueStale, "the misroute is not a confirm")
    check(q.ackForReply(ok: false, generation: gen, pairing: stamp) == .requeueStale, "nor is a stale failure a retry")
    check(!q.beginUpload(page.id), "the new Mac's resume is refused while the old send holds the photo")
    // The task's defer:
    check(q.finishUpload(page.id, generation: gen, pairing: stamp) == .init(released: true, requeued: true),
          "it releases its claim and requeues the page")
    check(q.item(page.id)?.state == .pending, "pending again, never uploaded")
    check(q.autoRetryCandidates.contains { $0.id == page.id }, "auto-retry sends it to the new Mac")
    check(q.heartbeatCount == 2, "the new Mac counts it")
    // The new pairing now delivers it for real.
    let now = q.pairing
    check(q.beginUpload(page.id), "new send begins")
    check(q.ackForReply(ok: true, generation: gen, pairing: now) == .confirm, "only the current Mac's reply confirms")
    check(q.ackForReply(ok: false, generation: gen, pairing: now) == .retry, "a current failure is a retry")
    check(q.finishUpload(page.id, generation: gen, pairing: stamp) == .init(released: false, requeued: false),
          "a second unwind from the old pairing frees nothing")
    check(q.isUploading(page.id), "the current send keeps its guard")
    check(q.finishUpload(page.id, generation: gen, pairing: now) == .init(released: true, requeued: false),
          "the current send's end releases and does not requeue")
}

test("unpair without re-pair: the page waits as pending for the next pairing") {
    var q = makeQueue()
    let page = q.addDocument(fileURL: url("p"))
    let gen = q.generation, stamp = q.pairing
    _ = q.beginUpload(page.id); q.setState(page.id, .uploading)
    q.rotatePairing()                        // disconnect(): cancelled, the send fails
    check(q.ackForReply(ok: false, generation: gen, pairing: stamp) == .requeueStale, "stale")
    check(q.finishUpload(page.id, generation: gen, pairing: stamp).requeued, "requeued")
    check(q.resumeCandidates.map(\.id) == [page.id] && !q.isUploading(page.id), "the next pairing's resume sends it")
}

test("Clear during a stale send: the defer touches nothing in the new session") {
    var q = makeQueue()
    let page = q.addDocument(fileURL: url("p"))
    let gen = q.generation, stamp = q.pairing
    _ = q.beginUpload(page.id)
    q.rotatePairing()
    _ = q.clear()
    let fresh = q.addDocument(fileURL: url("fresh"))
    check(q.ackForReply(ok: true, generation: gen, pairing: stamp) == nil, "Clear outranks the pairing")
    check(q.finishUpload(page.id, generation: gen, pairing: stamp) == .init(released: false, requeued: false), "no-op")
    check(q.item(fresh.id)?.state == .pending && q.beginUpload(fresh.id), "the new photo is untouched and can send")
}

test("a stale send folds a deferred resend into the requeue") {
    var q = makeQueue()
    let page = q.addDocument(fileURL: url("p"))
    q.setState(page.id, .uploading)
    _ = q.markNeedsResend(page.id)           // a Q3 toggle while the old send ran
    check(q.requeueAfterStaleSend(page.id), "changed")
    check(q.item(page.id)?.state == .pending && q.item(page.id)?.needsResend == nil, "pending, marker folded in")
    check(!q.requeueAfterStaleSend(page.id), "already pending → no change")
    check(!q.requeueAfterStaleSend(99), "unknown id")
}

test("a segment acked by the old Mac stays ended for the new one") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("a"))
    q.pendingTagGroupId = "g1"
    _ = q.endSegment(quality: "Q1", year: nil, month: nil)
    q.setState(a.id, .uploaded)
    let gen = q.generation, stamp = q.pairing
    check(q.readySegment("g1") != nil && q.beginSegmentSend("g1"), "signal sent")
    q.rotatePairing()
    check(q.ackForReply(ok: true, generation: gen, pairing: stamp) != .confirm, "the old Mac's ack does not confirm")
    check(q.endedSegments["g1"] != nil, "the new Mac never heard of it: still ended")
    check(!q.beginSegmentSend("g1"), "no second send while the retired one runs")
    check(q.finishSegmentSend("g1", generation: gen, pairing: stamp) == .init(released: true, requeued: true),
          "the retired send releases its claim and asks for a resend")
    let now = q.pairing
    check(q.readySegment("g1") != nil && q.beginSegmentSend("g1"), "it can be sent to the new Mac")
    check(q.ackForReply(ok: true, generation: gen, pairing: now) == .confirm, "the new Mac's ack confirms")
    check(q.finishSegmentSend("g1", generation: gen, pairing: now) == .init(released: true, requeued: false), "done")
}

// W40.i-fix-ios-session-durability: Android's W23.m8 (SessionStoreTest, CaptureOrphanAdoptionTest,
// CaptureRecoverySequenceTest), ported.

/// A scratch store whose writes go through `publish`, so a test can fail one the way a full volume does.
func withScratchStore(publish: @escaping (Data, URL) -> Bool, _ body: (SessionStore, URL, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cq-\(UUID().uuidString)")
    let photos = root.appendingPathComponent("capture", isDirectory: true)
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("capture-session.json")
    try body(SessionStore(url: file, photoDirectory: photos, publish: publish), photos, root)
}

test("save reports a failed write, and the stale flag outlives the process that raised it") {
    var fail = false
    try withScratchStore(publish: { fail ? false : SessionStore.replaceDurably($0, $1) }) { store, photos, root in
        var q = makeQueue()
        _ = q.addDocument(fileURL: photos.appendingPathComponent("img_A.jpg"))
        check(store.save(q.snapshot()), "a write that lands reports true")
        check(!store.manifestIsStale(), "and leaves no stale flag")
        fail = true
        _ = q.addMarker(fileURL: photos.appendingPathComponent("img_B.jpg"), type: .box)
        check(!store.save(q.snapshot()), "a write that fails reports false")
        check(store.manifestIsStale(), "and leaves the flag")
        let restarted = SessionStore(url: root.appendingPathComponent("capture-session.json"), photoDirectory: photos)
        check(restarted.manifestIsStale(), "a new process sees the flag")
        check(restarted.load()?.items.count == 1, "the file still holds the older snapshot")
        check(restarted.save(q.snapshot()) && !restarted.manifestIsStale(), "the next write that lands clears it")
        check(restarted.load()?.items.count == 2, "and holds the new snapshot")
        _ = store.save(q.snapshot())                                 // fails again: flag raised
        store.clear()
        check(!store.manifestIsStale() && store.load() == nil, "clear removes the file and the flag")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        check(leftovers.isEmpty, "no temporary files left behind")
    }
}

test("a session file that can't be read is set aside, never overwritten") {
    try withScratchStore { store, photos in
        let file = photos.deletingLastPathComponent().appendingPathComponent("capture-session.json")
        let garbage = Data("{\"items\":[{\"id\":1,".utf8)          // a truncated write
        try garbage.write(to: file)
        let loaded = store.loadSession()
        check(loaded.snapshot == nil && loaded.unreadable, "reported unreadable, not as no session")
        let aside = try XCTUnwrap(loaded.setAside)
        check((try? Data(contentsOf: aside)) == garbage, "the bytes survive under a new name")
        check(aside.lastPathComponent.hasPrefix("capture-session.unreadable-"), "named for what it is")
        var q = makeQueue()
        _ = q.addDocument(fileURL: photos.appendingPathComponent("img_A.jpg"))
        check(store.save(q.snapshot()), "the next save writes a fresh file")
        check((try? Data(contentsOf: aside)) == garbage, "and leaves the set-aside one alone")
        let fresh = store.loadSession()
        check(fresh.snapshot != nil && !fresh.unreadable, "the fresh file reads")
    }
    try withScratchStore { store, _ in
        let none = store.loadSession()
        check(none.snapshot == nil && !none.unreadable && none.setAside == nil, "no file is simply no session")
    }
}

test("an unlisted photo is adopted into a recovery segment that sends, against a trustworthy session") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("img_a"))                 // g1, listed
    let adopted = q.adoptOrphans([url("img_c"), url("img_a"), url("img_b"), url("img_dropped")],
                                 known: ["img_dropped.jpg"], manifestStale: false)
    check(adopted.map { $0.fileURL.lastPathComponent } == ["img_b.jpg", "img_c.jpg"], "unlisted only, in name order")
    check(adopted.allSatisfy { $0.groupId == "g2" && $0.type == .document }, "one new document group")
    check(adopted.map(\.id) == [a.id + 1, a.id + 2] && adopted.map(\.seq) == [2, 3], "ids and seqs continue")
    check(q.currentGroupId == "g1", "the open segment stays open")
    check(adopted.allSatisfy(CaptureQueue.isSendable), "sendable")
    check(Set(q.resumeCandidates.map(\.id)) == Set([a.id] + adopted.map(\.id)), "resume sends them")
    check(q.heldForReviewCount == 0 && !q.uploadSummary.contains("held"), "nothing held")
    check(q.adoptOrphans([url("img_a"), url("img_b")], manifestStale: false).isEmpty, "adopting twice adopts nothing")
}

test("against a stale session the adopted pages are held: counted, kept, never sent") {
    var q = makeQueue()
    let a = q.addDocument(fileURL: url("img_a"))
    let held = q.adoptOrphans([url("img_x"), url("img_y")], manifestStale: true)
    check(held.allSatisfy { $0.needsReview == true && !CaptureQueue.isSendable($0) }, "held")
    check(q.resumeCandidates.map(\.id) == [a.id], "resume skips them")
    check(q.autoRetryCandidates.map(\.id) == [a.id], "auto-retry skips them")
    check(q.heartbeatCount == 3, "the heartbeat still counts them, so the Mac can't finish without them")
    check(q.heldForReviewCount == 2 && q.heldReviewGroupId == "g2", "two held in g2")
    check(q.uploadSummary == "1 queued · 2 held", "the summary says held, not queued: \(q.uploadSummary)")
}

test("the hold survives a further kill") {
    try withScratchStore { store, photos in
        var q = makeQueue()
        _ = q.adoptOrphans([photos.appendingPathComponent("img_x.jpg")], manifestStale: true)
        check(store.save(q.snapshot()), "saved")
        var r = makeQueue()
        _ = r.restore(try XCTUnwrap(store.load()), fileExists: { _ in true })
        check(r.heldForReviewCount == 1 && r.resumeCandidates.isEmpty, "still held after restore")
    }
}

test("Review puts the tag sheet up on the held group; ending it releases the pages and keeps the open segment") {
    var q = makeQueue()
    let open = q.addDocument(fileURL: url("img_open"))              // g1, the operator's segment
    let held = q.adoptOrphans([url("img_x"), url("img_y")], manifestStale: true)   // g2
    check(q.beginReview() && q.pendingTagGroupId == "g2", "sheet on the held group")
    let end = try XCTUnwrap(q.endSegment(quality: "Q2", year: 1971, month: 4))
    check(end.group == "g2" && end.pages == 2, "the held group ended")
    check(Set(end.toUpload.map(\.id)) == Set(held.map(\.id)), "its pages are sent now")
    check(end.toUpload.allSatisfy { $0.needsReview == nil && $0.year == 1971 && $0.quality == "Q2" }, "released with the tags")
    check(q.currentGroupId == "g1", "the open segment was not rotated away")
    check(q.item(open.id)?.groupId == "g1" && q.heldForReviewCount == 0 && !q.beginReview(), "nothing left to review")
    check(q.endedSegments["g2"]?.seqs == "2,3", "recorded ended with its seqs")

    var s = makeQueue()
    _ = s.adoptOrphans([url("img_z")], manifestStale: true)
    check(s.beginReview(), "review")
    s.pendingTagGroupId = nil                                       // Cancel
    check(s.heldForReviewCount == 1, "Cancel leaves them held")
}

test("reclassifying a held page as a box or folder is its classification") {
    var q = makeQueue()
    let held = q.adoptOrphans([url("img_x")], manifestStale: true)[0]
    let box = try XCTUnwrap(q.reclassify(held.id, to: .box))
    check(box.needsReview == nil && CaptureQueue.isSendable(box), "the hold lifts")
}

test("restore brings back a review in progress without making the held group the open segment") {
    var q = makeQueue()
    _ = q.addDocument(fileURL: url("img_open"))                     // g1
    _ = q.adoptOrphans([url("img_x")], manifestStale: true)         // g2
    check(q.beginReview(), "review")
    var r = makeQueue()
    _ = r.restore(q.snapshot(), fileExists: { _ in true })
    check(r.pendingTagGroupId == "g2", "the review sheet comes back")
    check(r.currentGroupId == "g1", "the operator's segment stays current")
}

test("after a stale restore a new page never reuses a seq the open group already sent") {
    var q = makeQueue()
    _ = q.addDocument(fileURL: url("img_a"))                         // (g1, 1): the last snapshot that landed
    let stale = q.snapshot()
    let lost = q.addDocument(fileURL: url("img_b"))                  // (g1, 2): sent, but its save failed
    var r = makeQueue()
    _ = r.restore(stale, fileExists: { _ in true })
    r.skipSeqsAfterStaleRestore()
    _ = r.adoptOrphans([url("img_a"), url("img_b")], manifestStale: true)
    let next = r.addDocument(fileURL: url("img_c"))
    check(next.groupId == "g1" && next.seq > lost.seq, "(g1, \(next.seq)) can't replace (g1, \(lost.seq)) on the Mac")
}

test("the session writer keeps only the newest snapshot and orders a Clear") {
    var m = SessionWriteMailbox<Int>()
    check(m.offerSave(1), "the first offer starts a writer")
    check(!m.offerSave(2) && !m.offerSave(3), "later offers join it")
    if case .save(let n)? = m.take() { check(n == 3, "only the newest is written") } else { check(false, "a save") }
    check(m.take() == nil && !m.writerRunning, "drained: the writer ends")

    check(m.offerSave(4), "new writer")
    if case .save(let n)? = m.take() { check(n == 4, "writing 4") } else { check(false, "a save") }
    check(!m.offerSave(5), "5 waits while 4 is written")
    check(!m.offerClear(), "a Clear waits too")
    check(m.waitingSave == nil, "and drops the cleared session's snapshot")
    check(!m.offerSave(6), "the new session's first snapshot")
    if case .clear? = m.take() {} else { check(false, "Clear runs first") }
    if case .save(let n)? = m.take() { check(n == 6, "then the new session") } else { check(false, "a save") }
    check(m.take() == nil, "drained")
}

// W40.i-fix-ios-drive-oauth-client: the client id comes from the build, and a build without one is "not configured".
test("an unconfigured build has no Drive OAuth client") {
    for raw in [nil, "", "   ", "$(DRIVE_OAUTH_CLIENT_ID)", "YOUR_IOS_CLIENT_ID.apps.googleusercontent.com",
                ".apps.googleusercontent.com", "1234-abc", "1234 abc.apps.googleusercontent.com",
                "https://x.apps.googleusercontent.com"] as [String?] {
        check(DriveOAuthConfig(rawClientID: raw) == nil, "refused: \(raw ?? "nil")")
    }
    check(DriveOAuthConfig.current == nil, "the host binary's Info.plist carries none")
}
test("a configured client id yields its reversed-client-id redirect") {
    let c = DriveOAuthConfig(rawClientID: " 1234-abcdef.apps.googleusercontent.com\n")
    check(c?.clientID == "1234-abcdef.apps.googleusercontent.com", "trimmed")
    check(c?.redirectScheme == "com.googleusercontent.apps.1234-abcdef", "scheme")
    check(c?.redirectURI == "com.googleusercontent.apps.1234-abcdef:/oauth2redirect", "redirect URI")
}

// MARK: - Drive token storage (W40.i-fix-ios-drive-token-keychain)

/// Stands in for the Keychain: the host binary is unsigned, and an unattended Keychain prompt would hang.
final class MemoryVault: DriveTokenVault, @unchecked Sendable {
    var data: Data?
    var failWrites = false, failDeletes = false
    func read() -> Data? { data }
    func write(_ d: Data) -> Bool { if failWrites { return false }; data = d; return true }
    func delete() -> Bool { if failDeletes { return false }; data = nil; return true }
}
func scratchDefaults() -> (UserDefaults, String) {
    let name = "archive-capture-hosttest-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

test("Drive tokens are kept in the vault, not in UserDefaults, and survive a relaunch") {
    let vault = MemoryVault(); let (ud, name) = scratchDefaults(); defer { ud.removePersistentDomain(forName: name) }
    let exp = Date(timeIntervalSince1970: 2_000_000_000)
    let a = TokenStore(vault: vault, defaults: ud); a.load()
    a.update(accessToken: "AT1", refreshToken: "RT1", expiry: exp)
    check(a.persist(), "persist succeeds")
    for key in TokenStore.legacyDefaultsKeys { check(ud.object(forKey: key) == nil, "\(key) not in UserDefaults") }
    check(Array((ud.persistentDomain(forName: name) ?? [:]).keys) == [TokenStore.installMarkerKey],
          "UserDefaults holds only the install marker")
    let b = TokenStore(vault: vault, defaults: ud); b.load()
    check(b.accessToken == "AT1" && b.refreshToken == "RT1" && b.expiry == exp, "relaunch reads them back")
}
test("a refresh without a new refresh token keeps the old one in the vault") {
    let vault = MemoryVault(); let (ud, name) = scratchDefaults(); defer { ud.removePersistentDomain(forName: name) }
    let s = TokenStore(vault: vault, defaults: ud); s.load()
    s.update(accessToken: "AT1", refreshToken: "RT1", expiry: Date())
    s.persist()
    s.update(accessToken: "AT2", refreshToken: nil, expiry: Date())
    s.persist()
    let r = TokenStore(vault: vault, defaults: ud); r.load()
    check(r.accessToken == "AT2" && r.refreshToken == "RT1", "AT2 with RT1 kept")
}
test("sign-out deletes the vault item, so the next launch is signed out") {
    let vault = MemoryVault(); let (ud, name) = scratchDefaults(); defer { ud.removePersistentDomain(forName: name) }
    let s = TokenStore(vault: vault, defaults: ud); s.load()
    s.update(accessToken: "AT1", refreshToken: "RT1", expiry: Date())
    s.persist()
    s.clear()
    check(s.persist(), "delete succeeds")
    check(vault.data == nil, "item gone")
    let r = TokenStore(vault: vault, defaults: ud); r.load()
    check(r.refreshToken == nil && r.accessToken == nil, "signed out after relaunch")
}
test("a vault failure is reported, not swallowed") {
    let vault = MemoryVault(); let (ud, name) = scratchDefaults(); defer { ud.removePersistentDomain(forName: name) }
    let s = TokenStore(vault: vault, defaults: ud); s.load()
    vault.failWrites = true
    s.update(accessToken: "AT1", refreshToken: "RT1", expiry: Date())
    check(!s.persist(), "failed write returns false")
    check(s.refreshToken == "RT1", "tokens still usable this launch")
    vault.failWrites = false; s.persist(); vault.failDeletes = true; s.clear()
    check(!s.persist(), "failed delete returns false")
}
test("tokens left in UserDefaults by an older build are removed at load, never read") {
    let vault = MemoryVault(); let (ud, name) = scratchDefaults(); defer { ud.removePersistentDomain(forName: name) }
    ud.set("OLD-AT", forKey: "driveAccessToken"); ud.set("OLD-RT", forKey: "driveRefreshToken")
    ud.set(1_900_000_000.0, forKey: "driveTokenExpiry")
    let s = TokenStore(vault: vault, defaults: ud); s.load()
    for key in TokenStore.legacyDefaultsKeys { check(ud.object(forKey: key) == nil, "\(key) removed") }
    check(s.refreshToken == nil, "not carried over (no migration: no production material)")
}
test("a reinstall drops the item a deleted copy of the app left in the Keychain") {
    let vault = MemoryVault(); let (ud, name) = scratchDefaults(); defer { ud.removePersistentDomain(forName: name) }
    let s = TokenStore(vault: vault, defaults: ud); s.load()
    s.update(accessToken: "AT1", refreshToken: "RT1", expiry: Date()); s.persist()
    ud.removePersistentDomain(forName: name)   // the app is deleted: UserDefaults goes, the Keychain item stays
    let r = TokenStore(vault: vault, defaults: ud); r.load()
    check(r.refreshToken == nil && vault.data == nil, "signed out and the item deleted")
    let again = TokenStore(vault: vault, defaults: ud); again.load()
    again.update(accessToken: "AT2", refreshToken: "RT2", expiry: Date()); again.persist()
    let next = TokenStore(vault: vault, defaults: ud); next.load()
    check(next.refreshToken == "RT2", "later launches of the same install keep their sign-in")
}
test("an unreadable vault record loads as signed out") {
    let vault = MemoryVault(); let (ud, name) = scratchDefaults(); defer { ud.removePersistentDomain(forName: name) }
    ud.set(true, forKey: TokenStore.installMarkerKey); vault.data = Data("not json".utf8)
    let s = TokenStore(vault: vault, defaults: ud); s.load()
    check(s.refreshToken == nil && s.accessToken == nil && s.expiry == nil, "signed out")
}
test("the Keychain item is this-device-only, readable after first unlock") {
    let attrs = KeychainTokenVault.writeAttributes(Data("x".utf8))
    check((attrs[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
          "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly")
    check((attrs[kSecValueData as String] as? Data) == Data("x".utf8), "data set")
}

print("")
print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
