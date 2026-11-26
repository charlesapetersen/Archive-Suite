#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import AppKit
import PDFKit
import ArchiveCore

/// Headless, $0 self-test of the Live Capture DATA-SAFETY invariants, gated by
/// `LIVECAPTURE_RECOVERYTEST=1` (does nothing in normal use). Uses synthetic files in a temp dir — no OCR,
/// no network, no cost, no GUI interaction — to prove the mechanisms that stop the finalize data-loss bug
/// (and its adversarial-review follow-ups) from recurring:
///   1. `executePlans` reports a segment *filed* ONLY when its PDF actually reached the destination
///      (missing/failed output → NOT filed → `finalize` keeps that source photo).
///   2. An INCOMPLETE segment (a page produced no PDF) is skipped entirely — never filed, no source deleted.
///   3. Numbering ALWAYS continues from the folder's existing max, so a retry / same-name never overwrites
///      an already-filed file.
///   4. `CaptureSession.trashOrRemove` moves a file to the Trash instead of hard-deleting it (recoverable).
///      Tests 4b–4d (W40.fix-mut-processor-trash-tests) see which primitive ran through a recording
///      FileManager, inject a failed Trash and failed moves into finalize, plant a destination collision, and
///      check that a Clear commits only with its prepare's token.
///   5. Legacy staging-manifest migration (KNOWN_ISSUES #1) drops a re-processable segment (sources present →
///      stale output deleted so resume regenerates it) but KEEPS one whose source is gone (never deletes
///      output it can no longer rebuild).
///   6. Launch-time `pruneEmptySessions` (W23.h1) reclaims ONLY a positively-identified, spent session folder
///      and only via the Trash — never the `_relay` dir + its pending objects, a HEIC-/`.jpeg`-only session,
///      a folder holding unrecognized content, or a non-session (operator) folder.
///   7. `PDFGenerator.generate` (W23.h5) REPORTS whether the PDF's image page holds the real scan or the
///      deliberate placeholder, so finalize can refuse to retire a source whose PDF carries no scan.
///   8. `sourcesSafeToRetire` (W23.h5) withholds exactly those source photos — per PAGE, on top of the
///      existing filed gate — so a placeholder-only PDF never costs the operator the original image.
///   9. Staging (W3.cap-r1) neither invents a Finder colour from a subject tag nor discards a failed tag
///      write: the app's own colour decides the label, and an artifact the tagger could not write is
///      recorded on the segment so finalize can warn instead of reporting tags that aren't on disk.
///  10. `finalize` (W3.cap-r6) reclaims the staging directory only when nothing is left staged — a
///      straggler segment that finished processing DURING the move keeps the directory (and is reported),
///      instead of having its freshly written output trashed along with the batch it missed.
///  11. A phone auto-retry after a dropped ack (W3.cap-r2) re-ingests the SAME `(groupId, seq)` page and
///      buys NO second paid OCR call — while the first call's result stays reachable from the replacement
///      photo, and genuinely distinct pages still get their own call.
///  12. An out-of-order relay Box re-pins its document to the right collection whether it lands while the
///      document is still IN FLIGHT inside finalize (W3.cap-r5) or after it has staged (W3.cap-r4) — and in
///      the second case the correction survives the end-of-session rotation review, which regenerates the
///      segment and used to write the pre-correction collection straight back over it.
///  13. A page that LEAVES the session (W3.cap-r3) — deleted in the Captured pane, or tombstoned because the
///      phone reclassified it — takes its in-flight paid OCR call with it: the call is cancelled and its
///      Task dropped, exactly one page's worth, while a page removed MID-FINALIZE deliberately keeps the
///      call finalize is about to read.
///  14. A retry (W3.cap-r3-fu2) cancels the calls it is about to make unreachable before it drops them —
///      exactly the group being retried, without touching another segment's in-flight call, and without
///      eating the fresh calls it buys to replace them. Latent in production (nothing offers a retry for a
///      segment mid-OCR, and no such group is in `failedGroupIds`); the section pins both of those too.
///  15. A group that FILES leaves the failed set with the finalized one (W3.cap-r3-fu5), so
///      `failedGroupIds ⊆ finalizedGroups` — the subset several of this subsystem's latency arguments lean
///      on — survives the one path that used to break it: a segment failed by a transient staging write
///      error, regenerated into a filable record by the end-of-session rotation review, and then filed.
///  16. The end-of-session rotation review re-derives a regenerated segment's LABEL (W3.cap-r3-fu6), so the
///      record and the row describing it cannot disagree in either direction: a segment that regenerates
///      cleanly stops being counted failed (Test 19 — otherwise the sheet warns about a segment that is fine
///      and the retry it invites re-buys the OCR), and one whose regeneration produces nothing stops wearing
///      a success label over an empty record (Test 20 — otherwise finalize skips it silently).
///  17. A retry pressed WHILE that rotation review is regenerating (W3.cap-r3-fu7) is refused — the one finish
///      state with no sheet over the Live Capture panel used to let a click re-buy the segment's OCR and race
///      the write that was about to replace its record. Refused in `retryFailed` (so the model sheet's
///      deferred Apply is covered too) and withheld from the per-item menu, and only for the length of the
///      window (Test 21).
///  18. That window's throbber scrim BLOCKS the panel deliberately (W3.cap-r3-fu10), so it is up for exactly
///      `isFinishingScrimUp` and for no other state — down when idle, down under either sheet, and back down
///      the moment the regeneration lands (Test 21 §3b). Only the COVERAGE is measurable here; whether the
///      scrim then absorbs the click is a pixel question for the VM GUI lane.
///  19. A CLEAR pressed in that same window (W3.cap-r3-fu11) refuses in BOTH halves at once — it neither
///      Trashes the sources the pending write is still reading nor empties the state that write is about to
///      publish into — and refuses only for the length of the window (Test 22).
///  20. The finish flow never STARTS while one of the Processing list's per-item sheets is up
///      (W3.cap-r3-fu9), so the rotation review is never raised as a second concurrent `.sheet` presentation:
///      a drained Finish is HELD while the sheet is open (through a full watchdog tick), the operator's
///      deferred Apply is still allowed, and closing the sheet resumes the finish with the review intact and
///      the retried segment's pages in it (Test 23).
///  21. A pending Finish has an operator-visible ESCAPE that does not cost the session its source photos
///      (W3.cap-r3-fu9-fu1): cancelling un-arms the wait and does nothing else — no OCR cancelled, no staged
///      output dropped, no file touched — it is a cancel rather than a deferral, it is not a one-way door, and
///      it works from a Captured pane that has been emptied out from under it (Test 24). (Index entry added by
///      `W3.cap-r3-fu12`, which found Test 24 missing from this list.)
///  22. An EMPTIED Captured pane still offers Finish and Clear while the session holds unfiled staged segments
///      (W3.cap-r3-fu12) — the pane's control cluster was gated on `session.photos` while the unfiled work was
///      not, so deleting the last received page stranded already-paid-for output behind an undiscoverable
///      gesture. Both controls are driven from that state end to end (Finish → files on disk; Clear → abandons
///      and leaves every processed file recoverable), the gate is measured in both directions, and an orphaned
///      in-flight row is proved not to count as processing (Test 25).
///  23. A current staging manifest restores the label its record actually earns (W3.cap-r3-fu8), rather than
///      hardcoding `.staged`: a `.noOutput` segment returns as failed and retryable, resume itself buys no OCR,
///      and only the operator's existing bulk retry starts the replacement call (Test 26).
///  24. A staging manifest is versioned and fingerprinted (W17.stg1): a valid record resumes, while tampered,
///      unversioned, missing-version/fingerprint, or unknown-version records are quarantined byte-for-byte and
///      block normal processing without touching their staged artifacts (Test 27). W40.e6 adds a seeded fuzz
///      loop over the same record — truncated, bit-flipped, spliced, nested, re-spaced: each damaged body either
///      resumes the exact record that was written or is quarantined like the hand-made cases, never a third
///      outcome (Test 27b).
///  25. Launch-time stranded-session detection (W17.det1) counts only session-shaped backup folders with a
///      nonempty canonical staging array, reports the count on the existing status line, and mutates nothing
///      in the Backup Folder (Test 28).
///  26. Local Agent provenance survives a staging-manifest reload and a rotation regeneration, so every
///      durable Live Capture PDF credits the CLI actually used rather than a gateway or direct fallback
///      (W22.localagent-provenance; Test 29).
///
/// Writes a PASS/FAIL report to `LIVECAPTURE_RECOVERYTEST_OUT` (or a temp file) + NSLog. Test scaffolding.
/// A FileManager that records which deletion primitive ran and can be told to fail (W40.fix-mut-processor-trash-tests).
/// A file gone from its path looks the same after a Trash move and a hard delete, so the driver needs to see the
/// call. Its "Trash" is a scratch folder, so nothing reaches the real Trash. Test scaffolding; single-threaded use.
final class RecoveryTestFileManager: FileManager, @unchecked Sendable {
    let fakeTrash: URL
    var failTrash = false
    var failMoveWhen: (URL) -> Bool = { _ in false }
    private(set) var trashed: [URL] = []
    private(set) var landedInTrash: [URL] = []
    private(set) var removed: [URL] = []

