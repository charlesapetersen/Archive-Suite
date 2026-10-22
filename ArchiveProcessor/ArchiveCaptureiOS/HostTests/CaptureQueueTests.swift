import Foundation

// Host tests for the iOS companion's CaptureQueue, compiled with swiftc against the app's real
// Capture/CaptureQueue.swift, CaptureModels.swift and SessionStore.swift (scripts/test-ios-capture-queue.sh).
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
    q.endUpload(1)
    check(!q.isUploading(1) && q.beginUpload(1), "released")
    check(q.beginSegmentSend("g1") && !q.beginSegmentSend("g1"), "segment guard")
    q.endSegmentSend("g1")
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
    // CURRENT: failed pages are left out of the heartbeat. W40.i-fix-ios-heartbeat-count changes this.
    check(q.heartbeatCount == 2, "heartbeat = pending + uploading")
}

test("clear empties the session and resets the counters") {
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
    // CURRENT: ids restart at 1, so an id can be reused while an old upload is still running.
    // W40.i-fix-ios-clear-generation changes this.
    check(q.addDocument(fileURL: url("c")).id == 1, "next id is 1")
}

test("snapshot round-trips through SessionStore and restore drops confirmed items except the open segment's") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cq-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SessionStore(url: dir.appendingPathComponent("capture-session.json"))

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
    store.save(q.snapshot())

    var r = makeQueue()
    let dropped = r.restore(try XCTUnwrap(store.load()))
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
    _ = r.restore(q.snapshot())
    check(r.pendingTagGroupId == "g1" && r.currentGroupId == "g1", "mid-tagging → sheet re-opens")

    var s = q.snapshot()
    s.pendingTagGroupId = "gone"
    var r2 = makeQueue()
    _ = r2.restore(s)
    check(r2.pendingTagGroupId == nil && r2.currentGroupId == "g1", "no pages in that group → no sheet")
}

struct Missing: Error {}
func XCTUnwrap<T>(_ v: T?) throws -> T { guard let v else { throw Missing() }; return v }

print("")
print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