    init(fakeTrash: URL) { self.fakeTrash = fakeTrash; super.init() }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        trashed.append(url)
        if failTrash { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: fakeTrash, withIntermediateDirectories: true, attributes: nil)
        let dest = fakeTrash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try super.moveItem(at: url, to: dest)
        landedInTrash.append(dest)
        outResultingURL?.pointee = dest as NSURL
    }

    override func removeItem(at url: URL) throws {
        removed.append(url)
        try super.removeItem(at: url)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failMoveWhen(dstURL) { throw CocoaError(.fileWriteUnknown) }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

@MainActor
enum LiveCaptureRecoveryTestDriver {
    private static var didRun = false

    /// Read-only view of the on-disk staging manifest (W3.cap-r6). The processor's own `StagingManifest` is
    /// private, and the test only needs to know WHICH segments survived a finalize.
    struct ManifestPeek: Decodable {
        let schemaVersion: Int
        let fingerprint: String
        let staged: [LiveCaptureProcessor.StagedSegment]
    }

    /// A one-shot async gate (W3.cap-r5). Installed as the stub OCR's `_recoveryTestOCRGate`, it parks a
    /// `finalizeSegment` at its per-page await until the driver has delivered the out-of-order Box and calls
    /// `open()`. The defect lives only in that window, so the test has to *hold* the window open rather than
    /// hope a sleep lands inside it. Resuming an already-open gate is safe (a late waiter runs immediately),
    /// so a page ingested after `open()` is never stranded.
    final class TestGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened { lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
            }
        }
        func open() {
            lock.lock(); opened = true; let pending = waiters; waiters = []; lock.unlock()
            for w in pending { w.resume() }
        }
    }

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["LIVECAPTURE_RECOVERYTEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("RECOVERYTEST \(ok ? "PASS" : "FAIL"): \(name)")
        }

        let outputRoot = ProcessInfo.processInfo.environment["LIVECAPTURE_TESTOUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? fm.temporaryDirectory
        let tmp = outputRoot.appendingPathComponent("APRecoveryTest-\(UUID().uuidString)", isDirectory: true)
        let staging = tmp.appendingPathComponent("_staging", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)

        // --- Test 1: mixed plan — segment A's PDF exists, segment B's PDF was never written (the bug). ---
        let out = tmp.appendingPathComponent("out", isDirectory: true)
        let pdfA = staging.appendingPathComponent("A.pdf")
        try? Data("pdfA".utf8).write(to: pdfA)
        let pdfB = staging.appendingPathComponent("B.pdf")   // intentionally NOT created (phantom output)
        let mixed = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out, name: "Coll", appending: false, segments: [
                (groupId: "A", pdfURLs: [pdfA], imageURLs: [], jsonURL: nil, complete: true),
                (groupId: "B", pdfURLs: [pdfB], imageURLs: [], jsonURL: nil, complete: true),
            ])
        ])
        check("present-output segment A is reported filed", mixed.filedGroupIds.contains("A"))
        check("MISSING-output segment B is NOT filed (its source would be kept)", !mixed.filedGroupIds.contains("B"))
        check("movedFiles counts only the real output (1)", mixed.movedFiles == 1)
        check("allFiled is false when any segment is unfiled", mixed.allFiled == false)
        check("A.pdf actually landed in the collection folder", fm.fileExists(atPath: out.appendingPathComponent("000001 Coll.pdf").path))

        // --- Test 2: the total-loss shape — a lone segment whose PDF is missing → filedGroupIds EMPTY. ---
        let out2 = tmp.appendingPathComponent("out2", isDirectory: true)
        let missing = staging.appendingPathComponent("MISSING.pdf")   // never created
        let lone = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out2, name: "Lost", appending: false,
             segments: [(groupId: "X", pdfURLs: [missing], imageURLs: [], jsonURL: nil, complete: true)])
        ])
        check("0-moved finalize reports NO filed groups (sources all kept)", lone.filedGroupIds.isEmpty && lone.movedFiles == 0 && lone.allFiled == false)

        // --- Test 3: all outputs present → allFiled true. ---
        let out3 = tmp.appendingPathComponent("out3", isDirectory: true)
        let pdfC = staging.appendingPathComponent("C.pdf"); try? Data("pdfC".utf8).write(to: pdfC)
        let good = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out3, name: "Good", appending: false,
             segments: [(groupId: "C", pdfURLs: [pdfC], imageURLs: [], jsonURL: nil, complete: true)])
        ])
        check("all-present plan reports allFiled + the group filed", good.allFiled && good.filedGroupIds.contains("C"))

        // --- W21.e2e-fu2: the headless LAN E2E must receive the bearer its receiver actually authenticates;
        // the file-relay READY line remains on the six-character Drive token. These call the exact formatters
        // used by the two production callbacks, but do not bind a port, start USB forwarding, or write outside
        // this driver's existing scratch process. Never include either credential in a diagnostic.
        let readySession = CaptureSession()
        func readyToken(_ line: String) -> String? {
            line.split(separator: " ").first { $0.hasPrefix("token=") }.map { String($0.dropFirst(6)) }
        }
        let lanReady = readySession._testLANReadyLine(port: 43210)
        let lanReadyLog = readySession._testLANReadyLogLine(port: 43210)
        let relayReady = readySession._testFileRelayReadyLine(relayDir: tmp.appendingPathComponent("relay").path)
        check("W21.e2e-fu2: LAN READY publishes the high-entropy lanToken, never the Drive-relay token",
              readyToken(lanReady) == readySession.lanToken && readyToken(lanReady) != readySession.token)
        check("W21.e2e-fu2: LAN readiness stderr is redacted, never a second bearer sink",
              readyToken(lanReadyLog) == "[REDACTED]" && !lanReadyLog.contains(readySession.lanToken))
        check("W21.e2e-fu2: file-relay READY keeps the 6-char Drive token, never the LAN bearer",
              readyToken(relayReady) == readySession.token && readyToken(relayReady) != readySession.lanToken)

        // --- Test 5 (review finding #2): an INCOMPLETE segment (a page produced no PDF) is skipped — never
        // filed, and its (present) PDF is NOT moved, so its sources stay put. ---
        let out5 = tmp.appendingPathComponent("out5", isDirectory: true)
        let pdfD = staging.appendingPathComponent("D.pdf"); try? Data("pdfD".utf8).write(to: pdfD)
        let incomplete = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out5, name: "Partial", appending: false,
             segments: [(groupId: "D", pdfURLs: [pdfD], imageURLs: [], jsonURL: nil, complete: false)])
        ])
        check("incomplete segment is NOT filed", !incomplete.filedGroupIds.contains("D"))
        check("incomplete segment's PDF is NOT moved (stays in staging)", incomplete.movedFiles == 0 && fm.fileExists(atPath: pdfD.path))

        // --- Test 6 (review finding #1): a Finish-again retry into an ALREADY-POPULATED folder continues
        // numbering (no restart at 00001) so it never overwrites the already-filed file. ---
        let out6 = tmp.appendingPathComponent("out6", isDirectory: true)
        let pdfE1 = staging.appendingPathComponent("E1.pdf"); try? Data("E1".utf8).write(to: pdfE1)
        _ = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out6, name: "Reuse", appending: false,
             segments: [(groupId: "E1", pdfURLs: [pdfE1], imageURLs: [], jsonURL: nil, complete: true)])
        ])
        let pdfE2 = staging.appendingPathComponent("E2.pdf"); try? Data("E2".utf8).write(to: pdfE2)
        // Second finalize: SAME folder + name, "New collection" (appending:false) — must not restart at 000001.
        let retry = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out6, name: "Reuse", appending: false,
             segments: [(groupId: "E2", pdfURLs: [pdfE2], imageURLs: [], jsonURL: nil, complete: true)])
        ])
        let firstStillThere = fm.fileExists(atPath: out6.appendingPathComponent("000001 Reuse.pdf").path)
        let secondNumbered = fm.fileExists(atPath: out6.appendingPathComponent("000002 Reuse.pdf").path)
        check("retry into a populated folder does NOT overwrite the first file", firstStillThere)
        check("retry continues numbering at 000002 (no collision)", secondNumbered && retry.filedGroupIds.contains("E2"))

        // --- Test 7 (KNOWN_ISSUES #1): legacy staging-manifest migration DROPS a re-processable segment
        // (all sources present → delete its stale staged output so resume can regenerate it → a complete
        // rotation review) but KEEPS one whose source is gone (can't regenerate → preserve today's staged
        // output; NEVER delete output we can no longer rebuild). ---
        let legDir = tmp.appendingPathComponent("legacy", isDirectory: true)
        try? fm.createDirectory(at: legDir, withIntermediateDirectories: true)
        // L1: re-processable (its source still exists) — stale staged output = pdf + image + json.
        let l1pdf = legDir.appendingPathComponent("L1.pdf"); try? Data("l1".utf8).write(to: l1pdf)
        let l1img = legDir.appendingPathComponent("L1.jpg"); try? Data("l1i".utf8).write(to: l1img)
        let l1json = legDir.appendingPathComponent("L1.json"); try? Data("{}".utf8).write(to: l1json)
        let l1 = LiveCaptureProcessor.StagedSegment(groupId: "L1", type: CaptureGroupType.document.rawValue,
            collectionKey: "L1", order: 0, pdfURLs: [l1pdf], imageURLs: [l1img], jsonURL: l1json,
            boxLabelText: nil, pagesComplete: nil)
        // L2: NOT re-processable (source gone) — its stale staged output must be PRESERVED.
        let l2pdf = legDir.appendingPathComponent("L2.pdf"); try? Data("l2".utf8).write(to: l2pdf)
        let l2 = LiveCaptureProcessor.StagedSegment(groupId: "L2", type: CaptureGroupType.document.rawValue,
            collectionKey: "L2", order: 1, pdfURLs: [l2pdf], imageURLs: [], jsonURL: nil,
            boxLabelText: nil, pagesComplete: nil)
        let present: Set<String> = ["L1"]   // L1's sources are all on disk; L2's are gone
        let mig = LiveCaptureProcessor.migrateLegacyManifestSegments([l1, l2]) { present.contains($0) }
        check("legacy migration KEEPS the un-reprocessable segment (source gone)", mig.keep.map(\.groupId) == ["L2"])
        check("legacy migration DROPS the re-processable segment (source present)", !mig.keep.contains { $0.groupId == "L1" })
        check("dropped segment's stale output is DELETED (pdf+image+json)",
              !fm.fileExists(atPath: l1pdf.path) && !fm.fileExists(atPath: l1img.path) && !fm.fileExists(atPath: l1json.path))
        check("kept segment's output is PRESERVED (never delete unrecoverable output)", fm.fileExists(atPath: l2pdf.path))
        check("deleted list reports exactly the dropped segment's 3 files", Set(mig.deleted) == Set([l1pdf, l1img, l1json]))

        // --- Test 4: trashOrRemove sends a file to the Trash (leaves its original path), not a hard rm. ---
        let victim = tmp.appendingPathComponent("victim.txt")
        try? Data("bye".utf8).write(to: victim)
        let trashed = CaptureSession.trashOrRemove(victim)
        check("trashOrRemove removes the file from its original path", !fm.fileExists(atPath: victim.path))
        check("trashOrRemove reports it went to the Trash (not a fallback hard delete)", trashed)

        // --- Test 4b (W40.fix-mut-processor-trash-tests): Test 4 cannot tell a Trash move from a hard rm — the
        // file leaves its path either way — and a hard `removeItem` that returns true passed it (mutant P01).
        // A recording FileManager sees WHICH primitive ran and keeps the "Trash" in scratch, so the original
        // must be found there intact. Then the Trash is made to fail (mutant P02): the fallback must remove
        // the file and say so with `false`, never report a Trash move that did not happen.
        let rfm = RecoveryTestFileManager(fakeTrash: tmp.appendingPathComponent("fake-trash", isDirectory: true))
        let victim4b = tmp.appendingPathComponent("victim4b.txt")
        try? Data("keep me".utf8).write(to: victim4b)
        let trashed4b = CaptureSession.trashOrRemove(victim4b, rfm)
        check("W40 P01: trashOrRemove uses trashItem, never removeItem, when the Trash works",
              trashed4b && rfm.trashed.map(\.lastPathComponent) == ["victim4b.txt"] && rfm.removed.isEmpty)
        check("W40 P01: the original is recoverable — found in the Trash, contents intact",
              rfm.landedInTrash.count == 1
                && (try? Data(contentsOf: rfm.landedInTrash[0])) == Data("keep me".utf8)
                && !fm.fileExists(atPath: victim4b.path))
        let rfmFail = RecoveryTestFileManager(fakeTrash: tmp.appendingPathComponent("fake-trash-fail", isDirectory: true))
        rfmFail.failTrash = true
        let victim4c = tmp.appendingPathComponent("victim4c.txt")
        try? Data("no trash here".utf8).write(to: victim4c)
        let trashed4c = CaptureSession.trashOrRemove(victim4c, rfmFail)
        check("W40 P02: a failed Trash move returns false (fell back), never claims the Trash",
              trashed4c == false && rfmFail.trashed.count == 1)
        check("W40 P02: the fallback removes the file rather than leave it half-deleted",
              !fm.fileExists(atPath: victim4c.path) && rfmFail.removed.map(\.lastPathComponent) == ["victim4c.txt"])

        // --- Test 4c (W40.fix-mut-processor-trash-tests): the finalize move under injected failures.
        // P12 — a PDF whose move FAILS must not count as landed: the group is not filed, so its source photo is
        //       kept, and the PDF is still in staging.
        let out4p = tmp.appendingPathComponent("out4p", isDirectory: true)
        let pdfF = staging.appendingPathComponent("F.pdf"); try? Data("pdfF".utf8).write(to: pdfF)
        let rfmPdf = RecoveryTestFileManager(fakeTrash: tmp.appendingPathComponent("fake-trash-p12", isDirectory: true))
        rfmPdf.failMoveWhen = { $0.pathExtension == "pdf" }
        let pdfFailed = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out4p, name: "Stuck", appending: false,
             segments: [(groupId: "F", pdfURLs: [pdfF], imageURLs: [], jsonURL: nil, complete: true)])
        ], fm: rfmPdf)
        check("W40 P12: a failed PDF move is counted failed and its group is NOT filed",
              pdfFailed.failedMoves == 1 && pdfFailed.movedFiles == 0 && pdfFailed.filedGroupIds.isEmpty
                && !pdfFailed.allFiled && fm.fileExists(atPath: pdfF.path))
        // P08 — every group files (its PDF landed) but a secondary move (the JSON) failed: that is NOT
        //       "all filed", since the caller reclaims staging on allFiled and the JSON is still in it.
        let out4j = tmp.appendingPathComponent("out4j", isDirectory: true)
        let pdfG = staging.appendingPathComponent("G.pdf"); try? Data("pdfG".utf8).write(to: pdfG)
        let jsonG = staging.appendingPathComponent("G.json"); try? Data("{}".utf8).write(to: jsonG)
        let rfmJson = RecoveryTestFileManager(fakeTrash: tmp.appendingPathComponent("fake-trash-p08", isDirectory: true))
        rfmJson.failMoveWhen = { $0.pathExtension == "json" }
        let jsonFailed = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out4j, name: "Half", appending: false,
             segments: [(groupId: "G", pdfURLs: [pdfG], imageURLs: [], jsonURL: jsonG, complete: true)])
        ], fm: rfmJson)
        check("W40 P08: every group filed but a move failed is NOT allFiled",
              jsonFailed.filedGroupIds == ["G"] && jsonFailed.failedMoves == 1 && jsonFailed.allFiled == false
                && fm.fileExists(atPath: jsonG.path))
        // P11 — a destination collision. Numbering continues from the collection folder's highest number, but
        //       `JSON Output/` is not counted, so a stray `000001 <name>.json` there collides with the next
        //       segment's JSON. The displaced file must go to the Trash (recoverable), never a hard delete.
        let out4c = tmp.appendingPathComponent("out4c", isDirectory: true)
        let jsonDir4c = out4c.appendingPathComponent("JSON Output", isDirectory: true)
        try? fm.createDirectory(at: jsonDir4c, withIntermediateDirectories: true)
        let displaced = jsonDir4c.appendingPathComponent("000001 Clash.json")
        try? Data("old json".utf8).write(to: displaced)
        let pdfH = staging.appendingPathComponent("H.pdf"); try? Data("pdfH".utf8).write(to: pdfH)
        let jsonH = staging.appendingPathComponent("H.json"); try? Data("new json".utf8).write(to: jsonH)
        let rfmClash = RecoveryTestFileManager(fakeTrash: tmp.appendingPathComponent("fake-trash-p11", isDirectory: true))
        let clash = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out4c, name: "Clash", appending: false,
             segments: [(groupId: "H", pdfURLs: [pdfH], imageURLs: [], jsonURL: jsonH, complete: true)])
        ], fm: rfmClash)
        check("W40 P11: the collision really happened and the new JSON took the slot",
              clash.allFiled && (try? Data(contentsOf: displaced)) == Data("new json".utf8))
        check("W40 P11: a displaced destination goes to the Trash, never a hard delete",
              rfmClash.trashed.map(\.lastPathComponent) == ["000001 Clash.json"] && rfmClash.removed.isEmpty
                && rfmClash.landedInTrash.count == 1
                && (try? Data(contentsOf: rfmClash.landedInTrash[0])) == Data("old json".utf8))

        // --- Test 4d (W40.fix-mut-processor-trash-tests, mutant P06): a Clear commits only with the token its
        // prepare wrote. A stale token is refused and leaves the transaction prepared, so recovery still
        // restores the photos; only the matching token commits. Manifest writes go nowhere: this session
        // proves the token guard alone and touches no session folder.
        let tokenSession = CaptureSession()
        tokenSession.manifestWriteOverride = { _, _ in true }
        let prepared4d = tokenSession.prepareClear(token: "token-A")
        let staleCommit = tokenSession.commitPreparedClear(token: "token-B")
        check("W40 P06: a Clear commit with a stale token is refused and stays prepared",
              prepared4d && !staleCommit && tokenSession.clearPhase == "prepared" && tokenSession.clearToken == "token-A")
        let goodCommit = tokenSession.commitPreparedClear(token: "token-A")
        check("W40 P06: the matching token commits", goodCommit && tokenSession.clearPhase == "committed")
        tokenSession.restoreManifestAfterClearFailure()
        tokenSession.manifestWriteOverride = nil

        // --- Test 8 (W23.h1): launch-time pruneEmptySessions must never hard-delete non-session or
        // recoverable content. It reclaims ONLY positively-identified, spent session folders, via the Trash.
        // Fixtures cover all five failure cases from the finding + happy-path regression guards. ---
        let pruneRoot = tmp.appendingPathComponent("prune", isDirectory: true)
        let tk = String(UUID().uuidString.prefix(8))   // unique suffix → safe Trash lookup + cleanup
        func mk(_ rel: String, _ body: String = "x") {
            let u = pruneRoot.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(body.utf8).write(to: u)
        }
        func survives(_ rel: String) -> Bool { fm.fileExists(atPath: pruneRoot.appendingPathComponent(rel).path) }
        let spent = "2026-07-04T10-00-00Z-\(tk)"   // spent session: only a manifest left → RECLAIM
        let empty = "2026-07-05T10-00-00Z-\(tk)"   // genuinely-empty session → RECLAIM
        mk("_relay/AB12CD/photo-0001.json", "{}")                    // (1) pending relay object — KEEP
        mk("2026-07-01T10-00-00Z-\(tk)/IMG_0001.heic")              // (2) HEIC-only session — KEEP
        mk("2026-07-02T10-00-00Z-\(tk)/IMG_0002.jpeg")             // (3) .jpeg-only session — KEEP
        mk("2026-07-03T10-00-00Z-\(tk)/manifest.json", "{}")        // (4) unknown-content session — KEEP
        mk("2026-07-03T10-00-00Z-\(tk)/recovery.journal", "notes")
        mk("\(spent)/manifest.json", "{}")
        try? fm.createDirectory(at: pruneRoot.appendingPathComponent(empty, isDirectory: true), withIntermediateDirectories: true)
        mk("2026-07-06T10-00-00Z-\(tk)/IMG_0003.jpg")              // (6) classic .jpg session — KEEP
        mk("2026-07-07T10-00-00Z-\(tk)/_processed/00001 Coll.pdf") // (7) staged _processed output — KEEP
        mk("My Notes/whatever.txt")                                  // (8) non-session operator folder — KEEP
        let reclaimed = Set(CaptureSession.pruneEmptySessions(under: pruneRoot).map { $0.lastPathComponent })
        check("prune KEEPS the relay dir + its pending object", survives("_relay/AB12CD/photo-0001.json"))
        check("prune KEEPS a HEIC-only session (recoverable source)", survives("2026-07-01T10-00-00Z-\(tk)/IMG_0001.heic"))
        check("prune KEEPS a .jpeg-only session (recoverable source)", survives("2026-07-02T10-00-00Z-\(tk)/IMG_0002.jpeg"))
        check("prune KEEPS a session with unrecognized content", survives("2026-07-03T10-00-00Z-\(tk)/recovery.journal"))
        check("prune KEEPS a .jpg session (happy-path regression)", survives("2026-07-06T10-00-00Z-\(tk)/IMG_0003.jpg"))
        check("prune KEEPS a session with staged _processed output", survives("2026-07-07T10-00-00Z-\(tk)/_processed/00001 Coll.pdf"))
        check("prune KEEPS a non-session operator folder", survives("My Notes/whatever.txt"))
        check("prune RECLAIMS the spent manifest-only session", !survives(spent) && reclaimed.contains(spent))
        check("prune RECLAIMS the genuinely-empty session", !survives(empty) && reclaimed.contains(empty))
        check("prune reclaims ONLY the two spent sessions", reclaimed == Set([spent, empty]))
        // (d) recoverability: prune's ONLY deletion path is `trashOrRemove` (Trash → Put Back), never a hard
        // `removeItem`, so the reclaims above (spent + empty, gone from root) are Finder-recoverable. Prove
        // that path actually trashes a DIRECTORY in this runtime: trashItem returning success means the folder
        // went to the Trash (recoverable), not deleted. We assert the success/return contract rather than
        // scanning a guessed `~/.Trash` — the physical Trash location varies under the app's launch context.
        let dprobe = pruneRoot.appendingPathComponent("2026-07-09T09-09-09Z-\(tk)DP", isDirectory: true)
        try? fm.createDirectory(at: dprobe, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: dprobe.appendingPathComponent("manifest.json"))
        var probeDest: NSURL?
        let dpTrashed = (try? fm.trashItem(at: dprobe, resultingItemURL: &probeDest)) != nil
        check("reclaim path trashes a directory to the Trash — recoverable, not a hard delete",
              dpTrashed && !fm.fileExists(atPath: dprobe.path))
        if let dest = probeDest.map({ $0 as URL }) { try? fm.removeItem(at: dest) }   // tidy the probe

        // --- Test 9 (W23.h5): `PDFGenerator.generate` must REPORT whether the image page holds the real scan
        // or the deliberate placeholder. The placeholder stays (it preserves the 2-page archival contract and
        // PDFTextExtractor's pageCount>=2 heuristic) — the defect was that it is indistinguishable from
        // success, so finalize retires a source whose only image copy is the source itself. ---
        let gen = PDFGenerator()
        let genDir = tmp.appendingPathComponent("pdfgen", isDirectory: true)
        try? fm.createDirectory(at: genDir, withIntermediateDirectories: true)
        let ocr = OCRResult(text: "page text", classification: nil, errorMessage: nil, errorCode: nil)
        // Constructed inline (not pulled from a catalogue array) so the test can't break when the shipped
        // model list changes — `generate` only prints this on the text page.
        let stubModel = LLMModel(id: "test-model", displayName: "Test Model", provider: .gemini,
                                 supportsThinking: false, returnsMd: false,
                                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)

        // (a) A real, decodable image → `.embedded`. Written here (not a checked-in fixture) so the test
        // needs nothing on disk and can never touch the corpus.
        let realJPEG = genDir.appendingPathComponent("real.jpg")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let jpegData = bitmap?.representation(using: .jpeg, properties: [:]) {
            try? jpegData.write(to: realJPEG)
        }
        let realOut = genDir.appendingPathComponent("real.pdf")
        let realOutcome = try? gen.generate(imageURL: realJPEG, result: ocr, model: stubModel, outputURL: realOut)
        check("generate reports .embedded for a decodable image", realOutcome == .embedded)
        check("the embedded-image PDF still wrote 2 pages", PDFDocument(url: realOut)?.pageCount == 2)

        // (b) A file that is NOT a decodable image → `.placeholder`, and the PDF is STILL written with both
        // pages (the placeholder is deliberate — do not delete it; just make it detectable).
        let junk = genDir.appendingPathComponent("corrupt.jpg")
        try? Data("this is not a JPEG".utf8).write(to: junk)
        let junkOut = genDir.appendingPathComponent("corrupt.pdf")
        let junkOutcome = try? gen.generate(imageURL: junk, result: ocr, model: stubModel, outputURL: junkOut)
        check("generate reports .placeholder for an undecodable image", junkOutcome == .placeholder)
        check("placeholder outcome is flagged by isPlaceholder", junkOutcome?.isPlaceholder == true)
        check("the placeholder PDF is STILL written (2-page contract preserved)",
              fm.fileExists(atPath: junkOut.path) && PDFDocument(url: junkOut)?.pageCount == 2)

        // (c) The pre-fix detector — "the PDF exists" — cannot tell (a) from (b). This is what made the bug
        // silent, and asserting it keeps the new signal from being quietly replaced by a file-existence check.
        check("file-existence alone does NOT distinguish a placeholder from a real scan",
              fm.fileExists(atPath: realOut.path) && fm.fileExists(atPath: junkOut.path)
                  && realOutcome != junkOutcome)

        // --- Test 10 (W23.h5): the source-retirement gate. A filed segment's source photo is retired ONLY
        // if its own page's PDF holds the real scan. A placeholder image page means the PDF has no image, so
        // the photo is the last copy and must survive finalize — while its normally-embedded siblings are
        // still retired (per-page, not per-segment). This is the decision `finalize` makes on the real path;
        // it is a pure function precisely so it can be proven here without a session, OCR, or the GUI. ---
        func src(_ n: String) -> URL { tmp.appendingPathComponent(n) }
        let p1 = src("p1.jpg"), p2 = src("p2.jpg"), p3 = src("p3.jpg"), q1 = src("q1.jpg")

        // (a) THE BUG: a lone filed page whose PDF is placeholder-only. Pre-fix this source was trashed.
        let onlyPlaceholder = LiveCaptureProcessor.sourcesSafeToRetire(
            filedGroups: ["G"], sourcesByGroup: ["G": [p1]], placeholderSourcesByGroup: ["G": [p1]])
        check("a filed placeholder-only PDF does NOT retire its source photo", onlyPlaceholder.isEmpty)

        // (b) Per-page, not per-segment: siblings that embedded fine are still retired.
        let mixedPages = LiveCaptureProcessor.sourcesSafeToRetire(
            filedGroups: ["G"], sourcesByGroup: ["G": [p1, p2, p3]], placeholderSourcesByGroup: ["G": [p2]])
        check("the placeholder page's source is withheld", !mixedPages.contains(p2))
        check("its normally-embedded siblings are still retired", mixedPages == Set([p1, p3]))

        // (c) Happy path unchanged: no placeholders → every source of a filed segment is retired.
        let allEmbedded = LiveCaptureProcessor.sourcesSafeToRetire(
            filedGroups: ["G"], sourcesByGroup: ["G": [p1, p2]], placeholderSourcesByGroup: [:])
        check("no placeholder → all sources of a filed segment are retired (regression)",
              allEmbedded == Set([p1, p2]))

        // (d) The pre-existing filed gate still dominates: an UNFILED segment retires nothing, placeholder
        // or not. The two gates are AND-ed, so neither can be weakened by the other.
        let unfiled = LiveCaptureProcessor.sourcesSafeToRetire(
            filedGroups: [], sourcesByGroup: ["G": [p1, p2]], placeholderSourcesByGroup: [:])
        check("an UNFILED segment retires nothing (existing gate intact)", unfiled.isEmpty)

        // (e) Multi-segment: withholding in one filed segment must not leak into another.
        let twoGroups = LiveCaptureProcessor.sourcesSafeToRetire(
            filedGroups: ["G", "H"], sourcesByGroup: ["G": [p1], "H": [q1]],
            placeholderSourcesByGroup: ["G": [p1]])
        check("withholding is scoped to its own segment", twoGroups == Set([q1]))

        // (f) A legacy manifest carries no `placeholderSources` at all (nil → absent key): behaviour is
        // exactly the old one, so an upgrade can't silently strand every pre-existing staged session.
        let legacy = LiveCaptureProcessor.sourcesSafeToRetire(
            filedGroups: ["G"], sourcesByGroup: ["G": [p1, p2]], placeholderSourcesByGroup: ["H": [q1]])
        check("a legacy segment (no placeholder record) behaves exactly as before", legacy == Set([p1, p2]))

        // --- Test 11 (W23.h5): the WIRING. Tests 9 and 10 prove the detector and the gate independently;
        // this proves they are actually connected — that staging a real segment from real image files
        // records the undecodable page (and only it) in `placeholderSources`, which is what `finalize`
        // feeds to `sourcesSafeToRetire`. Without this a correct detector and a correct gate could still
        // be joined by nothing. ---
        let stageDir = tmp.appendingPathComponent("wire", isDirectory: true)
        try? fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        let goodSrc = stageDir.appendingPathComponent("good.jpg")
        let badSrc = stageDir.appendingPathComponent("bad.jpg")
        if let jpegData = bitmap?.representation(using: .jpeg, properties: [:]) {
            try? jpegData.write(to: goodSrc)
        }
        try? Data("not an image".utf8).write(to: badSrc)
        let wired = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [goodSrc, badSrc], stagingDir: stageDir, model: stubModel)
        check("staging both pages produces both PDFs (segment stays page-complete)",
              wired.pdfCount == 2 && wired.pagesComplete == true)
        check("the undecodable page's SOURCE is recorded as placeholder-backed",
              wired.placeholderSources == [badSrc])
        // And end-to-end: feeding that straight into the gate withholds exactly that photo.
        let endToEnd = LiveCaptureProcessor.sourcesSafeToRetire(
            filedGroups: ["T"], sourcesByGroup: ["T": [goodSrc, badSrc]],
            placeholderSourcesByGroup: ["T": wired.placeholderSources])
        check("end-to-end: finalize would retire the good photo and KEEP the unembeddable one",
              endToEnd == Set([goodSrc]))

        // --- Test 12 (W3.cap-r1): the Finder-tag write on a staged artifact. TWO defects shared these three
        // lines, so both are proven here. (i) The colour was INFERRED from the text — a raw `[String]` made
        // `applyTags` hunt for "Red"/"Purple" anywhere in the array, so a document whose subject really is
        // "Red" was promoted to a Finder colour label and lost "Red" as a searchable subject. (ii) The write
        // RESULT was discarded (`_ = try?`), so an xattr/permission/coordination failure left the segment
        // staged and finalized as though tagged — a file the Reader's tag triage can never surface. ---
        let tagDir = tmp.appendingPathComponent("tagwrite", isDirectory: true)
        try? fm.createDirectory(at: tagDir, withIntermediateDirectories: true)
        func makeJPEG(_ name: String, in dir: URL) -> URL {
            let u = dir.appendingPathComponent(name)
            if let d = bitmap?.representation(using: .jpeg, properties: [:]) { try? d.write(to: u) }
            return u
        }
        func tagsOf(_ u: URL) -> [String] {
            if case .success(let names, _) = TagReading.read(u) { return names }
            return []
        }
        // A cleared label reads back as 0 or absent depending on the write path; both mean "no colour".
        func labelOf(_ u: URL) -> Int {
            if case .success(_, let label) = TagReading.read(u) { return label ?? 0 }
            return -1
        }

        // (a) THE COLOUR BUG. A plain document whose subject tag is literally "Red" — the app assigned no
        // colour, so nothing here may become one.
        let redDoc = makeJPEG("redscare.jpg", in: tagDir)
        let redSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [redDoc], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: ["1948", "Red"],
            jsonTags: GeneratedTags(subjectTags: ["Red"]), stampUnread: true)
        let redPDF = redSeg.pdfURLs.first ?? tagDir
        check("a subject tag that is literally \"Red\" survives as a searchable tag",
              tagsOf(redPDF).contains("Red") && tagsOf(redPDF).contains("1948"))
        check("...and is NOT promoted to a Finder colour label (the app assigned no colour)",
              labelOf(redPDF) == 0)

        // The Live Capture staging path accepts only the q7 Quality field. This drives the real
        // PageWork.quality → staged-PDF writer.
        let qualityDoc = makeJPEG("quality.jpg", in: tagDir)
        let qualitySeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [qualityDoc], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: ["1948"], pageQuality: "Q3",
            jsonTags: GeneratedTags(), stampUnread: true)
        let qualityPDF = qualitySeg.pdfURLs.first ?? tagDir
        check("Live Capture writes phone Q3 as Quality",
              tagsOf(qualityPDF).contains("Q3"))

        // W19.q6: a Mac card's human-selected Quality travels through GeneratedTags, every live
        // artifact writer, and the real finalize mover. The Q3 page-rating input below mirrors the
        // `CaptureSession` handoff after the durable card decision; it is intentionally not a phone P.
        let selectedQualityDoc = makeJPEG("selected-quality.jpg", in: tagDir)
        let selectedQualityTags = GeneratedTags(subjectTags: ["oral history"], quality: 3)
        let selectedQualitySeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [selectedQualityDoc], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: selectedQualityTags.allTags, pageQuality: "Q3",
            jsonTags: selectedQualityTags, stampUnread: true, outputImageFile: true)
        check("W19.q6: user-selected Q3 reaches both staged PDF and image mirror without P",
              (selectedQualitySeg.pdfURLs + selectedQualitySeg.imageURLs).count == 2
              && (selectedQualitySeg.pdfURLs + selectedQualitySeg.imageURLs).allSatisfy {
                  tagsOf($0).contains("Q3") && !tagsOf($0).contains(where: { $0.hasPrefix("P") })
              })
        let selectedQualityOut = tmp.appendingPathComponent("selected-quality-final", isDirectory: true)
        let selectedQualityFinal = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: selectedQualityOut, name: "Selected Quality", appending: false, segments: [
                (groupId: "Q3", pdfURLs: selectedQualitySeg.pdfURLs,
                 imageURLs: selectedQualitySeg.imageURLs, jsonURL: nil, complete: true)
            ])
        ])
        let finalizedQualityArtifacts = ["000001 Selected Quality.pdf", "000001 Selected Quality.jpg"]
            .map { selectedQualityOut.appendingPathComponent($0) }
        check("W19.q6: Q3 survives the Live Capture finalize move on PDF and image mirror",
              selectedQualityFinal.filedGroupIds == ["Q3"]
              && finalizedQualityArtifacts.allSatisfy { tagsOf($0).contains("Q3") })

        // OCR failure is not a Quality decision. The failure-only tag branch must retain the human
        // choice on the staged artifact rather than returning before it appends Q.
        let failedQualityDoc = makeJPEG("failed-quality.jpg", in: tagDir)
        let failedQualityTags = GeneratedTags(ocrFailed: true, quality: 2)
        let failedQualitySeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [failedQualityDoc], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: failedQualityTags.allTags, pageQuality: "Q2",
            jsonTags: failedQualityTags, stampUnread: true)
        check("W19.q6: OCR failure retains the user-selected Q2 on its staged PDF",
              failedQualitySeg.pdfURLs.allSatisfy {
                  tagsOf($0).contains("OCR Failed") && tagsOf($0).contains("Q2")
              })

        // A skipped card keeps the phone values. Per-page Q3 is an explicit override of the
        // group's first-page Q1, so the one merged artifact must carry Q3 rather than Q1.
        let mergeQualityA = makeJPEG("merge-quality-a.jpg", in: tagDir)
        let mergeQualityB = makeJPEG("merge-quality-b.jpg", in: tagDir)
        let mergeQualitySeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [mergeQualityA, mergeQualityB], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: ["1948"], jsonTags: GeneratedTags(),
            stampUnread: true, doMerge: true, pageQualities: ["Q1", "Q3"])
        check("W19.q7: a later phone Q3 wins over first-page Q1 on the merged PDF",
              mergeQualitySeg.pdfURLs.count == 1
              && tagsOf(mergeQualitySeg.pdfURLs[0]).contains("Q3")
              && !tagsOf(mergeQualitySeg.pdfURLs[0]).contains(where: { $0.hasPrefix("P") }))

        // This must also hold when the Writer's copy-source/no-tagging semantics would otherwise pass
        // supplied names through verbatim. Q2 is a phone value, not a source tag.
        let copyQualityDoc = makeJPEG("copy-quality.jpg", in: tagDir)
        let copyQualitySeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [copyQualityDoc], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: ["1948"], pageQuality: "Q2",
            jsonTags: GeneratedTags(), stampUnread: false)
        let copyQualityPDF = copyQualitySeg.pdfURLs.first ?? tagDir
        check("copy-source staging applies phone Q2",
              tagsOf(copyQualityPDF).contains("Q2"))

        // The same boundary feeds the merged PDF. Q0 is internal-only explicit unrated, so it clears a
        // generated Q rather than escaping as a subject or retaining a stale rating through the merge.
        let clearQualityA = makeJPEG("clear-quality-a.jpg", in: tagDir)
        let clearQualityB = makeJPEG("clear-quality-b.jpg", in: tagDir)
        let clearQualitySeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [clearQualityA, clearQualityB], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: ["1948", "Q2"], pageQuality: "Q0",
            jsonTags: GeneratedTags(), stampUnread: false, doMerge: true)
        let clearQualityPDF = clearQualitySeg.pdfURLs.first ?? tagDir
        check("copy-source merge treats explicit zero quality as a clear without writing Q0",
              !tagsOf(clearQualityPDF).contains(where: DocumentTags.isRatingToken)
              && tagsOf(clearQualityPDF).contains("1948"))

        // W40.fix-live-vision-drops-card-tags — No tagging writes no GENERATED tag, but what a person set is
        // not generated. The phone's Q3 alone reaches the staged PDF, with no Unread.
        let noTagQualityDoc = makeJPEG("no-tag-quality.jpg", in: tagDir)
        let noTagQualitySeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [noTagQualityDoc], stagingDir: tagDir, model: stubModel,
            type: .document, pageQuality: "Q3", jsonTags: GeneratedTags(),
            stampUnread: false, taggingMode: TaggingMode.none)
        let noTagQualityPDF = noTagQualitySeg.pdfURLs.first ?? tagDir
        check("no-tagging staging writes the phone's Q3, and nothing else",
              tagsOf(noTagQualityPDF) == ["Q3"] && noTagQualitySeg.untaggedOutputs.isEmpty)

        // The card's subject, year and Q2 (the values `finalizeSegment` builds for No tagging) reach the
        // PDF, its image mirror and a merged PDF, with no Unread and no colour label.
        let noTagCard = GeneratedTags(year: "1973", subjectTags: ["W40d5 Dean Alpha"], quality: 2)
        let noTagCardA = makeJPEG("no-tag-card-a.jpg", in: tagDir)
        let noTagCardSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [noTagCardA], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: noTagCard.allTags, pageQuality: "Q2", jsonTags: noTagCard,
            stampUnread: false, taggingMode: TaggingMode.none, outputImageFile: true)
        let noTagCardArtifacts = noTagCardSeg.pdfURLs + noTagCardSeg.imageURLs
        check("no-tagging staging writes the tag card's subject, year and Q2 to the PDF and image mirror",
              noTagCardArtifacts.count == 2 && noTagCardArtifacts.allSatisfy {
                  Set(tagsOf($0)) == ["1973", "W40d5 Dean Alpha", "Q2"] && labelOf($0) == 0
              })
        let noTagMergeA = makeJPEG("no-tag-merge-a.jpg", in: tagDir)
        let noTagMergeB = makeJPEG("no-tag-merge-b.jpg", in: tagDir)
        let noTagMergeSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [noTagMergeA, noTagMergeB], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: noTagCard.allTags, jsonTags: noTagCard,
            stampUnread: false, taggingMode: TaggingMode.none, doMerge: true, pageQualities: ["Q2", "Q2"])
        check("no-tagging staging writes the card's tags to a merged PDF too",
              noTagMergeSeg.pdfURLs.count == 1
              && Set(tagsOf(noTagMergeSeg.pdfURLs[0])) == ["1973", "W40d5 Dean Alpha", "Q2"])

        // A card saved at 0 over a phone Q2 is the operator clearing it: the page input is the Q0 clear,
        // and through the real writer the PDF carries no rating. A skipped card leaves the phone's value.
        let clearedQuality = LiveCaptureProcessor.pageQuality(card: 0, phone: "Q2")
        check("a card saved at Quality 0 overrides the phone's Q2 with the Q0 clear",
              clearedQuality == "Q0" && LiveCaptureProcessor.pageQuality(card: nil, phone: "Q2") == "Q2"
              && LiveCaptureProcessor.pageQuality(card: 3, phone: "Q1") == "Q3")
        let clearedDoc = makeJPEG("no-tag-cleared.jpg", in: tagDir)
        let clearedSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [clearedDoc], stagingDir: tagDir, model: stubModel,
            type: .document, baseTags: ["1973"], pageQuality: clearedQuality, jsonTags: GeneratedTags(),
            stampUnread: false, taggingMode: TaggingMode.none)
        check("...and its PDF is written with the card's other values and no rating",
              (clearedSeg.pdfURLs.first.map(tagsOf) ?? []) == ["1973"])

        // A skipped card with no phone values: nothing a person set, so no Finder metadata write at all.
        let noTagBareDoc = makeJPEG("no-tag-bare.jpg", in: tagDir)
        let noTagBareSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [noTagBareDoc], stagingDir: tagDir, model: stubModel,
            type: .document, jsonTags: GeneratedTags(), stampUnread: false, taggingMode: TaggingMode.none)
        let noTagBarePDF = noTagBareSeg.pdfURLs.first ?? tagDir
        check("no-tagging staging with nothing set writes no tag xattr at all",
              getxattr(noTagBarePDF.path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0) < 0)

        // (b) The app's OWN colour still lands. A box segment carries Red as an actual Finder label, exactly
        // once — proving (a) narrowed the colour source rather than disabling colouring altogether.
        let boxSrc = makeJPEG("boxlabel.jpg", in: tagDir)
        let boxSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [boxSrc], stagingDir: tagDir, model: stubModel,
            type: .box, baseTags: ["Box", "Red"],
            jsonTags: GeneratedTags(subjectTags: ["Box"], colorTag: "Red"), stampUnread: true)
        let boxPDF = boxSeg.pdfURLs.first ?? tagDir
        check("a box segment still gets the Finder RED label from the app's own colour", labelOf(boxPDF) == 6)
        check("...and \"Red\" appears exactly once in its tags",
              tagsOf(boxPDF).filter { $0 == "Red" }.count == 1)
        // W40.suite-item-types: with no colour chosen (the default), a box is its Box token and no label.
        let plainBoxSrc = makeJPEG("boxlabel-plain.jpg", in: tagDir)
        let plainBoxSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [plainBoxSrc], stagingDir: tagDir, model: stubModel,
            type: .box, baseTags: ["Box"],
            jsonTags: GeneratedTags(subjectTags: ["Box"], colorTag: nil), stampUnread: true)
        let plainBoxPDF = plainBoxSeg.pdfURLs.first ?? tagDir
        check("a box with no colour chosen carries its Box token and no Finder label",
              tagsOf(plainBoxPDF).contains("Box") && labelOf(plainBoxPDF) == 0
              && DocumentTags.parse(raw: tagsOf(plainBoxPDF), labelNumber: nil).itemType == .box)

        // (c) No false positives: a write that succeeded records nothing, and the tags really are on disk.
        check("a successful staging reports no untagged artifact",
              redSeg.untaggedOutputs.isEmpty && boxSeg.untaggedOutputs.isEmpty)
        check("the tags the segment claims are genuinely ON DISK", tagsOf(redPDF).last == "Unread")

        // (d) THE DISCARDED-FAILURE BUG, at the production seam. `uchg` makes the artifact genuinely
        // un-writable, which is the permission class the old `try?` erased.
        let locked = tagDir.appendingPathComponent("locked.pdf")
        try? fm.copyItem(at: realOut, to: locked)
        try? fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        let lockedVerdict = LiveCaptureProcessor._recoveryTestTagArtifact(
            ["1948", "Correspondence"], at: locked, appColor: nil, stampUnread: true)
        check("a tag write the filesystem refuses is reported FAILED, not swallowed", lockedVerdict == false)
        check("...and the refusal was real — the file carries no tags", tagsOf(locked).isEmpty)
        try? fm.setAttributes([.immutable: false], ofItemAtPath: locked.path)   // so `tmp` can be removed

        // (e) The WIRING: that verdict has to reach the manifest. Lock a newly generated PDF only for
        // its real tag write, so the fixture can distinguish that warning from a failed generation.
        let wireTagDir = tmp.appendingPathComponent("tagwire", isDirectory: true)
        try? fm.createDirectory(at: wireTagDir, withIntermediateDirectories: true)
        let lockedSrc = makeJPEG("held.jpg", in: wireTagDir)
        let lockedOut = wireTagDir.appendingPathComponent("held.pdf")
        let lockedSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [lockedSrc], stagingDir: wireTagDir, model: stubModel,
            type: .document, baseTags: ["1948"], jsonTags: GeneratedTags(), stampUnread: true
        ) { tags, url, colour, unread in
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }
            return LiveCaptureProcessor._recoveryTestTagArtifact(tags, at: url, appColor: colour, stampUnread: unread)
        }
        check("an un-taggable staged artifact is recorded on the segment (the wiring)",
              lockedSeg.pdfCount == 1 && lockedSeg.untaggedOutputs == [lockedOut])

        try? fm.setAttributes([.immutable: true], ofItemAtPath: lockedOut.path)
        let blockedGeneration = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [lockedSrc], stagingDir: wireTagDir, model: stubModel)
        check("a refused write cannot reuse a stale staged PDF", blockedGeneration.pdfCount == 0)
        try? fm.setAttributes([.immutable: false], ofItemAtPath: lockedOut.path)

        // (f) The merge path tags the MERGED file and reports nothing spurious — the constituents it deletes
        // must not linger in the record as artifacts that no longer exist.
        let mergeDir = tmp.appendingPathComponent("tagmerge", isDirectory: true)
        try? fm.createDirectory(at: mergeDir, withIntermediateDirectories: true)
        let m1 = makeJPEG("m1.jpg", in: mergeDir), m2 = makeJPEG("m2.jpg", in: mergeDir)
        let mergedSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [m1, m2], stagingDir: mergeDir, model: stubModel,
            type: .document, baseTags: ["1948"], jsonTags: GeneratedTags(),
            stampUnread: true, doMerge: true)
        check("merging leaves exactly one staged PDF and no stale untagged record",
              mergedSeg.pdfURLs.count == 1 && mergedSeg.untaggedOutputs.isEmpty)
        check("the merged PDF is the one that carries the tags",
              mergedSeg.pdfURLs.first.map { tagsOf($0).contains("1948") } == true)

        // --- Test 13 (W3.cap-r6): finalize must not reclaim the staging directory while it still holds
        // output nothing else has a copy of. `plans` is snapshotted BEFORE the `executePlans` await; a
        // segment whose processing finishes inside that window writes fresh output into the SAME staging
        // dir and appends itself to `staged` without ever being in `plans` — so `allFiled`, which reports
        // only on the planned segments, stays true. Trashing on that alone threw the straggler's processed
        // output into the Trash and left a `staged` entry pointing at it. Proven three ways: the decision,
        // the WIRING on the real `finalize`, and the happy-path reclaim it must not break. ---

        // (a) The decision itself.
        check("reclaim is allowed only when everything filed AND nothing is left staged",
              LiveCaptureProcessor.stagingSafeToReclaim(allPlannedFiled: true, segmentsStillStaged: 0))
        check("a straggler BLOCKS the reclaim even though every PLANNED segment filed",
              !LiveCaptureProcessor.stagingSafeToReclaim(allPlannedFiled: true, segmentsStillStaged: 1))
        check("a partial finalize never reclaims (the pre-existing gate is intact)",
              !LiveCaptureProcessor.stagingSafeToReclaim(allPlannedFiled: false, segmentsStillStaged: 0)
                  && !LiveCaptureProcessor.stagingSafeToReclaim(allPlannedFiled: false, segmentsStillStaged: 2))

        // (b)+(c) The wiring, driven through the REAL `finalize`. FAIL-CLOSED: this builds a
        // `CaptureSession`, whose folders come from `backupRoot` — without the test override that is the
        // operator's real `~/Pictures` backup root, so refuse to run rather than touch it.
        let isolatedBackup = !(ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"] ?? "").isEmpty
        check("the finalize wiring test runs against an ISOLATED backup root (never the operator's)",
              isolatedBackup)
        if isolatedBackup {
            await runTest13(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- Test 14 (W3.cap-r2): a phone auto-retry after a dropped ack must not buy a SECOND paid OCR
        // call. `CaptureSession.ingest` already de-duplicates a re-upload on `(groupId, seq)` — it REPLACES
        // the stored photo rather than appending one — but `CapturedPhoto.id` is a fresh `UUID()` per value,
        // so the processor's "already started" guard, keyed on that id, saw a brand-new page and started OCR
        // a second time (the first Task orphaned, both calls billed). Driven through the REAL `ingest` path
        // with a $0 stand-in for the paid call, so what the test counts IS what the operator gets charged. ---
        if isolatedBackup {
            await runTest14(tmp: tmp, stubModel: stubModel, check: check)
        }

        // --- Test 15 (W3.cap-r5): an out-of-order relay Box delivered while a document is IN FLIGHT inside
        // `finalizeSegment` must still re-pin that document's collection. Finalize inserted the group into
        // `finalizedGroups` and read its collection key into a local BEFORE its OCR / tagging / file-write
        // awaits, each of which suspends for seconds; `backfillCollections` skipped anything already
        // finalized and could only repair segments already in `staged`. Between those two states the
        // document was reachable from neither side, so a Box arriving out of relay order in that window
        // could never correct it and the pages were filed into the PREVIOUS collection — an irreplaceable
        // document in a folder nobody would think to look in. Driven through the REAL ingest → finalize path
        // with the $0 OCR stub held on a gate, so the Box lands inside that exact window and nowhere else. ---
        if isolatedBackup {
            await runTest15(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- Test 16 (W3.cap-r4): the mirror of Test 15 — the Box arrives AFTER the document has staged, so
        // `backfillCollections` DOES reach it and corrects the visible record. The correction then had to
        // survive the operator's last action before the move: the end-of-session rotation review. That pass
        // regenerates each straightened segment from its RETAINED write inputs and replaces the staged record
        // with the result — and the retained copy of the collection key was taken at finalize and never
        // corrected, so straightening a page wrote the pre-correction key straight back over the corrected
        // one. The document went into the previous collection, on the way out the door, with nothing on
        // screen to say so. Driven through the real ingest → backfill → rotation-review path. ---
        if isolatedBackup {
            await runTest16(tmp: tmp, stubModel: stubModel, isolatedBackup: isolatedBackup, check: check)
        }

        // --- Test 17 (W3.cap-r3): a page that LEAVES the session must take its paid OCR call with it. Both
        // removal paths — the operator's delete in the Captured pane, and the Mac tombstoning the old copy of
        // a page the phone reclassified (`X-Replaces`) — dropped the photo and trashed its source without
        // telling the processor anything. The OCR call started on arrival ran to completion, billed, for a
        // page nobody would ever read, and its Task + result sat in `pageTasks` under a key nothing looks up
        // again; no other path drops a single page's entry. Driven through the REAL removal paths with the $0
        // stub held on a gate, so the call is genuinely IN FLIGHT at the moment the page is deleted — the
        // only state in which there is anything to cancel. ---
        if isolatedBackup {
            await runTest17(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- Test 17 (W3.cap-r3-fu1): the started-once guard must not outlive the call it guards. W3.cap-r2
        // made `photoIngested` refuse a second paid OCR call for a page it had already started, and recorded
        // "already started" in a SET beside the Task. Three paths free the Task without retiring that key —
        // `finalizeSegment` clears `pageTasks` for the pages it staged, `finalize` drops a FILED group out of
        // `finalizedGroups` while its keys stay armed, and `photoRemoved`'s mid-finalize carve-out keeps the
        // key on purpose — so the guard came to mean "this page once had a call" instead of "this page has
        // one". A page the phone re-sent after its group finalized returned at that guard, ABOVE the
        // late-page branch under it: it bought no call, raised no warning, and once the group had been filed
        // a later finalize read the empty `pageTasks` entry as "OCR not started" and filed a silently
        // text-less archival document. The guard now asks `pageTasks` itself, which is the only record left.
        // Driven through the REAL ingest → finalizeSegment → finalize path with the $0 OCR stub, so what these
        // checks count is what the operator would be charged. ---
        if isolatedBackup {
            await runTest17fu1(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- Test 18 (W3.cap-r3-fu2): a retry must CANCEL the calls it is about to make unreachable.
        // `retryFailed` deletes the group's staged output and its retained inputs, then re-ingests every page
        // — so each old `pageTasks` entry is replaced and nothing can ever read what those calls return. It
        // used to drop them without `cancel()`, which is the exact mutant (M2) W3.cap-r3 was measured against,
        // living in production 130 lines above that fix.
        //
        // HONEST SCOPE, because this is the one thing a reader could take the wrong way: the defect is LATENT,
        // and this section enters `retryFailed` through the API rather than through the UI **because the UI
        // cannot reach it**. Every route into a retry runs past `finalizeSegment`'s own `pageTasks` clear first —
        // the bulk button passes `failedGroupIds`, which only `markFailed` writes, and `markFailed` runs after
        // that clear; the per-item menu offers `.retry` only for `.failed`/`.succeededNoText`/
        // `.succeededPlaceholderImage`, never for a segment mid-OCR. Check 2 PINS BOTH legs of that gate — the
        // per-item menu AND `failedGroupIds` — so the day an edit makes a retry reachable mid-flight this
        // driver says so out loud. (The `failedGroupIds` leg used to be the fragile one — nothing kept a
        // failed group inside `finalizedGroups`; `W3.cap-r3-fu5` made that structural and Test 19 drives it.)
        // What the section proves is that the mechanism is right whenever it IS reached: cancel first, drop
        // second, exactly this group.
        //
        // NON-VACUITY, measured (2026-08-03), four mutants of the loop:
        //   M1 the pre-fix drop-without-cancel                   → 1 RED, the cancel check alone.
        //   M2 a wholesale `for t in pageTasks.values { t.cancel() }` ahead of the same per-group drop
        //                                                        → 1 RED, the scope check alone.
        //   M3 the cancel moved BELOW the re-ingest              → 2 RED, the cancel + fresh-call checks.
        //   M4 the cancel WITHOUT the `= nil`                    → the fresh-call check RED (the started-once
        //      guard refuses the re-ingest, so nothing replaces the entry), and then the run emits NOTHING
        //      further and the harness kills it at 60 s. Recorded as observed, ×3: by the clock the bounded
        //      10 s settle below should have let the staging check report FAIL with ~20 s to spare (the green
        //      suite finishes in ~28 s), so that state stops making progress for a reason this pass did not
        //      diagnose. It is not a crash — the app is alive when the harness SIGTERMs it.
        // Check 6 is a guard against over-reach, not a second catcher — see its own note. ---
        if isolatedBackup {
            await runTest18(tmp: tmp, stubModel: stubModel, check: check)
        }

        // --- Test 19 (W3.cap-r3-fu5): a group that FILES must leave the failed set.
        // `failedGroupIds ⊆ finalizedGroups` is load-bearing and was unenforced. `markFailed` is the only
        // writer that INSERTS, and it runs inside `finalizeSegment` after the group is already finalized, so
        // the subset can only break on a REMOVAL — and of the three, `finalize` was the one that dropped the
        // finalized entry alone, over exactly the groups it had just filed.
        //
        // Reaching it needs a group that is both FAILED and FILABLE, which sounds contradictory and is not:
        // `finalizeSegment` appends to `staged` and `retained` BEFORE the label branch, so a `.noOutput`
        // segment sits in both; `finishSession` enumerates `retained.values` unconditionally, so its pages
        // enter the rotation review; and a regeneration there replaces the staged record WHOLESALE without
        // touching the label. If the original failure was transient — a write error, no free space, rather
        // than a missing source, which fails regeneration the same way — the record comes back filable while
        // the group is still counted failed. This section builds that state for real, with a read-only
        // staging dir as the transient error, and drives it through Finish → rotation review → finalize.
        //
        // What the leftover entry cost: `finalize` drops the status row one line above, so the operator got a
        // "Retry 1 failed" button with no row under it, pointed at a document already in the collection — and
        // `retryFailed` would have answered that button by buying its OCR a second time.
        //
        // NON-VACUITY, measured (2026-08-03), four mutants of the two release helpers + the finalize call site:
        //   M1 the pre-fix `finalizedGroups.remove(gid)` back at the finalize call site
        //      → 2 RED, both here: the subset check and the button check. This is the shipped defect.
        //      ⚠️ RE-MEASURED 2026-08-04, after `W3.cap-r3-fu6`: now **0 RED**. Not a regression in this
        //      section — fu6 removed the reachability M1 needed. The regeneration re-derives the label, so
        //      V1 leaves `failedGroupIds` at check 4 instead of at the finalize, and no other path can put a
        //      filable record in the failed set (see the fu6 note at the `releaseFinalizedGroup` call site in
        //      `finalize`). Read it as "the defect fu5 fixed can no longer be constructed", not as "fu5 was
        //      unnecessary": it was real and shipped. The pairing's live coverage is now M2's 8 Test-17 REDs.
        //   M2 `releaseFinalizedGroup` clearing ONLY `failedGroupIds` (the finalized leg dropped)
        //      → 9 RED: the subset check here, plus 8 in Test 17, which needs that same removal for a filed
        //      group's re-uploaded page to buy its call. ⚠️ Read with the harness wait temporarily raised to
        //      240 s — Test 17's stalled settles push the run past `test-recovery.sh`'s 60 s, and the report
        //      is written only at the END, so under the script AS SHIPPED this mutant reads as a bare
        //      timeout with no PASS/FAIL lines at all. (Corroborates `W21.recovery-timeout`.)
        //   M3 `failedGroupIds.removeAll()` instead of removing this group
        //      → 1 RED, the button check. It is caught only because the section files V1 while V2 is still
        //      genuinely failed: an earlier draft with a single group let M3 through the WHOLE suite, and
        //      Test 18's scope check does not cover this (it is about `pageTasks`, not the failed set).
        //   M4 `releaseAllFinalizedGroups` (the Clear exit) dropping its `failedGroupIds.removeAll()`
        //      → 0 RED, recorded as an honest limit rather than fixed. Nothing here drives Clear, and the
        //      two sets are emptied together at that site, so the pairing is convention there in a way it
        //      is not at the per-group exit. Closing it would need a Clear-path section of its own.
        // Checks 1–3 are premises, not catchers — they exist so a green result cannot come from the segments
        // never failing, or from the regeneration never making V1 filable. ---
        if isolatedBackup {
            await runTest19(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- Test 20 (W3.cap-r3-fu6): the BACKWARD direction — a SUCCESS label left over a record with
        // nothing in it. Test 19 covers the forward half (a failed label surviving a good regeneration);
        // this is the one that fails quietly instead of loudly. `applyRotationReviewAndFinalize` replaces the
        // staged record wholesale, so a regeneration that produces NO output turns a `.staged` segment into
        // an empty record still wearing "Staged" — and `executePlans` then skips it (`pagesComplete ==
        // false`) with no failure surfaced anywhere. The operator finishes the session, sees no warning, and
        // the document is simply not in the collection.
        //
        // HOW the write is made to fail, and why the shape is `mergeDocuments: true` rather than a
        // read-only staging dir alone. Regeneration writes each page back to the SAME path
        // (`<source-basename>.pdf` in the staging dir), so with per-page PDFs still sitting there a failed
        // write could be masked by the previous run's file — `writeSegmentFiles` records a PDF it can prove
        // is on disk, and the stale one is on disk. Merge removes that ambiguity for real instead of by
        // deleting fixtures behind the code's back: the successful first write merges the per-page PDFs and
        // deletes them, so the regeneration's target paths are genuinely absent. Check 2 asserts exactly
        // that, because the whole section is vacuous without it.
        //
        // NON-VACUITY, measured (2026-08-04), on `labelStagedRecord` + the regeneration call site:
        //   N1 the pre-fix regeneration — the `labelStagedRecord` call at the end of the `for outcome in
        //      regenerated` loop deleted → 3 RED: Test 19's check 4 (the forward direction) plus checks 5
        //      and 6 here (the backward one, and its operator-visible consequence). This is the shipped
        //      defect, in both of its directions, and it is the only mutant either section needs to justify
        //      itself.
        //   N2 `labelStagedRecord` labelling from `RetainedSegment.texts` (`texts.contains { !$0.isEmpty }`)
        //      instead of `pages[].result.text != nil` — the approximation the item warned against
        //      → 0 RED. Recorded as an honest limit, not fixed: nothing here or in Test 19 stages a document
        //      whose OCR returns an EMPTY STRING rather than nil, which is the only input that separates the
        //      two, and manufacturing one needs an OCR stub per page rather than the single shared stub the
        //      driver installs. The approximation is avoided in the code and argued in the comment; it is
        //      not pinned by a test.
        //   N3 the label re-derived from `self.retained[groupId]` instead of the `regenInputs` snapshot
        //      → 0 RED, and expected to be: nothing on this path mutates `retained` while the detached write
        //      runs, which is exactly why the code comment calls that a property of the surroundings rather
        //      than of the line. Recorded so the next reader knows the snapshot is defensive, not covered.
        // Checks 1–2 and 4 are premises, not catchers. ---
        if isolatedBackup {
            await runTest20(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- Test 21 (W3.cap-r3-fu7): a retry pressed WHILE the end-of-session rotation review is
        // regenerating. `applyRotationReviewAndFinalize` sets `isFinalizing` and then writes the changed
        // segments from a DETACHED task, and that is the one finish state with no sheet over the Live Capture
        // panel — `LiveCaptureView:48` shows a throbber for precisely `isFinalizing && !showFinalizeSheet &&
        // !showRotationReview`. So the panel's "Retry N failed" button and the expanded row's per-item retry
        // were both live in a window where a retry deletes the segment's staged output, drops `retained`, and
        // re-ingests every page — buying the OCR a SECOND time — while the regeneration's write is still in
        // flight and about to `staged[idx] = fresh` over whatever the re-run appended.
        //
        // HOW the window is held open, and why no gate object is needed. `isFinalizing = true` is set
        // SYNCHRONOUSLY before the `Task`, and everything that closes the window again (`staged[idx] = fresh`,
        // `isFinalizing = false`, `beginFinalize()`) runs on the MainActor *after* an await on the detached
        // write. So a retry issued on the same MainActor turn as `applyRotationReviewAndFinalize()`, with no
        // await between, is inside the window by construction. Check 3 asserts that state rather than
        // trusting it.
        //
        // ⚠️ Stated exactly, because the first draft of this comment overclaimed it and the adversarial pass
        // nailed down why. `LiveCaptureProcessor` is `@MainActor`, so the `Task { … }` in
        // `applyRotationReviewAndFinalize` is MainActor-ISOLATED — it cannot begin until the MainActor yields,
        // which this test never does before check 5. So at checks 3–5 the outer Task has not started and the
        // inner `Task.detached` has not even been CREATED, let alone run on another thread. What this section
        // therefore proves is a FLAG-STATE refusal, not a simultaneous race: the retry is issued in exactly the
        // state the exposed window has, and is refused. That is the property the fix turns on — the defect is
        // the retry running at all, in a state from which the pending write will later publish over it — but it
        // is weaker than "with the write running concurrently", which is not asserted anywhere and should not
        // be claimed. Making the overlap literal would need a gate inside `writeSegmentFiles`; the refusal it
        // would additionally demonstrate is the same one.
        //
        // WHAT is asserted, and why it is not the record overwrite itself. The overwrite half is
        // order-dependent — whether the regeneration's `firstIndex` finds the retry's freshly appended record
        // (overwrite, pointing at deleted files) or finds nothing (the fresh record silently skipped) depends
        // on which resumes first — so pinning one ordering would pin an artifact of this run's scheduling.
        // The DOUBLE SPEND is order-independent: the retry always re-ingests. The fix is a refusal, which
        // forecloses every ordering at once, so the checks measure the refusal and its money consequence.
        //
        // NON-VACUITY, measured (2026-08-04). Every mutant was built and run; the counts are observed:
        //   P1 the `guard !isFinalizing` in `retryFailed` deleted (the shipped defect)
        //      → 3 RED: checks 4, 5 and 8. The retry buys FOUR more paid calls — check 4 issues two retries,
        //      and the second re-nils `pageTasks` so it re-buys too; the first draft of this note said two,
        //      which the adversarial pass corrected — and takes the segment's staged
        //      record, its `finalizedGroups` entry and its output files with it. Check 8 goes down
        //      as a consequence rather than on its own account — the window's retries already spent the calls
        //      it counts — which is worth knowing when reading a future regression: 4 and 5 are the ones that
        //      name the defect. This is the mutant the section exists for.
        //   P2 the guard weakened to the bulk-only shape — `!(isFinalizing && groupIds == nil)`, refusing only
        //      the "Retry N failed" button and letting every single-group call through
        //      → 3 RED: the same three. Pins that the PER-ITEM entry is gated too, which is the item's open
        //      question answered as a measurement rather than a preference.
        //   P3 `SegmentItem.gate` returning its input unchanged (the UI half reverted)
        //      → 1 RED, check 7. The menu offers a retry that `retryFailed` would refuse.
        //   P4 `gate` filtering `.retry` only, leaving `.changeRotation`
        //      → 1 RED, check 7. The rotation sheet also reaches `retryFailed`, so a gate that stops at the
        //      plain retry leaves a money path open.
        //   P5 the guard WIDENED to `requestFinish`'s triple — also refusing while `showFinalizeSheet` /
        //      `showRotationReview` is up
        //      → 1 RED, check 8. Recorded because it is the mutant that shows the section constrains the
        //      guard's WIDTH and not merely its presence: `beginFinalize` has raised the collection sheet by
        //      the time check 8 runs, so a widened guard turns the intended window into a ban and is caught.
        //      The widening was considered and declined on its own merits (see `retryFailed`'s comment and
        //      `W3.cap-r3-fu9`); this is what makes that a tested decision.
        //   P6 `segmentItems`' `let finalizing = liveProc.isFinalizing` forced to `false` — the view WIRING of
        //      the per-item gate, as opposed to the pure function check 7 exercises
        //      → 0 RED, and recorded as a limit rather than fixed. Check 7 calls
        //      `SegmentItem.actions(for:finalizing:)` directly, so nothing here proves the view passes the real
        //      flag into it. Asserting that needs the view, i.e. the VM GUI lane.
        //   P7 the bulk button's `.disabled(liveProc.isFinalizing)` deleted
        //      → 0 RED, same reason and unavoidably so: a SwiftUI modifier's effect is not observable from a
        //      headless driver at all.
        //      ⚠️ P6 and P7 together are the honest scope statement for this section: of the fix's three edits,
        //      only the `retryFailed` guard (P1/P2) and the pure action-gate function (P3/P4) are measured
        //      here. Both unmeasured mutants are in the VIEW, and both were found by the adversarial pass
        //      rather than volunteered.
        //      ⚠️⚠️ `W3.cap-r3-fu10` has since DECIDED the reachability question these two were parked behind,
        //      and the answer changes what a VM-lane session can do with them rather than unblocking them. The
        //      throbber's scrim blocks the pointer deliberately, so a CLICK-driven XCUITest cannot kill P6 or
        //      P7 either: removing `.disabled` from a control the scrim is already eating the clicks for
        //      changes nothing a click can observe. Killing them needs KEYBOARD-driven focus (⇥+Space with
        //      Full Keyboard Access on), which is the one route the scrim does not block and therefore the one
        //      route on which those two modifiers are the sole defence. Recorded here so `W21.vmgui-d` writes
        //      the right test instead of writing a clicking one and reading its 0 RED as coverage.
        //
        // Section 3b (fu10's own coverage check) adds six more — four MEASURED 2026-08-04 and two that are
        // 0 RED by construction — all on `LiveCaptureProcessor.isFinishingScrimUp` unless noted:
        //   S1 `!showFinalizeSheet` dropped → 1 RED, 3b (the finalize-move state would claim a scrim behind
        //      the sheet that is already the modality).
        //   S2 `!showRotationReview` dropped → 1 RED, 3b. A SPECIFICATION kill, not a reachability one — no
        //      path reaches `isFinalizing && showRotationReview` today; 3b constructs it by assignment and
        //      says so.
        //   S3 the whole property forced to `false` (the scrim never up) → 1 RED, 3b.
        //   S4 forced to `true` (always up) → 2 RED: 3b (via the idle and review-sheet samples) AND check 6,
        //      whose folded-in sample C is the only one taken after the window has closed. Predicted as 1 and
        //      measured as 2; recorded as measured. The second RED is the useful one — it says sample C is
        //      load-bearing rather than decorative, because it is the only place an always-on scrim is caught
        //      in a state the test DROVE rather than assigned.
        //   S5/S6 `.contentShape(Rectangle())` deleted, and the overlay's `if` deleted outright
        //      → 0 RED and 0 RED BY CONSTRUCTION, which is the point rather than a gap: hit-testing and
        //      SwiftUI rendering are both invisible from a headless driver. What the driver measures is WHEN
        //      the panel is declared blocked; whether the scrim then eats the click is `W21.vmgui-d`'s
        //      observation, and the throbber carries `accessibilityIdentifier("live.finishing-throbber")` so
        //      that test can wait on the window and assert a panel button behind it is not `isHittable`.
        // Checks 1–3 and 6 are premises, not catchers. ---
        if isolatedBackup {
            await runTest21(tmp: tmp, stubModel: stubModel, check: check)
        }

        // --- Test 22 (W3.cap-r3-fu11): a CLEAR pressed while the end-of-session rotation review is
        // regenerating. Same window as Test 21 — `applyRotationReviewAndFinalize` sets `isFinalizing` and
        // then writes the changed segments from a DETACHED task, the one finish state with no sheet over the
        // Live Capture panel — but the hazard is worse and it is data rather than money. The Captured pane's
        // Clear button was `session.clear(); liveProc.clearSessionState()`, ungated: the first half Trashes
        // the source photos the in-flight `writeSegmentFiles` is still reading, and the second empties
        // `staged`/`retained` under the loop that is about to `staged.firstIndex` them — so the
        // regeneration's `guard let idx` finds nothing, its partially-rewritten `_processed` files are
        // orphaned, and the sources are in the Trash. Recoverable (Trash, per the Recovery Core Directive),
        // which is why the item is LOW rather than MED.
        //
        // WHAT IS ASSERTED, stated at the strength the driver can actually reach. This inherits Test 21's
        // ⚠️ exactly and it is not a footnote: `LiveCaptureProcessor` is `@MainActor`, so the `Task { … }` in
        // `applyRotationReviewAndFinalize` cannot begin until the MainActor yields, which nothing between
        // check 3 and check 4 does. So at check 4 the outer Task has not started and the inner
        // `Task.detached` has not been CREATED, let alone run. This is a FLAG-STATE refusal — the Clear is
        // issued in exactly the state the exposed window has, and is refused — NOT a demonstration of a
        // Clear racing a running write. That weaker property is the one the fix turns on (the defect is the
        // Clear landing at all, in a state from which a pending write will later read files it has Trashed),
        // but the stronger one is not measured here and should not be read in. Making the overlap literal
        // would need a gate inside `writeSegmentFiles`.
        //
        // WHY BOTH HALVES ARE IN ONE CHECK rather than two. The fix's real claim is ATOMICITY — the
        // destructive half and the state half refuse together — and the failure the item is about is
        // precisely a SPLIT: sources in the Trash while `staged` still lists the segments pointing at them.
        // A check per half would pass on a mutant that gated only one, which is the outcome worse than
        // either. Check 4 is therefore deliberately compound.
        //
        // NON-VACUITY, measured (2026-08-04). Every mutant was built and run; the counts are observed:
        //   M1 the `guard !isFinalizing` in `clearSession()` deleted (the shipped defect)
        //      → 2 RED: checks 4 and 5. The Clear Trashes both sources and empties `staged`/`retained`/
        //      `finalizedGroups`, and the regeneration that follows then has no index to publish into, so
        //      the segment never comes back. This is the mutant the section exists for.
        //   M2 the guard kept but `session.clear()` hoisted ABOVE it — the destructive half ungated, i.e.
        //      exactly the split the one-door shape exists to make impossible
        //      → 2 RED: checks 4 and 5. The worse-than-either outcome, and the one a per-half check set
        //      would have missed: `staged` still lists a segment whose sources are in the Trash.
        //   M3 the mirror — `clearSessionState()` hoisted above the guard, the STATE half ungated
        //      → 2 RED: checks 4 and 5. Predicted as 1 (check 4 only) and measured as 2; recorded as
        //      measured. The second RED is the informative one — emptying `staged` alone is enough to strand
        //      the regeneration, so the state half is not the "harmless" side of the split it looks like.
        //   M4 the guard WIDENED to `requestFinish`'s triple — also refusing while `showFinalizeSheet` /
        //      `showRotationReview` is up
        //      → 1 RED, check 6. The WIDTH measurement, mirroring Test 21's P5: `beginFinalize` has raised
        //      the collection sheet by then, so a widened guard turns the intended window into a ban and is
        //      caught. The widening was considered and declined on its own merits (see `clearSession`);
        //      this is what makes that a tested decision rather than a preference.
        //   M5 the view's `.disabled(liveProc.isFinalizing)` on the Clear button deleted
        //      → 0 RED, and unavoidably so — a SwiftUI modifier's effect is not observable from a headless
        //      driver at all. Same limit as Test 21's P7, and the same route out: `W3.cap-r3-fu10` settled
        //      that the scrim eats the POINTER, so the only thing that modifier defends is the
        //      keyboard/VoiceOver path, and killing it needs a KEYBOARD-driven XCUITest in the Processor VM
        //      lane (`W21.vmgui-d`) — ⇥+Space with Full Keyboard Access on, not a clicking test. Recorded
        //      so that lane writes the right test instead of reading a clicking 0 RED as coverage.
        //
        // ⚠️ AN OPS FACT THIS MEASUREMENT TURNED UP, worth more than the mutant counts. M1 and M3 both make
        // the WHOLE driver take ~80 s (81 s and 79 s observed, against a 15 s ALL-PASS baseline), because a
        // Clear that gets through strands the regeneration and every downstream settle runs to its timeout.
        // `test-recovery.sh` waits 60 s for the report — so a REAL regression of this fix does not present
        // as `FAIL: a Clear mid-regeneration…`, it presents as "Recovery data-safety test timed out", which
        // is indistinguishable from a hang. That is `W21.recovery-timeout` stopping being hypothetical, and
        // its tracker entry now carries these numbers. It also cost this item a round: the first mutant pass
        // read M1's missing report as 0 RED. If you are reading a timeout here, raise the wait before you
        // conclude anything. ---
        if isolatedBackup {
            await runTest22(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- Test 23 (W3.cap-r3-fu9): the end-of-session rotation review raised while one of the Processing
        // list's PER-ITEM sheets ("Retry with model" / "Rotate & re-run", "View text") is already on screen.
        //
        // THE WINDOW, and why it is reachable with no operator click. `finishSession` is the only writer of
        // `showRotationReview`, and one of its two callers is `proceedToFinishIfReady` — driven by BACKGROUND
        // events: a segment staging, a phone heartbeat, and a 5 s watchdog. So the operator presses Finish
        // while the phone is still draining (the finish goes `pendingFinish`), opens a per-item sheet on a
        // staged segment while they wait, and the drain completing then raises the review underneath their
        // open sheet. No second click is needed anywhere. That is what this section drives, in that order.
        //
        // WHAT WAS **NOT** SETTLED, stated first because the fix is shaped around not needing it. Whether
        // SwiftUI SUPPRESSES the second presentation, QUEUES it, or STACKS it is unobserved — a headless
        // driver cannot see sheet presentation at all, and the Processor has no VM GUI lane yet
        // (`W21.vmgui-d`). The item that filed this asked for the premise to be verified; it could not be,
        // here, so it was made IRRELEVANT instead: each of the three answers is a different failure
        // (a silently skipped review + a permanently dead Finish; a review describing pages of a segment
        // being re-OCR'd, whose edits `applyRotationReviewAndFinalize` then drops on a nil `retained`; or a
        // model sheet revealed again inside `isFinalizing`, where `W3.cap-r3-fu7`'s refusal is silent), and
        // `proceedToFinishIfReady` refusing to start the finish while a per-item sheet is up makes the state
        // none of them can be reached from. See `LiveCaptureProcessor.rotationRetryTarget`.
        //
        // WHAT THIS DRIVER CAN AND CANNOT PROVE. It proves the MODEL-layer rule and its non-vacuity: at
        // check 4 every other term of `proceedToFinishIfReady`'s guard is independently asserted false, so
        // only the sheet term can be doing the holding. It also proves the two halves separately — the guard
        // consumes `perItemSheetUp` (check 4) and `perItemSheetUp` survives a cleared target for the grace
        // (check 6) — which compose into "the finish is held across a sheet's teardown".
        // ⚠️ It CANNOT prove the VIEW feeds that state; a SwiftUI binding is invisible from here. An earlier
        // draft of this note claimed deleting `LiveCaptureView`'s `@State` made that leg "compile-enforced".
        // It does not, and an adversarial pass built the counterexample: re-adding a `@State` target and
        // repointing the `.sheet(item:)` + the three `performSegmentAction` writes compiles cleanly, leaves
        // `perItemSheetUp` permanently false, and turns this whole guard into a silent no-op with 0 RED
        // anywhere here. So the honest statement is that the view→model leg is UNCOVERED (see M4), and
        // closing it needs the Processor VM GUI lane (`W21.vmgui-d`).
        //
        // NON-VACUITY, measured (2026-08-04, re-measured after the adversarial pass changed the fix). Every
        // mutant was built and run to a WRITTEN report on a 150 s wait, not `test-recovery.sh`'s 60 s — a
        // stranded run that gets killed reads as 0 RED, which is the mistake `W3.cap-r3-fu11`'s pass made
        // once. Baseline 172 checks, 0 RED, 0 Swift warnings:
        //   M1 the `!perItemSheetUp` term deleted from `proceedToFinishIfReady` (the original defect)
        //      -> 1 RED, check 4. The drained finish walks straight into the review with the model sheet open.
        //      Checks 5-9 still PASS, recorded rather than hidden: with the review raised early, the Apply's
        //      retry re-populates `retained` before the review is applied, so the dropped-edits leg does not
        //      reproduce at the driver's timing. Check 4 is the load-bearing kill; checks 8-9 assert the
        //      leg-2 PROPERTY rather than killing the leg-2 bug.
        //   M2 `perItemSheetGrace` deleted, so the gate reads the raw targets only — i.e. v1 of this fix
        //      -> 1 RED, check 6. THE kill for the defect the adversarial pass found: the gate drops the
        //      instant the target clears, which is mid-teardown.
        //   M3 the delayed re-evaluation shortened back to ONE MainActor turn (v1's actual code)
        //      -> 0 RED, and that is the right answer rather than a gap: with the grace in place the hop may
        //      fire as early as it likes and `proceedToFinishIfReady` still refuses. It is the measurement
        //      that says the protection lives in the GRACE and the hop is only latency — v1 was broken
        //      because it had no grace, not because its hop was short.
        //   M4 the guard MOVED into `finishSession` (the plausible wrong placement)
        //      -> 3 RED, checks 4, 7 and 8. `proceedToFinishIfReady` clears `pendingFinish` on the line before
        //      the call, so a refusal one level in DISCARDS the finish: check 4 catches it immediately
        //      (`pendingFinish` already false with the sheet still up), the review never comes back (7), and
        //      there is nothing left to apply (8). Check 9 passes anyway, because
        //      `applyRotationReviewAndFinalize` with no pages still reaches `beginFinalize` — which is exactly
        //      why check 9 alone would be a weak assertion.
        //   M5 the view->model leg — a `@State` target re-added to `LiveCaptureView` with `.sheet(item:)`
        //      repointed at it — is buildable (~6 lines) and would be 0 RED: nothing here reads the view, so
        //      `perItemSheetUp` would simply stay false and this guard become a silent no-op. NOT RUN, and
        //      recorded as the priced coverage gap it is; closing it needs `W21.vmgui-d`.
        //
        // COST, since `W21.recovery-timeout` is about exactly this: the section spends ~0.75 s on check 4's
        // negative window and ~1.7 s waiting out the grace in check 6, against a ~13 s ALL-PASS baseline for
        // the rest of the driver and a 60 s report wait. An earlier draft spent 5.5 s on check 4 to "cover a
        // watchdog period" and bought no assertion with it (see check 4). ---
        if isolatedBackup {
            await runTest23(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- Test 24 (W3.cap-r3-fu9-fu1): CANCELLING a pending Finish from an empty pane after scratch recovery
        // restores staged output whose source photos are unavailable.
        //
        // WHAT WAS ACTUALLY BROKEN, since it is unusual: `cancelPendingFinish()` was correct code with no
        // caller. Nothing in the shipped UI reached it, so while a Finish was pending the operator's only exit
        // was **Clear**, which Trashes every source photo of the session. Re-tapping Finish is not an exit
        // (`requestFinish` re-arms). So the bug was a MISSING BUTTON.
        //
        // ⚠️ WHICH HOLDS THE BUTTON RESCUES — the first draft of this note said "on a tag card, on in-flight
        // OCR, on the phone's drain, or on a per-item sheet", i.e. all four terms of
        // `proceedToFinishIfReady`'s guard, and that was wrong. Two of the four hold the finish BY putting a
        // `.sheet` over the capture panel the button lives in, so the button is behind it and unpressable;
        // for those, dismissing the sheet is itself the exit, and Clear was never reachable there either. The
        // button serves the in-flight-OCR and phone-drain holds — which are the two that matter, being the
        // two that can persist indefinitely with nothing on screen to resolve. This section drives the OCR
        // one (check 2 resolves the tag card precisely so the hold is attributable to processing alone).
        //
        // And the fix is NOT "one button": it is one button rendered in TWO places. The pane's whole control
        // cluster is gated on `!session.photos.isEmpty` and `pendingFinish` outlives that gate, so an escape
        // nested inside it disappears in exactly the state it is needed (checks 7-8, and the fix's second
        // renderer). That was found by this item's own adversarial pass, after the first version shipped the
        // button inside the gate while three of its own comments cited that same gate as the defect.
        //
        // WHICH IS EXACTLY WHY THE COVERAGE HAS TO BE STATED BEFORE THE CHECKS. A headless driver calls the
        // model method directly, so on its own it re-proves what was already true and says nothing about the
        // thing that was wrong. This section is therefore NOT the proof that the affordance exists; it is the
        // proof that the affordance is SAFE TO OFFER — which was not previously established either, because
        // nothing had ever exercised a cancel against live session state. See M1: deleting the button from
        // `LiveCaptureView` leaves every check here green, the same UNCOVERED view→model leg `W3.cap-r3-fu9`
        // recorded as its M5, and closing it needs the Processor VM GUI lane (`W21.vmgui-d`). The button
        // carries `.accessibilityIdentifier("live.cancel-finish")` so that lane has something to press.
        //
        // WHAT IT DOES PROVE, and each one is a property a plausible implementation of "cancel" gets wrong:
        //   • the wait is un-armed and the session is otherwise UNTOUCHED — photos still present, every source
        //     file still on disk, the segment still mid-OCR, not one extra paid call (check 3). This is the
        //     Clear contrast measured rather than asserted in prose: Test 22 drives the Clear that DOES Trash
        //     the sources, so the two together say what the operator now gains.
        //   • the cancel is a CANCEL, not a deferral: when the hold clears the finish does NOT quietly resume,
        //     and the OCR that was in flight during the cancel still lands (check 5). Discarding paid work in
        //     progress would be the money-path over-reach; the term that actually catches it is in check 3
        //     (see M4 — the obvious version of this assertion does not work).
        //   • it is not a one-way door — Finish works again afterwards (check 6), asserted as a transition
        //     rather than a level. The whole value of the affordance: an escape that wedged the session would
        //     be worse than Clear.
        //   • the `guard pendingFinish` is not decorative (check 4).
        //   • `pendingFinish` and a non-empty Captured pane genuinely come apart (checks 7-8), which is the
        //     premise the fix's second renderer rests on and the one thing here that is about WHERE the
        //     button is rather than what cancelling does.
        //
        // NON-VACUITY, measured (2026-08-04) — every mutant BUILT and RUN to a written report, so a 0 RED
        // below is a measurement and not a strand. Baseline 180 checks, 0 RED, 0 Swift warnings. M2-M4 were
        // measured twice — once against the 178-check pre-adversarial-pass baseline and again against this
        // one, since the pass added checks 7-8 and tightened 5 and 6; the numbers below are the SECOND run,
        // and where they differ from the first, the difference is recorded because it is what the pass
        // bought. M1's class-level 0 RED is unchanged by construction (see M6):
        //   M1 the `Button("Cancel finish")` deleted from `LiveCaptureView` — i.e. the shipped defect, exactly
        //      as it stood before this item -> 0 RED. RUN rather than predicted, because this is the item's
        //      own leg and a comfortable prediction was not good enough: nothing here reads the view. Recorded
        //      as the priced gap it is (`W21.vmgui-d`).
        //   M2 `guard pendingFinish` deleted from `cancelPendingFinish()` -> 1 RED, check 4. The no-op leg:
        //      without it a cancel with nothing armed overwrites the status line with a message about a finish
        //      that was not happening.
        //   M3 `pendingFinish = false` deleted, so cancelling only writes the status message -> predicted 2
        //      RED, measured 3 pre-pass, and **5 against the 180-check baseline**: checks 3, 4, 5, 6 and 8.
        //      The convincing-looking failure — the UI says "cancelled" and the finish then raises the
        //      rotation review by itself the moment the gate opens. Two of those five are worth reading
        //      carefully rather than counting. Check 4 falls OVER-DETERMINEDLY, and the first draft of this
        //      line mis-credited it: its `!pendingFinish` term is the same term as check 3's and is already
        //      false, so it goes RED whether or not the sentinel is overwritten — that is NOT evidence the
        //      no-op leg is separately sensitive to M3 (M2 is what shows that leg has teeth). Check 6 is the
        //      opposite story: it was GREEN under M3 before the adversarial pass, because `requestFinish`
        //      no-ops against the already-raised review and the level-style assertion could not tell that
        //      from a working Finish. Adding `cfNoReviewBefore` turned it into a transition, and it now
        //      fails — the pass's finding, measured.
        //   M4 the cancel widened to also cancel the in-flight OCR (`for t in pageTasks.values { t.cancel() }`,
        //      the "cancel means cancel everything" reading) -> 1 RED, check 3, via the task-handle term.
        //      ⚠️ Run TWICE, and the first run is the point: against check 5's stage-and-paid-count terms
        //      alone it was **0 RED**, because the driver's stub OCR never consults `Task.isCancelled` and so
        //      returns its text cancelled or not. Check 3's `_recoveryTestOCRTasks … !isCancelled` term was
        //      added in response and re-measured. Left standing as the reminder that "the segment still
        //      staged" is not by itself evidence that in-flight paid work was left alone.
        //   M5 the cancel widened to `session.clear()` (conflating the two exits) is the OTHER over-reach and
        //      would be caught by check 3's photo/source terms. NOT RUN: it Trashes the fixture photos to the
        //      real Trash, and Test 22 already drives that Clear for its own purposes.
        //   M6 the fix's SECOND renderer deleted — the `else if liveProc.pendingFinish` arm in
        //      `LiveCaptureView`'s header, i.e. the button back inside the `!session.photos.isEmpty` gate,
        //      which is where the first version of this fix put it -> 0 RED. NOT re-run, and that is a
        //      statement about the driver rather than a shortcut: M1 already MEASURED that deleting the
        //      button's action changes nothing here, and M6 is the same class (a view-only edit that no check
        //      reads). Checks 7-8 deliberately cover the MODEL half — that the state the renderer exists for
        //      is reachable and the escape works from it — which is the most a headless driver can say.
        //      Whether the row actually DRAWS there is `W21.vmgui-d`'s to close.
        //
        // COST (`W21.recovery-timeout`): NO wall-clock waits at all — the section parks its OCR at a gate
        // rather than racing it, and the adversarial pass deleted check 5's 0.5 s negative window once it was
        // shown to discriminate nothing (see check 5). Only settles, which return as soon as their condition
        // holds. Its one side effect outside the temp dir is check 7's two Trashed stub JPEGs. ---
        if isolatedBackup {
            await runTest24(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- Test 25 (W3.cap-r3-fu12): what an empty Captured pane offers while recovery restores unfiled
        // staged segments whose source photos are missing — and whether those controls work from there.
        //
        // THE ITEM WAS FILED AS A DECISION, NOT A BUG, so what this section is for needs saying first. The
        // header's whole control cluster is gated on `!session.photos.isEmpty`, while the session's unfiled
        // work is not: source photos may be missing on recovery while OCR'd, tagged segments in `_processed/`
        // still await filing. The pane said "Waiting for photos…". The decision taken was to offer the SAME two
        // controls, gated on `LiveCaptureProcessor.hasUnfiledWork`; this section is what makes that decision
        // falsifiable instead of a paragraph in a commit message.
        //
        // COVERAGE, stated before the checks for the same reason Test 24 had to. A headless driver calls model
        // methods directly and cannot read a `View`, so it can never show that a BUTTON appeared. That is why
        // the gate was put on the model rather than left inline in the header — the predicate the view draws on
        // is itself measurable here (check 3), and its non-vacuity is measured in the other direction too
        // (check 5: a fully successful finish must turn it OFF, or the cluster would linger over the green
        // "Session complete" summary forever). What stays uncovered is exactly one leg: that the header reads
        // it. See M1 — reverting the header arm leaves every check here green, the same view→model gap
        // `W3.cap-r3-fu9` recorded as its M5 and fu9-fu1 as its M1/M6, and closing it needs the Processor VM
        // GUI lane (`W21.vmgui-d`). `live.clear` / `live.finish` identifiers were added for that lane.
        //
        // WHAT IT DOES PROVE, and each is a property a plausible version of this decision gets wrong:
        //   • the recovered empty state is real and the staged work survives reaching it (checks 1-2).
        //   • FINISH FILES FROM THERE (checks 4-5) — the substance of the decision. It is not enough that a
        //     button appears: `requestFinish` runs `session.completeAllOpenDocGroups()` over a session with no
        //     groups left, and had that returned false the finish would have died in its error branch and the
        //     whole decision would have been unimplementable. Driven end to end, to files on disk.
        //   • CLEAR ABANDONS FROM THERE WITHOUT DESTROYING THE OUTPUT (check 6) — it empties the durable
        //     staging roster before clearing the Captured pane, while the `_processed` PDFs stay on disk.
        //     Note what Clear costs from THIS state compared with Test 22: `session.clear()` Trashes `photos`,
        //     which is empty here, so it Trashes nothing at all.
        //   • the new arm cannot draw a spinner that never stops (check 7) — the `processingCount` half of the
        //     fix. `session.groups` is derived from `session.photos`, so an emptied pane orphans every
        //     `.ocr`/`.tagging` row; unfiltered, "Processing…" would draw forever in exactly the state this
        //     item makes visible.
        //   • the two gates COME APART, and Finish is withheld where it would be inert (check 8). This is the
        //     correction the adversarial pass forced, and it is the one place the section indicts its own
        //     earlier self: check 7 creates a roster of nothing but an orphaned row and asserts
        //     `hasUnfiledWork`, i.e. it blessed drawing the cluster there — while the button it blessed did
        //     nothing at all when pressed. `canFinish` is the term that withholds it; check 8 presses it anyway
        //     to pin that the model layer was already refusing, silently.
        //
        // NON-VACUITY, measured (2026-08-04) — every mutant below was BUILT and RUN to a written report, so a
        // 0 RED here is a measurement and not a strand. Baseline **188 checks, 0 RED, 0 Swift warnings**, and
        // all seven were RE-RUN against that baseline after the adversarial pass added check 8 (M2 and M4 each
        // gained a second RED from it, which is the clearest single sign that check 8 was the missing one):
        //   M1 the `else if liveProc.hasUnfiledWork` arm reverted to fu9-fu1's `else if liveProc.pendingFinish
        //      { HStack(spacing: 8) { pendingFinishRow } }` — i.e. the shipped defect, exactly as it stood
        //      -> 0 RED. RUN rather than predicted, because it is this item's own leg. Recorded as the priced
        //      gap it is (`W21.vmgui-d`).
        //   M2 `hasUnfiledWork` weakened to `!staged.isEmpty` — the reading the item's own TITLE suggests
        //      ("staged, unfiled segments") -> **2 RED, checks 7 and 8**. Worth reading as a history: it was
        //      PREDICTED 0 (the author's reasoning being that every state here has something staged whenever it
        //      has a roster), measured 1 at the 187 baseline, and is 2 now. Check 7 is exactly the state where
        //      the prediction is false — an orphaned row surviving a Clear'd session with nothing staged — so
        //      the wider `statuses` spelling is measured rather than argued, on the case that matters: an
        //      operator holding only an orphaned row still needs **Clear** offered.
        //   M3 `hasUnfiledWork` widened to `true` -> **2 RED, checks 5 and 6** (predicted 1). The gate that
        //      never turns off: the cluster would draw over the green "Session complete" summary offering to
        //      finish a session with nothing in it. Both checks assert the OFF direction; the prediction had
        //      counted it once.
        //   M4 `processingCount`'s `session.groups` term deleted -> **2 RED, checks 7 and 8**. The
        //      forever-spinner leg. ⚠️ NOT "the pre-fu12 spelling", which is what an earlier draft called it:
        //      `proceedToFinishIfReady` now READS this property, so deleting the term removes it from the
        //      finish hold as well, and pre-fu12 the hold had the filter while the UI count did not. The
        //      combination this mutant creates never shipped. It is still the right test of the new coupling —
        //      just not a re-creation of the old bug.
        //   M5 `finalize`'s `self.statuses.removeAll { filedGroups.contains($0.id) }` deleted -> 2 RED. NOT a
        //      mutant of this item's code, run deliberately to show check 5 reads the roster the gate reads
        //      rather than passing on `staged` alone. Predicted "checks 5 and 6"; measured check 5 plus a
        //      PRE-EXISTING check from `W3.cap-r3-fu5`'s section ("…so the button counts exactly the segment
        //      that is still failed, and it has a row"). Check 6 is green under it because `clearSessionState`
        //      empties `statuses` unconditionally. Kept in that corrected form, because it says something worth
        //      knowing: the invariant this item leans on was already partly guarded elsewhere in the driver.
        //   M6 the `|| pendingFinish` disjunct deleted from `hasUnfiledWork` -> **0 RED**, and recorded rather
        //      than quietly dropped. The disjunct is genuinely UNREACHABLE (an adversarial pass traced it:
        //      `requestFinish` is the only writer that raises the flag, and the only two `statuses.removeAll`
        //      sites are `finalize`, reached with the flag already false, and `clearSessionState`, which lowers
        //      it) — so this is a 0 RED that says "dead code", not "untested behaviour". It stays in because
        //      `W3.cap-r3-fu9-fu1` ships a renderer that draws on `pendingFinish` alone and this gate must not
        //      be what deletes that escape; the honest status is "belt-and-braces, unmeasured, argued".
        //   M7 `canFinish` widened to `true` — i.e. the state this item SHIPPED before its adversarial pass,
        //      a `.borderedProminent` Finish drawn and enabled over a roster it cannot act on -> **1 RED,
        //      check 8**. The one mutant that is a re-creation of a defect that really existed in this diff.
        //
        // COST (`W21.recovery-timeout`): no wall-clock waits — only settles, and one gate the section opens
        // itself. Recovery fixtures remove only synthetic JPEGs under the redirected temporary backup root;
        // no real Trash or corpus paths are involved.
        //
        // ⚠️ FILE SAFETY — STATED CORRECTLY, because the first version of this paragraph was FALSE and an
        // adversarial pass caught it. It claimed "every finalize destination is an explicit `chosenExisting`
        // under `tmp`, so the move can never consult `currentOutputDirectory`". `finalize` evaluates
        // `currentOutputDirectory` UNCONDITIONALLY, one line after its guard and before any draft is looked at;
        // `chosenExisting` only wins the folder CHOICE afterwards. And check 4's `requestFinish` reaches
        // `beginFinalize`, which does not merely evaluate that path but ENUMERATES it on disk
        // (`existingCollectionFolders`). What actually keeps this section out of the operator's real output
        // folder is two things, and a future author needs both: `test-recovery.sh` exports
        // `LIVECAPTURE_TESTOUT`, which `currentOutputDirectory` prefers over the Settings folder; and check 5
        // passes a HAND-BUILT draft (`chosenExisting: uwFiled`) rather than `uwProc.drafts`, every one of which
        // carries `chosenExisting: nil`. ⛔ So do NOT "improve" check 5 by driving the real sheet's drafts: run
        // the driver without `LIVECAPTURE_TESTOUT` and that refactor creates a collection folder in the
        // operator's real output directory. This is the same hazard Test 20 refused to drive `finalize` for,
        // stated there correctly and here wrongly until the pass compared the two. Nothing is written outside
        // `tmp` as the section stands — the enumeration is read-only — but the MECHANISM was mis-located, which
        // in this file is itself the defect. ---
        if isolatedBackup {
            await runTest25(tmp: tmp, staging: staging, stubModel: stubModel, check: check)
        }

        // --- W3.cap-r3-fu12-fu2 review regression: a crash after the committed capture-manifest write but
        // before finishPreparedClear must leave enough durable state for launch to complete source cleanup.
        // No filed groups are present, matching the adversarial case that used to make the session invisible.
        if isolatedBackup {
            await runTest25fu2(check: check)
        }

        // --- Test 26 (W3.cap-r3-fu8): the CURRENT manifest-resume path is the third writer of a status row.
        // It used to hardcode `.staged` even when the record beside it said no output / incomplete output,
        // hiding a failed segment from both the row and `failedGroupIds`. Finalize still refused the record,
        // so the Recovery Core kept every source, but the operator had no visible recovery action.
        //
        // THE MONEY DECISION: resumed failures SHOULD be retryable, but resume must not retry them. Rebuilding
        // the label puts them into the existing bulk set; only the operator pressing that button calls
        // `retryFailed` and buys OCR. Checks 3 and 4 pin both halves independently.
        //
        // MUTATION PROOF (measured before the production change): with the loader's hardcoded `.staged`
        // restored, checks 2, 4 and 5 are RED — the row lies / set is empty, the no-argument bulk retry buys
        // nothing, and therefore nothing can re-stage. The manifest premise and no-auto-spend guard stay green,
        // so those failures cannot be a bad fixture or an accidental call during load.
        if isolatedBackup {
            await runTest26to29(tmp: tmp, staging: staging, stubModel: stubModel, bitmap: bitmap, check: check)
        }

        // --- W3.cap-r3-fu4: a filed group remains closed to late phone pages after relaunch. ---
        // Exercise CaptureSession.clearFiled (the production path after executePlans confirms destination
        // files), its on-disk manifest, launch-time empty-session preservation, and the real ingest callback.
        let backupOverride = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"]
        let backupPath = backupOverride.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path } ?? ""
        let tempRoots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        if let backupOverride, tempRoots.contains(where: { backupPath == $0 || backupPath.hasPrefix($0 + "/") }) {
            let backupRoot = URL(fileURLWithPath: backupOverride, isDirectory: true)
            let priorSessions = (try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []
            for folder in priorSessions where CaptureSession.isSessionIdName(folder.lastPathComponent) {
                try? fm.removeItem(at: folder)
            }

            let fu4Group = "fu4-filed-group"
            let fu4Bytes = Data("synthetic filed page".utf8)
            let fu4First = CaptureSession()
            fu4First.beginStageSessionForTest()
            let fu4Original = fu4First.ingest(jpeg: fu4Bytes, groupId: fu4Group, seq: 1, type: .document,
                                               quality: nil, year: nil, month: nil, deviceName: "TestPhone")
            fu4First.manifestWriteOverride = { _, _ in false }
            let fu4WriteRefused = fu4Original.map { !fu4First.clearFiled([$0], groupIds: [fu4Group]) } ?? false
            let fu4OriginalKept = fu4Original.map { original in
                fm.fileExists(atPath: original.path) && fu4First.photos.contains(where: { $0.url == original })
            } ?? false
            fu4First.manifestWriteOverride = nil
            let fu4Recorded = fu4Original.map { fu4First.clearFiled([$0], groupIds: [fu4Group]) } ?? false
            let fu4ManifestURL = fu4First.incomingFolder.appendingPathComponent("manifest.json")
            let fu4Persisted = (try? Data(contentsOf: fu4ManifestURL))
                .flatMap { CaptureSession.decodeManifest($0) }?.filed.contains(fu4Group) == true
            let fu4Preserved = !CaptureSession.isReclaimableEmptySession(fu4First.incomingFolder,
                                                                          relayBases: [])

            // A new CaptureSession simulates app relaunch after every original was retired. It must recover
            // the same epoch from the ledger-only manifest, otherwise the next page would get a fresh set.
            let fu4Resumed = CaptureSession()
            let fu4Restored = fu4Resumed.sessionId == fu4First.sessionId && fu4Resumed.photos.isEmpty
                && fu4Resumed.filedGroupIds.contains(fu4Group)
            let fu4Output = tmp.appendingPathComponent("fu4-out", isDirectory: true)
            let fu4Staging = tmp.appendingPathComponent("fu4-staging", isDirectory: true)
            try? fm.createDirectory(at: fu4Staging, withIntermediateDirectories: true)
            let fu4Config = SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                outputDirectory: fu4Output,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1)
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "should not run", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            fu4Resumed.beginStageSessionForTest()
            let fu4Late = fu4Resumed.ingest(jpeg: fu4Bytes, groupId: fu4Group, seq: 2, type: .document,
                                             quality: nil, year: nil, month: nil, deviceName: "TestPhone")
            let fu4StagedExcluded = fu4Resumed.orderedFilesAndGroups().files.isEmpty
            let fu4LateSegmentAck = fu4Resumed.markSegmentComplete(groupId: fu4Group, quality: "Q2",
                                                                    year: 2026, month: 9)
            let fu4LateFinishAck = fu4Resumed.completeAllOpenDocGroups()
            let fu4NoLateTagCard = fu4Resumed.pendingTagGroup == nil
                && !fu4Resumed.completedDocGroups.contains(fu4Group)
            fu4Resumed._recoveryTestBeginLive(config: fu4Config, stagingDir: fu4Staging)
            if let latePhoto = fu4Resumed.photos.first(where: { $0.groupId == fu4Group && $0.seq == 2 }) {
                fu4Resumed.liveProcessor.photoIngested(latePhoto)
            }
            let fu4Refused = fu4Late != nil && fu4Resumed.photos.contains { $0.groupId == fu4Group && $0.seq == 2 }
                && fu4Resumed.statusMessage.contains("already-finished document")
                && fu4Resumed.statusMessage.contains("Backup Folder")
                && fu4Resumed.statusMessage.contains("NEW segment")
                && LiveCaptureProcessor._recoveryTestOCRStarts.isEmpty
            check("W3.cap-r3-fu4: ledger-write failure keeps originals; filed IDs survive relaunch and block late OCR",
                  fu4Original != nil && fu4WriteRefused && fu4OriginalKept && fu4Recorded
                      && fu4Persisted && fu4Preserved && fu4Restored && fu4StagedExcluded
                      && fu4LateSegmentAck && fu4LateFinishAck && fu4NoLateTagCard && fu4Refused)
            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        } else {
            check("W3.cap-r3-fu4: recovery backup-root override resolves inside a temp directory", false)
        }

        // --- W3.cap-r3-fu4: if the ledger cannot be committed after destination moves, keep recovery state. ---
        if let backupOverride, tempRoots.contains(where: { backupPath == $0 || backupPath.hasPrefix($0 + "/") }) {
            let backupRoot = URL(fileURLWithPath: backupOverride, isDirectory: true)
            let priorSessions = (try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []
            for folder in priorSessions where CaptureSession.isSessionIdName(folder.lastPathComponent) {
                try? fm.removeItem(at: folder)
            }
            let failOut = tmp.appendingPathComponent("fu4-ledger-fail-out", isDirectory: true)
            let failSession = CaptureSession()
            let failStaging = LiveCaptureProcessor.stagingDir(for: failSession)
            try? fm.createDirectory(at: failStaging, withIntermediateDirectories: true)
            failSession._recoveryTestBeginLive(config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                outputDirectory: failOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1),
                stagingDir: failStaging)
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "ledger failure page", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            let failGroup = "fu4-ledger-failure"
            let failSource = failSession.ingest(jpeg: Data("scratch original".utf8), groupId: failGroup, seq: 1,
                                                 type: .document, quality: nil, year: nil, month: nil,
                                                 deviceName: "TestPhone")
            failSession.liveProcessor.segmentResolved(groupId: failGroup)
            var failStaged = false
            for _ in 0..<400 {
                if failSession.liveProcessor.staged.contains(where: { $0.groupId == failGroup }) {
                    failStaged = true; break
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            let failKey = failSession.liveProcessor.staged.first { $0.groupId == failGroup }?.collectionKey ?? "__unfiled__"
            failSession.manifestWriteOverride = { _, _ in false }
            failSession.liveProcessor.finalize([LiveCaptureProcessor.CollectionDraft(
                id: failKey, finalName: failOut.lastPathComponent, existingFolders: [], suggestedFolders: [],
                chosenExisting: failOut, segmentCount: 1, photoCount: 1)])
            var failFinalizeStopped = false
            for _ in 0..<400 {
                if !failSession.liveProcessor.isFinalizing { failFinalizeStopped = true; break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            let failManifest = failStaging.appendingPathComponent("staging-manifest.json")
            let failRecoveryKept = failSource.map { fm.fileExists(atPath: $0.path) } == true
                && failSession.photos.contains { $0.groupId == failGroup }
                && failSession.liveProcessor.staged.contains { $0.groupId == failGroup }
                && fm.fileExists(atPath: failManifest.path)
                && failSession.liveProcessor.finalizeSummary?.contains("ledger could not be saved") == true
            check("W3.cap-r3-fu4: failed post-move ledger write keeps originals and staged recovery data",
                  failStaged && failFinalizeStopped && failRecoveryKept)
            failSession.manifestWriteOverride = nil
            let failResumed = CaptureSession()
            failResumed.beginStageSessionForTest()
            let failRecoveredGroups = failResumed.liveProcessor.recoveredStagedGroupIds()
            check("W3.cap-r3-fu4: relaunch restores the source while ledger is absent",
                  failResumed.sessionId == failSession.sessionId && failResumed.filedGroupIds.isEmpty
                      && failResumed.photos.contains { $0.groupId == failGroup })
            check("W3.cap-r3-fu4: verified staging manifest identifies output after ledger-write failure",
                  failRecoveredGroups?.contains(failGroup) == true)
            let failHandoff = failResumed.orderedFilesAndGroups()
            check("W3.cap-r3-fu4: verified staged output blocks duplicate stage-for-later handoff after relaunch",
                  failHandoff.files.isEmpty)
            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        }

        // --- Tests 30-32: in their own file, because this function's size took the compiler past the heavy
        // job's memory limit (W46.rotation-majority-fix). ---
        if isolatedBackup {
            await runLateDocumentTests(tmp: tmp, stubModel: stubModel, bitmap: bitmap, check: check)
        }

        // --- Test 33 (W40.fix-processor-pending-invisible-after-relaunch): in its own file, because one more
        // test in this function took the compiler past the heavy job's memory limit. ---
        if isolatedBackup {
            await runPendingRelaunchTest(tmp: tmp, stubModel: stubModel,
                                         jpeg: bitmap?.representation(using: .jpeg, properties: [:]) ?? Data(),
                                         check: check)
        }

        // Last by design: this synthetic session may be the newest recoverable one in the shared scratch
        // backup root, so do not let it influence any preceding restart fixture.
        if isolatedBackup {
            let corruptStageSession = CaptureSession()
            corruptStageSession.beginStageSessionForTest()
            let corruptStagePhoto = corruptStageSession.ingest(
                jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), groupId: "corrupt-stage", seq: 1,
                type: .document, quality: nil, year: nil, month: nil, deviceName: nil)
            let corruptStageDir = LiveCaptureProcessor.stagingDir(for: corruptStageSession)
            try? fm.createDirectory(at: corruptStageDir, withIntermediateDirectories: true)
            let corruptBytes = Data("untrusted staging recovery bytes".utf8)
            try? corruptBytes.write(to: corruptStageDir.appendingPathComponent("staging-manifest.json"), options: .atomic)
            let corruptStageProcessor = corruptStageSession.liveProcessor
            corruptStageProcessor.clearSession()
            let quarantinedName = ((try? fm.contentsOfDirectory(atPath: corruptStageDir.path)) ?? [])
                .first { $0.hasPrefix("staging-manifest.corrupt-") }
            let preservedCorruptBytes = quarantinedName.flatMap {
                try? Data(contentsOf: corruptStageDir.appendingPathComponent($0))
            }
            check("Stage-for-later Clear preserves an unverified manifest and leaves its source in place (fu12-fu2)",
                  corruptStageProcessor.stagingRecoveryBlocked
                      && corruptStagePhoto.map { fm.fileExists(atPath: $0.path) } == true
                      && preservedCorruptBytes == corruptBytes)
        }

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["LIVECAPTURE_RECOVERYTEST_OUT"]
            ?? fm.temporaryDirectory.appendingPathComponent("APRecoveryTest-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: tmp)
        NSLog("RECOVERYTEST DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}

#endif
