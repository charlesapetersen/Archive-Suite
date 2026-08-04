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
///
/// Writes a PASS/FAIL report to `LIVECAPTURE_RECOVERYTEST_OUT` (or a temp file) + NSLog. Test scaffolding.
@MainActor
enum LiveCaptureRecoveryTestDriver {
    private static var didRun = false

    /// Read-only view of the on-disk staging manifest (W3.cap-r6). The processor's own `StagingManifest` is
    /// private, and the test only needs to know WHICH segments survived a finalize.
    private struct ManifestPeek: Decodable {
        let staged: [LiveCaptureProcessor.StagedSegment]
    }

    /// A one-shot async gate (W3.cap-r5). Installed as the stub OCR's `_recoveryTestOCRGate`, it parks a
    /// `finalizeSegment` at its per-page await until the driver has delivered the out-of-order Box and calls
    /// `open()`. The defect lives only in that window, so the test has to *hold* the window open rather than
    /// hope a sleep lands inside it. Resuming an already-open gate is safe (a late waiter runs immediately),
    /// so a page ingested after `open()` is never stranded.
    private final class TestGate: @unchecked Sendable {
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

        let tmp = fm.temporaryDirectory.appendingPathComponent("APRecoveryTest-\(UUID().uuidString)", isDirectory: true)
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
        check("A.pdf actually landed in the collection folder", fm.fileExists(atPath: out.appendingPathComponent("00001 Coll.pdf").path))

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
        // Second finalize: SAME folder + name, "New collection" (appending:false) — must not restart at 00001.
        let retry = LiveCaptureProcessor._recoveryTestFinalizeMove([
            (folder: out6, name: "Reuse", appending: false,
             segments: [(groupId: "E2", pdfURLs: [pdfE2], imageURLs: [], jsonURL: nil, complete: true)])
        ])
        let firstStillThere = fm.fileExists(atPath: out6.appendingPathComponent("00001 Reuse.pdf").path)
        let secondNumbered = fm.fileExists(atPath: out6.appendingPathComponent("00002 Reuse.pdf").path)
        check("retry into a populated folder does NOT overwrite the first file", firstStillThere)
        check("retry continues numbering at 00002 (no collision)", secondNumbered && retry.filedGroupIds.contains("E2"))

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

        // (e) The WIRING: that verdict has to reach the manifest, or finalize still can't warn. Pre-placing
        // an immutable file at the staged PDF's path fails every write against it — realistic (a locked
        // output fails as a unit) and enough to prove the verdict is threaded onto the segment.
        let wireTagDir = tmp.appendingPathComponent("tagwire", isDirectory: true)
        try? fm.createDirectory(at: wireTagDir, withIntermediateDirectories: true)
        let lockedSrc = makeJPEG("held.jpg", in: wireTagDir)
        let lockedOut = wireTagDir.appendingPathComponent("held.pdf")
        try? Data("pre-existing".utf8).write(to: lockedOut)
        try? fm.setAttributes([.immutable: true], ofItemAtPath: lockedOut.path)
        let lockedSeg = LiveCaptureProcessor._recoveryTestStageSegment(
            sources: [lockedSrc], stagingDir: wireTagDir, model: stubModel,
            type: .document, baseTags: ["1948"], jsonTags: GeneratedTags(), stampUnread: true)
        check("an un-taggable staged artifact is recorded on the segment (the wiring)",
              lockedSeg.untaggedOutputs == [lockedOut])
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
            func makeConfig(_ out: URL) -> SessionProcessingConfig {
                SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    taggingMode: .automatic, rotationMode: .off, mergeDocuments: false,
                    outputDirectory: out, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1)
            }
            func stagedSeg(_ gid: String, pdf: URL) -> LiveCaptureProcessor.StagedSegment {
                LiveCaptureProcessor.StagedSegment(
                    groupId: gid, type: CaptureGroupType.document.rawValue, collectionKey: gid, order: 0,
                    pdfURLs: [pdf], imageURLs: [], jsonURL: nil, boxLabelText: nil, pagesComplete: true)
            }
            // `chosenExisting` is set on purpose: it makes the destination an explicit scratch folder, so
            // `currentOutputDirectory` (which would otherwise fall back to the operator's real Settings
            // output folder) can never contribute a path to this test.
            func draft(_ key: String, into folder: URL) -> LiveCaptureProcessor.CollectionDraft {
                LiveCaptureProcessor.CollectionDraft(
                    id: key, finalName: folder.lastPathComponent, existingFolders: [], suggestedFolders: [],
                    chosenExisting: folder, segmentCount: 1, photoCount: 1)
            }
            func manifestGroupIds(_ dir: URL) -> [String] {
                let u = dir.appendingPathComponent("staging-manifest.json")
                guard let d = try? Data(contentsOf: u),
                      let m = try? JSONDecoder().decode(ManifestPeek.self, from: d) else { return [] }
                return m.staged.map(\.groupId)
            }
            func settle(_ p: LiveCaptureProcessor) async {
                for _ in 0..<400 {
                    if !p.isFinalizing { return }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
            }
            // One session for both scenarios: `LiveCaptureProcessor` holds it `unowned`, and finalize only
            // uses it for `clearFiled` — which retires nothing here, because no `retained` sources exist.
            let r6Session = CaptureSession()
            // Distinctively NAMED staging dirs (not `_processed`) so the reclaim case can take its own
            // folder back out of the Trash instead of leaving one behind on every Tier-2 run.
            let tok = String(UUID().uuidString.prefix(8))

            // (b) THE BUG: a straggler finalizes during the move.
            let keepDir = tmp.appendingPathComponent("APStaging-keep-\(tok)", isDirectory: true)
            try? fm.createDirectory(at: keepDir, withIntermediateDirectories: true)
            let plannedPDF = keepDir.appendingPathComponent("planned.pdf")
            try? Data("planned".utf8).write(to: plannedPDF)
            let keepOut = tmp.appendingPathComponent("r6keep", isDirectory: true)
            let keepProc = LiveCaptureProcessor(session: r6Session)
            keepProc._recoveryTestArm(stagingDir: keepDir, config: makeConfig(keepOut),
                                      staged: [stagedSeg("planned", pdf: plannedPDF)])
            keepProc.finalize([draft("planned", into: keepOut)])
            // Still the SAME MainActor turn: `finalize` has already snapshotted `plans` and enqueued its
            // Task, but that Task cannot have run. Writing output into the staging dir and appending to
            // `staged` here reproduces the straggler's interleaving exactly, and deterministically.
            let stragglerPDF = keepDir.appendingPathComponent("straggler.pdf")
            try? Data("straggler".utf8).write(to: stragglerPDF)
            keepProc._recoveryTestAppendStaged(stagedSeg("straggler", pdf: stragglerPDF))
            await settle(keepProc)
            check("a straggler that finalized during the move KEEPS the staging directory",
                  fm.fileExists(atPath: keepDir.path))
            check("...and its processed output is still on disk, not in the Trash",
                  fm.fileExists(atPath: stragglerPDF.path))
            check("...and it is still staged, so Finish again can file it",
                  keepProc.staged.map(\.groupId) == ["straggler"])
            check("...and the reduced manifest on disk lists exactly the straggler",
                  manifestGroupIds(keepDir) == ["straggler"])
            check("...while the PLANNED segment really did file (the fix costs nothing)",
                  !fm.fileExists(atPath: plannedPDF.path)
                      && fm.fileExists(atPath: keepOut.appendingPathComponent("00001 r6keep.pdf").path))
            check("...and the operator is TOLD, instead of seeing a clean \"Finalized\"",
                  keepProc.finalizeSummary?.contains("finished processing while this batch was being filed") == true)

            // (c) The happy path must still reclaim: nothing arrives behind the move, so the spent staging
            // dir goes to the Trash exactly as before.
            let goneDir = tmp.appendingPathComponent("APStaging-reclaim-\(tok)", isDirectory: true)
            try? fm.createDirectory(at: goneDir, withIntermediateDirectories: true)
            let onlyPDF = goneDir.appendingPathComponent("only.pdf")
            try? Data("only".utf8).write(to: onlyPDF)
            let goneOut = tmp.appendingPathComponent("r6gone", isDirectory: true)
            let goneProc = LiveCaptureProcessor(session: r6Session)
            goneProc._recoveryTestArm(stagingDir: goneDir, config: makeConfig(goneOut),
                                      staged: [stagedSeg("only", pdf: onlyPDF)])
            goneProc.finalize([draft("only", into: goneOut)])
            await settle(goneProc)
            check("no straggler → the spent staging directory is still reclaimed (regression)",
                  !fm.fileExists(atPath: goneDir.path) && goneProc.staged.isEmpty)
            check("...and the summary carries no straggler warning",
                  goneProc.finalizeSummary?.contains("finished processing while") != true)
            // The reclaim above went to the Trash (recoverable, by design). Take our own probe folder back
            // out so a Tier-2 run doesn't leave one behind each time — best-effort, since the physical
            // Trash location varies with the app's launch context. The assertion is about the ORIGINAL
            // path being gone, so it does not depend on this succeeding.
            try? fm.removeItem(at: fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash/\(goneDir.lastPathComponent)"))
        }

        // --- Test 14 (W3.cap-r2): a phone auto-retry after a dropped ack must not buy a SECOND paid OCR
        // call. `CaptureSession.ingest` already de-duplicates a re-upload on `(groupId, seq)` — it REPLACES
        // the stored photo rather than appending one — but `CapturedPhoto.id` is a fresh `UUID()` per value,
        // so the processor's "already started" guard, keyed on that id, saw a brand-new page and started OCR
        // a second time (the first Task orphaned, both calls billed). Driven through the REAL `ingest` path
        // with a $0 stand-in for the paid call, so what the test counts IS what the operator gets charged. ---
        if isolatedBackup {
            let r2Out = tmp.appendingPathComponent("r2out", isDirectory: true)
            let r2Staging = tmp.appendingPathComponent("APStaging-r2-\(String(UUID().uuidString.prefix(8)))",
                                                       isDirectory: true)
            try? fm.createDirectory(at: r2Staging, withIntermediateDirectories: true)
            let r2Session = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            r2Session._recoveryTestBeginLive(
                config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    taggingMode: .automatic, rotationMode: .off, mergeDocuments: false,
                    outputDirectory: r2Out, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1),
                stagingDir: r2Staging)
            let jpeg = Data("synthetic page bytes".utf8)
            func send(_ gid: String, _ seq: Int) -> Bool {
                r2Session.ingest(jpeg: jpeg, groupId: gid, seq: seq, type: .document,
                                 priority: nil, year: nil, month: nil, deviceName: "TestPhone") != nil
            }
            func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }

            let firstAccepted = send("G1", 1)
            check("the page's first upload is accepted (so the retry checks aren't passing on nothing)",
                  firstAccepted)
            check("...and it starts exactly one paid OCR call", paidStarts() == 1)

            let retryAccepted = send("G1", 1)   // THE BUG: the phone's auto-retry after a dropped ack
            check("the dropped-ack retry is accepted too (a real second trip through ingest)", retryAccepted)
            check("a re-upload of the SAME (groupId, seq) buys NO second paid OCR call", paidStarts() == 1)
            check("...and the session still holds exactly one photo for that page", r2Session.photos.count == 1)
            // Counting starts alone cannot catch a fix that de-duplicates but files the surviving Task under
            // a key nothing reads: ask the REPLACEMENT photo for its result, the way finalize asks. Without
            // this the page would finalize as "OCR not started" and be filed image-only.
            let replaced = r2Session.photos.first
            let carried = replaced == nil ? nil
                : await r2Session.liveProcessor._recoveryTestPageOCRText(for: replaced!)
            check("...and finalize still reaches the FIRST call's result through the replacement photo",
                  carried == "stub page text")

            // The guard must not over-dedup — `(groupId, seq)` has to keep genuinely distinct pages distinct.
            check("a genuinely new page in the same group still starts its own OCR",
                  send("G1", 2) && paidStarts() == 2)
            check("a page in a different group still starts its own OCR",
                  send("G2", 3) && paidStarts() == 3)

            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
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
            let r5Out = tmp.appendingPathComponent("r5out", isDirectory: true)
            let r5Staging = tmp.appendingPathComponent("APStaging-r5-\(String(UUID().uuidString.prefix(8)))",
                                                       isDirectory: true)
            try? fm.createDirectory(at: r5Staging, withIntermediateDirectories: true)
            let r5Session = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            r5Session._recoveryTestBeginLive(
                config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    // `.human`, not `.automatic`: `computeTags` only reaches the LLM for a DOCUMENT in
                    // automatic mode, and a box/folder short-circuits to a colour tag inside `TagGenerator`.
                    // So this test finalizes real segments for $0 and never touches the network.
                    taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                    outputDirectory: r5Out, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1),
                stagingDir: r5Staging)
            let r5Proc = r5Session.liveProcessor
            let r5Bytes = Data("synthetic page bytes".utf8)
            func r5Send(_ gid: String, _ seq: Int, _ type: CaptureGroupType) {
                r5Session.ingest(jpeg: r5Bytes, groupId: gid, seq: seq, type: type,
                                 priority: nil, year: nil, month: nil, deviceName: "TestPhone")
            }
            func r5Settle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func r5Key(_ gid: String) -> String? { r5Proc.staged.first { $0.groupId == gid }?.collectionKey }

            // The gate the in-flight document's OCR result parks on. Holding it is what makes the
            // interleaving deterministic — a sleep would only *hope* to land inside the window.
            let r5Gate = TestGate()

            // 1. The first Box, delivered in order: it opens collection "B0".
            r5Send("B0", 1, .box)
            _ = await r5Settle { r5Key("B0") != nil }

            // 2. The document (capture seq 3). It was shot after a second Box, but the relay delivers it
            //    first, so on arrival it is pinned to the only Box the Mac has seen — "B0". Its page OCR is
            //    held, so the finalize its tag card triggers parks mid-flight.
            LiveCaptureProcessor._recoveryTestOCRGate = { await r5Gate.wait() }
            r5Send("D", 3, .document)
            LiveCaptureProcessor._recoveryTestOCRGate = nil   // hold THAT page only
            r5Proc.segmentResolved(groupId: "D")
            let parked = await r5Settle { r5Proc.isFinalized("D") }
            check("the document is genuinely mid-finalize when the Box lands (finalized, not yet staged)",
                  parked && r5Key("D") == nil)

            // 3. THE BUG: the out-of-order Box (capture seq 2 — before the document) arrives NOW, inside
            //    the window. It is the document's correct collection.
            r5Send("B1", 2, .box)

            // 4. Release the held page and let the segment finish writing itself out.
            r5Gate.open()
            let landed = await r5Settle { r5Key("D") != nil }
            check("the in-flight document finishes staging", landed)
            check("an out-of-order Box delivered mid-finalize RE-PINS the in-flight document",
                  r5Key("D") == "B1")
            check("...and the live map the rotation review regenerates from agrees",
                  r5Proc._recoveryTestLiveCollectionKey(for: "D") == "B1")
            // The out-of-order Box's own finalize was only ENQUEUED by `ingest`; settle for it before asking
            // about its staged record (it reds ~1 run in 10 on a loaded machine otherwise — W3.cap-r4).
            _ = await r5Settle { r5Key("B1") != nil }
            check("a Box is still its own collection and is never re-pinned",
                  r5Key("B0") == "B0" && r5Key("B1") == "B1")

            // 5. The correction is ordered, not "latest wins": a Box captured AFTER the document (seq 4)
            //    must not steal it away from B1.
            r5Send("B2", 4, .box)
            _ = await r5Settle { r5Key("B2") != nil }
            check("a Box captured AFTER the document does not steal it", r5Key("D") == "B1")

            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRGate = nil
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
            let r4Out = tmp.appendingPathComponent("r4out", isDirectory: true)
            let r4Staging = tmp.appendingPathComponent("APStaging-r4-\(String(UUID().uuidString.prefix(8)))",
                                                       isDirectory: true)
            try? fm.createDirectory(at: r4Staging, withIntermediateDirectories: true)
            // Isolation, and it is load-bearing: `CaptureSession.init` adopts the newest backup session that
            // still holds unprocessed photos (crash recovery). The tests above leave theirs behind, so
            // without this the session below inherits their groups — including BOXES, whose capture order
            // then decides where this test's document is pinned. That is the exact fact under test, and it
            // made the first draft of this test pass before it had done anything. Only session-named folders
            // under the throwaway root are removed (`isolatedBackup` is what proves it is the script's
            // mktemp dir and not the operator's Backup Folder), matched with the same conservative predicate
            // launch-time pruning uses.
            if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
               !testRoot.isEmpty {
                let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                           includingPropertiesForKeys: nil)) ?? []
                for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                    try? fm.removeItem(at: e)
                }
            }
            let r4Session = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
            r4Session._recoveryTestBeginLive(
                config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                    outputDirectory: r4Out, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1),
                stagingDir: r4Staging)
            let r4Proc = r4Session.liveProcessor
            let r4Bytes = Data("synthetic page bytes".utf8)
            func r4Send(_ gid: String, _ seq: Int, _ type: CaptureGroupType) {
                r4Session.ingest(jpeg: r4Bytes, groupId: gid, seq: seq, type: type,
                                 priority: nil, year: nil, month: nil, deviceName: "TestPhone")
            }
            func r4Settle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func r4Key(_ gid: String) -> String? { r4Proc.staged.first { $0.groupId == gid }?.collectionKey }

            // 1. A Box, then the document (capture seq 3) — both in order, so it pins to the only Box seen.
            r4Send("B0", 1, .box)
            _ = await r4Settle { r4Key("B0") != nil }
            r4Send("D", 3, .document)
            r4Proc.segmentResolved(groupId: "D")
            let r4Staged = await r4Settle { r4Key("D") != nil }
            check("the document stages under the only Box the Mac has seen", r4Staged && r4Key("D") == "B0")

            // 2. The out-of-order Box (capture seq 2 — shot BEFORE the document) finally arrives. It is the
            //    document's real collection, and backfill corrects the already-staged record.
            r4Send("B1", 2, .box)
            check("an out-of-order Box corrects the already-staged document", r4Key("D") == "B1")
            // `ingest` back-fills synchronously (the check above is deterministic) but only ENQUEUES the
            // Box's own finalize. The draft assertion below reads `beginFinalize`'s grouping, which sees
            // only what has staged — so wait for the Box itself, or the last check turns into a load-
            // dependent flake that reds on a busy machine while the product invariant is fine.
            _ = await r4Settle { r4Key("B1") != nil }

            // 3. THE BUG: the operator straightens that page in the end-of-session rotation review. This is
            //    the review sheet's own path — it edits the page list, then applies.
            let r4Source = r4Session.photos.first { $0.groupId == "D" }?.url
            check("the staged document's source page is on disk for regeneration", r4Source != nil)
            if let r4Source {
                r4Proc.rotationReviewPages = [
                    LiveCaptureProcessor.RotationReviewPage(groupId: "D", pageIndex: 0, order: 3,
                                                            sourceURL: r4Source, rotationDegrees: 90)
                ]
                r4Proc.applyRotationReviewAndFinalize()
                // Non-vacuity: `isFinalizing` is set synchronously ONLY when there is a segment to regenerate.
                // Without this the checks below could pass on a run that never re-wrote anything.
                check("the rotation change really does trigger a regeneration", r4Proc.isFinalizing)
                let r4Done = await r4Settle { !r4Proc.isFinalizing }
                check("...and the regeneration completes", r4Done)
                check("straightening a page does NOT re-file the document into the previous collection",
                      r4Key("D") == "B1")
                // What the operator actually sees next: the naming sheet groups by collection key. The
                // misfile shows up here as the document sitting in the wrong draft.
                let b1 = r4Proc.drafts.first { $0.id == "B1" }
                let b0 = r4Proc.drafts.first { $0.id == "B0" }
                check("...so the naming sheet offers the document with its own Box, not the previous one",
                      b1?.segmentCount == 2 && b0?.segmentCount == 1)
            }

            LiveCaptureProcessor._recoveryTestOCRStub = nil
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
            // Same isolation as Test 16, and load-bearing for the same reason: `CaptureSession.init` adopts
            // the newest backup session that still holds unprocessed photos, and the tests above leave theirs
            // behind. Inheriting their photos would put pages in this session that it never ingested — and
            // `paidStarts()` counts starts for the whole run, so the counts below would read someone else's.
            if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
               !testRoot.isEmpty {
                let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                           includingPropertiesForKeys: nil)) ?? []
                for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                    try? fm.removeItem(at: e)
                }
            }
            let r3Out = tmp.appendingPathComponent("r3out", isDirectory: true)
            let r3Staging = tmp.appendingPathComponent("APStaging-r3-\(String(UUID().uuidString.prefix(8)))",
                                                       isDirectory: true)
            try? fm.createDirectory(at: r3Staging, withIntermediateDirectories: true)
            let r3Session = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            r3Session._recoveryTestBeginLive(
                config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    // `.human` — see Test 15: a document only reaches the LLM in `.automatic`, so the
                    // mid-finalize case below finalizes for real, for $0, with no network.
                    taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                    outputDirectory: r3Out, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1),
                stagingDir: r3Staging)
            let r3Proc = r3Session.liveProcessor
            let r3Bytes = Data("synthetic page bytes".utf8)
            // The gate keeps every page this test ingests parked mid-OCR. A finished Task cannot be shown to
            // have been cancelled, so an un-gated page would make every assertion below vacuous.
            let r3Gate = TestGate()
            LiveCaptureProcessor._recoveryTestOCRGate = { await r3Gate.wait() }
            func r3Send(_ gid: String, _ seq: Int) {
                r3Session.ingest(jpeg: r3Bytes, groupId: gid, seq: seq, type: .document,
                                 priority: nil, year: nil, month: nil, deviceName: "TestPhone")
            }
            func r3Settle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
            func photo(_ gid: String, _ seq: Int) -> CapturedPhoto? {
                r3Session.photos.first { $0.groupId == gid && $0.seq == seq }
            }
            func cancelled(_ p: CapturedPhoto) -> Bool {
                LiveCaptureProcessor._recoveryTestOCRTasks[LiveCaptureProcessor.PageKey(p)]?.isCancelled ?? false
            }

            // 1. THE BUG: the operator deletes a page in the Captured pane while its OCR is still in flight.
            r3Send("R1", 1)
            let p1 = photo("R1", 1)
            check("the deleted-mid-OCR page was really ingested and bought a call",
                  p1 != nil && paidStarts() == 1)
            if let p1 {
                // Non-vacuity: the call must be LIVE and reachable at the moment of the delete, or "cancelled
                // + gone" afterwards would be true of a page that had simply already finished.
                check("...its call is in flight, uncancelled, and held in pageTasks before the delete",
                      !cancelled(p1) && r3Proc._recoveryTestHasPageTask(for: p1))

                r3Session.removePhoto(p1)

                check("deleting the page CANCELS its paid OCR call", cancelled(p1))
                check("...and drops its Task out of pageTasks (nothing orphaned)",
                      !r3Proc._recoveryTestHasPageTask(for: p1))
                check("...and the page really did leave the session", photo("R1", 1) == nil)
                // The started-once guard (W3.cap-r2) has to be retired WITH the task: this page has no OCR
                // any more, so if the phone re-sends it, it must be free to buy a new call. Leaving the guard
                // armed over an absent task would file the page as "OCR not started" instead — silently
                // text-less. This is also the behavioural read of the started-once guard, which is private
                // (`pageTasks`, since W3.cap-r3-fu1 retired the second copy that used to shadow it).
                r3Send("R1", 1)
                check("...so a later arrival of that same page is free to buy its own call",
                      photo("R1", 1) != nil && paidStarts() == 2)
            }

            // 2. The cancel is scoped to the ONE page. A fix that cancelled the group (or the session) would
            //    silently throw away the sibling pages the operator is still capturing.
            r3Send("R2", 1)
            r3Send("R2", 2)
            let s1 = photo("R2", 1), s2 = photo("R2", 2)
            check("a two-page group has both pages in flight", s1 != nil && s2 != nil && paidStarts() == 4)
            if let s1, let s2 {
                r3Session.removePhoto(s1)
                check("deleting one page of a group cancels exactly that page", cancelled(s1))
                check("...and leaves its sibling's call running and reachable",
                      !cancelled(s2) && r3Proc._recoveryTestHasPageTask(for: s2))
            }

            // 3. The reclassify path (`X-Replaces`): the phone moved a page into another group, so the Mac
            //    tombstones the old copy. The OCR bought for that old copy is money nobody will read either.
            r3Send("R3", 7)
            let t1 = photo("R3", 7)
            check("the reclassified page's old copy is in flight", t1 != nil && paidStarts() == 5)
            if let t1 {
                r3Session.removePhotoIfSafe(groupId: "R3", seq: 7)
                check("tombstoning a reclassified page's old copy cancels its OCR too", cancelled(t1))
                check("...and orphans nothing in pageTasks", !r3Proc._recoveryTestHasPageTask(for: t1))
                check("...and the old copy is gone from the session", photo("R3", 7) == nil)
            }

            // 4. The deliberate carve-out, and the reason this fix is a guard rather than an unconditional
            //    cancel: while the segment is MID-FINALIZE, finalize is the task's consumer. It snapshotted
            //    the group before its awaits and is about to read this page's result into the segment's text,
            //    so the call is already bought — cancelling there would discard paid output instead of saving
            //    any. Without this check, "cancel unconditionally" passes every assertion above.
            r3Send("R4", 1)
            let f1 = photo("R4", 1)
            r3Proc.segmentResolved(groupId: "R4")
            let parked = await r3Settle { r3Proc.isFinalized("R4") }
            check("the segment is genuinely mid-finalize (finalized, not yet staged)",
                  parked && f1 != nil && r3Proc.retainedText(for: "R4") == nil)
            if let f1 {
                r3Session.removePhoto(f1)
                check("a page removed MID-FINALIZE is not cancelled", !cancelled(f1))
                check("...and its Task stays in pageTasks for finalize to read",
                      r3Proc._recoveryTestHasPageTask(for: f1))
                r3Gate.open()   // release every parked page; finalize can now finish
                let consumed = await r3Settle { r3Proc.retainedText(for: "R4") != nil }
                check("...and finalize really does consume the result it was left",
                      consumed && r3Proc.retainedText(for: "R4") == "stub page text")
            }

            // 5. The same carve-out, measured on the OUTPUT rather than on the mechanism. Scenario 4 can only
            //    assert the Task's state: finalize had already read that one page's Task out of `pageTasks`
            //    before it suspended, so removing the entry afterwards costs it nothing, and the test gate is
            //    cancellation-blind by design (Test 15 needs it to park, not to throw). Here the removed page
            //    is the SECOND of two, and finalize is parked on the FIRST — so its entry has not been read
            //    yet and an unconditional cancel really does lose it. The segment's retained text is then
            //    short by a page: the operator paid for two pages of OCR and the record keeps one. That is
            //    the consequence the guard exists to prevent, and it is what makes this more than a
            //    restatement of the implementation.
            let gate5 = TestGate()
            LiveCaptureProcessor._recoveryTestOCRGate = { await gate5.wait() }
            r3Send("R5", 1)
            r3Send("R5", 2)
            LiveCaptureProcessor._recoveryTestOCRGate = nil
            let g2 = photo("R5", 2)
            r3Proc.segmentResolved(groupId: "R5")
            let parked5 = await r3Settle { r3Proc.isFinalized("R5") }
            check("a two-page segment is mid-finalize, parked on its FIRST page",
                  parked5 && g2 != nil && r3Proc.retainedText(for: "R5") == nil)
            if let g2 {
                r3Session.removePhoto(g2)
                gate5.open()
                let done5 = await r3Settle { r3Proc.retainedText(for: "R5") != nil }
                let pages = (r3Proc.retainedText(for: "R5") ?? "").components(separatedBy: "stub page text").count - 1
                check("deleting the not-yet-read page mid-finalize does NOT drop the OCR it already paid for",
                      done5 && pages == 2)
            }

            // 6. The IDENTITY the delete resolves — found by the adversarial pass over the fix above, and the
            //    one way this fix could have made things worse than the bug it closes. `CapturedPhoto.id` is
            //    a fresh UUID minted per VALUE (and `==` compares only `id`), while an idempotent re-upload —
            //    the phone resuming after a dropped ack — replaces the value in `photos` under the SAME
            //    `(groupId, seq)` with a NEW id. A SwiftUI row closure rendered before that replace therefore
            //    hands the delete a photo whose `id` is gone. The cancel keys on `(groupId, seq)`; the
            //    removal used to key on `id`. In that window the two disagreed: the cancel killed the LIVE
            //    page's call and `removeAll` removed nothing, so a page stayed in the session with no task
            //    and its source in the Trash — which finalize files as "OCR not started" over a placeholder
            //    image, i.e. a silently text-less archival document. Pre-fix that same window trashed the
            //    file but left the OCR running, so the text survived; keying the two halves differently is
            //    what widened the harm.
            let gate6 = TestGate()
            LiveCaptureProcessor._recoveryTestOCRGate = { await gate6.wait() }
            r3Send("R6", 1)
            r3Send("R6", 2)
            let stale2 = photo("R6", 2)     // the value a row closure captured…
            r3Send("R6", 2)                 // …then the phone re-uploads that page: same key, NEW value/id
            let live2 = photo("R6", 2)
            check("an idempotent re-upload replaces the page's value under the same key, with a new id",
                  stale2 != nil && live2 != nil && stale2?.id != live2?.id
                      && stale2?.groupId == live2?.groupId && stale2?.seq == live2?.seq)
            if let stale2, let live2 {
                // Non-vacuity: the live page's call has to be in flight and reachable here, or the
                // "left behind with its call cancelled" invariant below could not distinguish anything.
                check("...and the live page's call is in flight and reachable before the delete",
                      !cancelled(live2) && r3Proc._recoveryTestHasPageTask(for: live2))
                r3Session.removePhoto(stale2)   // the operator's ✕, holding the pre-replace value
                check("deleting through a stale value still removes the page it names", photo("R6", 2) == nil)
                // The harm, stated as an invariant over what is LEFT rather than over the mechanism: no page
                // may remain in the session with its paid call cancelled, its Task gone, or its source
                // trashed under it. Pre-fix, page 2 is still listed and fails all three.
                let orphaned = r3Session.photos.filter { $0.groupId == "R6" }.filter {
                    cancelled($0) || !r3Proc._recoveryTestHasPageTask(for: $0)
                        || !fm.fileExists(atPath: $0.url.path)
                }
                check("...leaving no page in the session whose call was cancelled or whose source was trashed",
                      orphaned.isEmpty)
                check("...and the sibling page it did not name is untouched",
                      photo("R6", 1).map { !cancelled($0) && r3Proc._recoveryTestHasPageTask(for: $0) } == true)
                gate6.open()   // release R6's parked pages; nothing after this ingests
            }

            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            LiveCaptureProcessor._recoveryTestOCRGate = nil
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
            // Same isolation as Tests 16/17, load-bearing for the same reason: `CaptureSession.init` adopts
            // the newest backup session that still holds unprocessed photos, and every test above leaves
            // theirs behind. Inherited photos would put pages in this session it never ingested, and
            // `paidStarts()` counts starts for the whole run.
            if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
               !testRoot.isEmpty {
                let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                           includingPropertiesForKeys: nil)) ?? []
                for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                    try? fm.removeItem(at: e)
                }
            }
            let fuOut = tmp.appendingPathComponent("fu1out", isDirectory: true)
            let fuStaging = tmp.appendingPathComponent("APStaging-fu1-\(String(UUID().uuidString.prefix(8)))",
                                                       isDirectory: true)
            try? fm.createDirectory(at: fuStaging, withIntermediateDirectories: true)
            let fuSession = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            fuSession._recoveryTestBeginLive(
                config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    // `.human` — a document only reaches the LLM in `.automatic`, so every finalize below
                    // runs for real, for $0, with no network.
                    taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                    outputDirectory: fuOut, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1),
                stagingDir: fuStaging)
            let fuProc = fuSession.liveProcessor
            let fuBytes = Data("synthetic page bytes".utf8)
            func fuSend(_ gid: String, _ seq: Int) {
                fuSession.ingest(jpeg: fuBytes, groupId: gid, seq: seq, type: .document,
                                 priority: nil, year: nil, month: nil, deviceName: "TestPhone")
            }
            func fuSettle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
            func fuPhoto(_ gid: String, _ seq: Int) -> CapturedPhoto? {
                fuSession.photos.first { $0.groupId == gid && $0.seq == seq }
            }
            func textPages(_ gid: String) -> Int {
                (fuProc.retainedText(for: gid) ?? "").components(separatedBy: "stub page text").count - 1
            }
            func lateWarned() -> Bool { fuSession.statusMessage.contains("late page arrived") }

            // 1. The page is re-sent while its document is STAGED but not yet filed. The app has a message for
            //    exactly this ("a late page arrived… kept in the Backup Folder"), and the stale guard made it
            //    unreachable for the only pages that can reach that state: the page vanished into a `return`.
            fuSend("F1", 1)
            fuProc.segmentResolved(groupId: "F1")
            let f1Staged = await fuSettle { fuProc.staged.contains { $0.groupId == "F1" } }
            check("the document staged, so the re-send below is a genuine late arrival",
                  f1Staged && paidStarts() == 1 && fuProc.isFinalized("F1") && !lateWarned())
            fuSend("F1", 1)
            check("a page re-sent for an already-staged document TELLS the operator instead of vanishing",
                  lateWarned())
            check("...and buys nothing — it cannot join a document that is already written",
                  paidStarts() == 1)

            // 2. THE HARM. The operator hits Finish, the document files, and `finalize` drops it from
            //    `finalizedGroups` — so the late-page branch above no longer covers its pages, and the stale
            //    key was the only thing left in front of them. Pre-fix a page re-sent NOW bought nothing and
            //    the document it landed in carried no text for it.
            let f1Key = fuProc.staged.first { $0.groupId == "F1" }?.collectionKey ?? "__unfiled__"
            fuProc.finalize([LiveCaptureProcessor.CollectionDraft(
                id: f1Key, finalName: fuOut.lastPathComponent, existingFolders: [], suggestedFolders: [],
                chosenExisting: fuOut, segmentCount: 1, photoCount: 1)])
            let filed = await fuSettle { !fuProc.isFinalizing && fuProc.staged.isEmpty }
            check("the document really filed, so what follows is the post-filing state and not a partial",
                  filed && !fuProc.isFinalized("F1"))
            // Finish reclaimed the spent staging dir along with the batch (W3.cap-r6). Put it back, so the
            // re-finalize below writes its output for the same reason a live session's would and the checks
            // read the OCR rather than a missing directory.
            try? fm.createDirectory(at: fuStaging, withIntermediateDirectories: true)
            fuSend("F1", 1)   // the phone's dropped-ack re-upload, arriving after Finish
            check("a page re-sent after its document was FILED buys the OCR call it needs", paidStarts() == 2)
            fuSend("F1", 2)   // …and a genuinely new page of the same document, which always bought one
            check("...and a genuinely new page still buys its own (the guard is not just disabled)",
                  paidStarts() == 3)
            fuProc.segmentResolved(groupId: "F1")
            let refiled = await fuSettle { fuProc.retainedText(for: "F1") != nil }
            // The consequence, measured on the record finalize wrote rather than on the guard: pre-fix the
            // re-sent page is read as "OCR not started" and contributes an empty string, so the document goes
            // out with ONE page of text where the operator captured two.
            check("...so the document is filed with BOTH pages' text, not \"OCR not started\" for one of them",
                  refiled && textPages("F1") == 2)
            // …and this is why it had to be fixed at ingest: the sibling's text means no status ever says a
            // page came out empty. `succeededNoText` (the one warning about missing text) needs the WHOLE
            // segment to be text-less, so it never fires for the mixed case the phone actually produces.
            check("...which nothing would have warned about: with a text-bearing sibling the segment is not "
                  + "reported text-less",
                  fuProc.statuses.first { $0.id == "F1" }?.phase != .succeededNoText)

            // 3. The trap this fix had to avoid, and the reason it is keyed on the Task rather than retired in
            //    the carve-out: a page removed MID-FINALIZE keeps the Task finalize is suspended on, so it
            //    must keep the guard too. Retiring the key there would let the phone's re-send overwrite that
            //    entry — buying the page a second time and handing finalize a different call's result — and
            //    would tell the operator a "late page arrived" for a page that IS being included. Both guards
            //    now cover the window (no Task is free, and the group is in `finalizedGroups`); these checks
            //    pin the OUTCOME, which is what a future edit to either one must not change.
            let fuGate = TestGate()
            LiveCaptureProcessor._recoveryTestOCRGate = { await fuGate.wait() }
            fuSend("F2", 1)
            fuSend("F2", 2)
            LiveCaptureProcessor._recoveryTestOCRGate = nil   // hold only F2's two pages
            let f2p2 = fuPhoto("F2", 2)
            fuProc.segmentResolved(groupId: "F2")
            let parked = await fuSettle { fuProc.isFinalized("F2") }
            check("a two-page segment is mid-finalize, parked on its FIRST page",
                  parked && f2p2 != nil && paidStarts() == 5 && fuProc.retainedText(for: "F2") == nil)
            if let f2p2 {
                fuSession.removePhoto(f2p2)   // carve-out: not cancelled, its Task kept for finalize to read
                fuSend("F2", 2)               // the phone re-sends it INSIDE that window
                check("a page re-sent while finalize is suspended on its group buys NO second call",
                      paidStarts() == 5)
                check("...and is not mislabelled a late arrival — its call is the one being read",
                      !lateWarned())
                fuGate.open()
                let consumed = await fuSettle { fuProc.retainedText(for: "F2") != nil }
                check("...and finalize still reads both pages of OCR the operator paid for",
                      consumed && textPages("F2") == 2)
            }

            // 4. The other end of the same duplication, and the reason the fix DELETED the second record
            //    rather than kept it in sync: the reclaim branch of `finalize` used to empty that set
            //    WHOLESALE when a batch filed cleanly. Reclaim needs nothing left staged — not nothing left
            //    RUNNING — so a page still mid-OCR in a group this batch never planned was disarmed along
            //    with the filed ones, and the phone's dropped-ack re-upload of it could buy its call a second
            //    time. `pageTasks` cannot be emptied that way: the entry is the call.
            let fuGate4 = TestGate()
            LiveCaptureProcessor._recoveryTestOCRGate = { await fuGate4.wait() }
            fuSend("F3", 1)                                   // still mid-OCR, and never planned below
            LiveCaptureProcessor._recoveryTestOCRGate = nil
            let f2Key = fuProc.staged.first { $0.groupId == "F2" }?.collectionKey ?? "__unfiled__"
            fuProc.finalize([LiveCaptureProcessor.CollectionDraft(
                id: f2Key, finalName: fuOut.lastPathComponent, existingFolders: [], suggestedFolders: [],
                chosenExisting: fuOut, segmentCount: 1, photoCount: 1)])
            let reclaimed = await fuSettle { !fuProc.isFinalizing && fuProc.staged.isEmpty }
            check("a clean batch reclaims while a page of an unplanned group is still mid-OCR",
                  reclaimed && paidStarts() == 6
                      && fuPhoto("F3", 1).map { fuProc._recoveryTestHasPageTask(for: $0) } == true)
            fuSend("F3", 1)
            check("...and that page's re-upload still buys NO second call after the reclaim",
                  paidStarts() == 6)
            fuGate4.open()

            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            LiveCaptureProcessor._recoveryTestOCRGate = nil
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
            // Same isolation as Tests 16/17, load-bearing for the same reason: `CaptureSession.init` adopts
            // the newest backup session that still holds unprocessed photos, so inherited photos would put
            // pages in this session it never ingested and `paidStarts()` counts starts for the whole run.
            if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
               !testRoot.isEmpty {
                let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                           includingPropertiesForKeys: nil)) ?? []
                for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                    try? fm.removeItem(at: e)
                }
            }
            let ruOut = tmp.appendingPathComponent("fu2out", isDirectory: true)
            let ruStaging = tmp.appendingPathComponent("APStaging-fu2-\(String(UUID().uuidString.prefix(8)))",
                                                       isDirectory: true)
            try? fm.createDirectory(at: ruStaging, withIntermediateDirectories: true)
            let ruSession = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            ruSession._recoveryTestBeginLive(
                config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    // `.human` — a document only reaches the LLM in `.automatic`, so the re-finalize the
                    // retry triggers runs for real, for $0, with no network.
                    taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                    outputDirectory: ruOut, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1),
                stagingDir: ruStaging)
            let ruProc = ruSession.liveProcessor
            let ruBytes = Data("synthetic page bytes".utf8)
            func ruSend(_ gid: String, _ seq: Int) {
                ruSession.ingest(jpeg: ruBytes, groupId: gid, seq: seq, type: .document,
                                 priority: nil, year: nil, month: nil, deviceName: "TestPhone")
            }
            func ruSettle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
            func ruPhoto(_ gid: String, _ seq: Int) -> CapturedPhoto? {
                ruSession.photos.first { $0.groupId == gid && $0.seq == seq }
            }
            // The handle kept OUTSIDE `pageTasks` (W3.cap-r3): dropping the entry is exactly what makes the
            // Task unreachable everywhere else, so this is the only vantage from which a genuine `cancel()`
            // can be told from a silent drop — both leave `pageTasks` without that key.
            func ruTask(_ p: CapturedPhoto) -> Task<OCRResult, Never>? {
                LiveCaptureProcessor._recoveryTestOCRTasks[LiveCaptureProcessor.PageKey(p)]
            }
            func textPages(_ gid: String) -> Int {
                (ruProc.retainedText(for: gid) ?? "").components(separatedBy: "stub page text").count - 1
            }

            // 1. Two pages of the group to be retried, plus a page of a DIFFERENT group, all parked mid-OCR.
            //    A finished Task cannot be shown to have been cancelled, so without the gate every assertion
            //    below would be vacuous.
            let ruGate = TestGate()
            LiveCaptureProcessor._recoveryTestOCRGate = { await ruGate.wait() }
            ruSend("U1", 1)
            ruSend("U1", 2)
            ruSend("U2", 1)
            LiveCaptureProcessor._recoveryTestOCRGate = nil   // hold only these three; the re-ingest runs free
            let u1 = ruPhoto("U1", 1), u2 = ruPhoto("U1", 2), other = ruPhoto("U2", 1)
            // Captured BEFORE the retry: the re-ingest inside it overwrites these entries with the new Tasks.
            let oldT1 = u1.flatMap(ruTask), oldT2 = u2.flatMap(ruTask)
            check("the group's two pages bought calls that are genuinely in flight and uncancelled",
                  u1 != nil && u2 != nil && other != nil && paidStarts() == 3
                      && oldT1?.isCancelled == false && oldT2?.isCancelled == false
                      && u1.map { ruProc._recoveryTestHasPageTask(for: $0) } == true)

            // 2. The reachability claim this item rests on, pinned rather than asserted in prose. It has TWO
            //    independent legs and both are checked here: a segment in this state renders as `.processing`,
            //    for which the shared per-item menu offers NOTHING; and it is absent from `failedGroupIds`,
            //    which is the entire input of the bulk "Retry N failed" button. If a future edit reaches this
            //    loop through either one, the matching check fails — and whoever sees it should re-read the
            //    comment on `retryFailed`'s cancel loop, which is what keeps that edit safe. Scope of the
            //    second leg, since it asserts an absence: it pins that a group in THIS state is not in the
            //    bulk retry's input. It cannot see the lifecycle path of `W3.cap-r3-fu5` — a group that fails,
            //    is later filed by the rotation review, and used to stay in `failedGroupIds` after losing its
            //    late-page cover — because nothing in this session ever fails. Test 19 drives that one.
            //    `finalizing: false` below is on purpose: this leg is about the STATE offering nothing, so it
            //    must not be able to pass because of `W3.cap-r3-fu7`'s separate mid-regeneration gate, which
            //    Test 21 drives.
            let midOCR = ruProc.statuses.first { $0.id == "U1" }
            let midOCRActions = midOCR.map {
                SegmentItem.actions(for: SegmentItem.state(for: $0), finalizing: false)
            }
            check("no retry is offered for a segment mid-OCR — the reason the drop-without-cancel was latent",
                  midOCR?.phase == .ocr && midOCRActions?.isEmpty == true)
            check("...and the bulk retry cannot reach it either: a mid-OCR group is in no failed set",
                  !ruProc.failedGroupIds.contains("U1") && !ruProc.failedGroupIds.contains("U2"))

            // 3. THE FIX. The retry replaces every one of this group's entries, so the calls it drops can
            //    never be read again — they have to be cancelled on the way out.
            ruProc.retryFailed(groupIds: ["U1"])
            check("a retry CANCELS the in-flight calls it is dropping",
                  oldT1?.isCancelled == true && oldT2?.isCancelled == true)

            // 4. Scoped to the group being retried. A fix that cancelled `pageTasks.values` wholesale would
            //    silently kill the calls of every other segment the operator is still capturing.
            check("...and leaves another group's in-flight call running and reachable",
                  other.map { ruTask($0)?.isCancelled == false
                              && ruProc._recoveryTestHasPageTask(for: $0) } == true)

            // 5. The retry still does its own job — cancelling must not eat the replacements. Its whole point
            //    is to buy this group's OCR again, so each page gets a fresh, uncancelled call under the same
            //    key, and it is not the one just cancelled.
            let newT1 = u1.flatMap(ruTask), newT2 = u2.flatMap(ruTask)
            check("...while re-ingesting the group: a fresh call per page, neither of them the cancelled one",
                  paidStarts() == 5 && newT1 != nil && newT2 != nil
                      && newT1?.isCancelled == false && newT2?.isCancelled == false
                      && newT1 != oldT1 && newT2 != oldT2)

            // 6. The retry's own product, measured on the OUTPUT: the re-finalize it triggers reads the NEW
            //    calls, so the segment stages with both pages of text — the mechanism must not cost the retry
            //    the thing it exists to do. Stated honestly, this check is a guard against over-reach rather
            //    than a second catcher of the fix: the $0 stub is cancellation-blind BY DESIGN (it has to park
            //    on the gate for the checks above, and a cancelled stub still returns its text), so an
            //    after-the-re-ingest cancel does not show up here — check 5 is what kills that one. The drop
            //    is what this check is aimed at (cancel-without-`= nil` leaves the old entry in place, the
            //    started-once guard refuses the re-ingest, and the group can never stage again) — but M4 is
            //    also the mutant that stops the run before this line reports, so in practice check 5 catches
            //    that one too. No measured mutant reddens this check alone.
            let restaged = await ruSettle { ruProc.staged.contains { $0.groupId == "U1" } }
            check("...and the retried segment stages with both pages of the OCR it just paid for",
                  restaged && textPages("U1") == 2)

            ruGate.open()   // release the three parked pages; nothing after this reads them
            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            LiveCaptureProcessor._recoveryTestOCRGate = nil
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
            // Same isolation as Tests 16–18, and load-bearing for the same reason: `CaptureSession.init`
            // adopts the newest backup session that still holds unprocessed photos, so inherited photos would
            // put pages in this session it never ingested.
            if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
               !testRoot.isEmpty {
                let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                           includingPropertiesForKeys: nil)) ?? []
                for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                    try? fm.removeItem(at: e)
                }
            }
            let fvOut = tmp.appendingPathComponent("fu5out", isDirectory: true)
            let fvStaging = tmp.appendingPathComponent("APStaging-fu5-\(String(UUID().uuidString.prefix(8)))",
                                                       isDirectory: true)
            try? fm.createDirectory(at: fvStaging, withIntermediateDirectories: true)
            let fvSession = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            fvSession._recoveryTestBeginLive(
                config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    // `.human` — a document only reaches the LLM in `.automatic`, so both finalizes below run
                    // for real, for $0, with no network.
                    taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                    outputDirectory: fvOut, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1),
                stagingDir: fvStaging)
            let fvProc = fvSession.liveProcessor
            func fvSettle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func fvChmod(_ mode: Int) {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: fvStaging.path)
            }

            // 1. PREMISE. Fail the segment the way the item describes — a TRANSIENT write error, not a lost
            //    source. `writeSegmentFiles` records only a PDF it can prove is on disk, so a staging dir it
            //    cannot write into yields none at all → `.noOutput` → `markFailed`. The source photo lives in
            //    the backup root and is untouched, which is exactly why step 3's regeneration can succeed
            //    where this write did not. The subset is asserted HERE too: at the moment of failure the
            //    group is in both sets, which is the state the rest of the section watches.
            //    TWO groups fail, and only V1 is rotated below — so V2 is a segment that is STILL genuinely
            //    failed and unfiled when the batch files V1. It is what makes the scoping load-bearing: a
            //    `releaseFinalizedGroup` that cleared the failed set wholesale would take the operator's one
            //    real retry with it, and nothing else in this driver would notice.
            fvChmod(0o555)
            for gid in ["V1", "V2"] {
                fvSession.ingest(jpeg: Data("synthetic page bytes".utf8), groupId: gid, seq: 1,
                                 type: .document, priority: nil, year: nil, month: nil, deviceName: "TestPhone")
                fvProc.segmentResolved(groupId: gid)
            }
            let fvFailed = await fvSettle {
                fvProc.failedGroupIds.contains("V1") && fvProc.failedGroupIds.contains("V2")
            }
            fvChmod(0o755)   // the error was transient; from here the dir is writable again
            check("a transient staging write error fails both segments with NO output, inside both sets",
                  fvFailed && fvProc.statuses.first { $0.id == "V1" }?.phase == .failed
                      && fvProc.isFinalized("V1") && fvProc.isFinalized("V2")
                      && fvProc.staged.first { $0.groupId == "V1" }?.pdfURLs.isEmpty == true
                      && fvProc.staged.first { $0.groupId == "V2" }?.pdfURLs.isEmpty == true)

            // 2. PREMISE. A failed segment's pages still reach the end-of-session rotation review, because
            //    `finishSession` enumerates `retained.values` and nothing filters by label. Driven through the
            //    real Finish rather than by poking `rotationReviewPages`: the "Review rotation" default is the
            //    only input, and it is set and restored around the single SYNCHRONOUS call that reads it
            //    (`finishSession` is not `async`, and there is no `await` in this block), so this never
            //    leaves the operator's own toggle flipped. Two residuals an adversarial pass named, both
            //    accepted: a crash or SIGTERM inside that window would leave it ON — this is the driver's
            //    only isolation not done by env var — and `object(forKey:)` reads through the domain search
            //    list, so a value inherited from a global domain would be written INTO the app domain by the
            //    restore. Negligible for an app-private key, but it is not nothing.
            let priorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
            UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)
            fvProc.finishSession()
            if let priorReview {
                UserDefaults.standard.set(priorReview, forKey: DefaultsKeys.reviewRotation)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
            }
            check("a FAILED segment's pages still enter the end-of-session rotation review",
                  fvProc.showRotationReview
                      && fvProc.rotationReviewPages.contains { $0.groupId == "V1" })

            // 3. PREMISE. The operator corrects a rotation, so the review regenerates the segment — and this
            //    time the write lands. The staged record is replaced wholesale, so a group that is still
            //    counted failed is now one `executePlans` will file. Without this the finalize below would
            //    file nothing and check 5 would pass for the wrong reason.
            for i in fvProc.rotationReviewPages.indices where fvProc.rotationReviewPages[i].groupId == "V1" {
                fvProc.rotationReviewPages[i].rotationDegrees = 90
            }
            fvProc.applyRotationReviewAndFinalize()
            let fvRegen = await fvSettle {
                !fvProc.isFinalizing && fvProc.staged.first { $0.groupId == "V1" }?.pdfURLs.isEmpty == false
            }
            let fvRecord = fvProc.staged.first { $0.groupId == "V1" }
            check("the rotation review regenerates that record into a FILABLE one — a PDF proven on disk",
                  fvRegen && fvRecord?.pagesComplete != false
                      && fvRecord?.pdfURLs.first.map { fm.fileExists(atPath: $0.path) } == true)

            // 4. THE FIX (W3.cap-r3-fu6) — and it RECONCILES the label while doing it. This check is the one
            //    fu5 predicted would flip: it used to PIN the stale `.failed`, because fu5 needed a filable
            //    group that was still counted failed and this was how that state arose. fu6 closed it at
            //    source — `applyRotationReviewAndFinalize` now re-derives the label from the record it just
            //    wrote (`labelStagedRecord`), so the "1 segment(s) failed to process and are NOT filed —
            //    Retry them before finalizing" warning no longer names a segment that is fine, and the
            //    operator can no longer be talked into a `retryFailed` that deletes the freshly regenerated
            //    output and re-buys its OCR.
            //    `.succeededPlaceholderImage`, not `.staged`, and that is not incidental: the synthetic bytes
            //    are not a decodable image, so `generate` embeds the deliberate placeholder page (check 7
            //    below turns on the same fact). Asserted as the SPECIFIC label the taxonomy owes this record
            //    rather than "not failed", so a fix that reconciled the sets by blanket-clearing them would
            //    still be caught — as would one that forgot the reason line, which is what the row shows.
            //    The `== ["V2"]` equality is the over-reach half: V2 is genuinely failed and was NOT
            //    regenerated, so a relabel that cleared the whole set would take the operator's one real
            //    retry with it.
            check("...and RECONCILES the label with it — a regenerated record is no longer counted failed",
                  !fvProc.failedGroupIds.contains("V1")
                      && fvProc.failedGroupIds == ["V2"]
                      && fvProc.statuses.first { $0.id == "V1" }?.phase == .succeededPlaceholderImage
                      && fvProc.statuses.first { $0.id == "V1" }?.failureKind == nil)

            // 5. THE FIX (fu5). Finish files it, and a filed group leaves BOTH sets together. Since fu6 the
            //    group has ALREADY left the failed set at check 4, so what follows now confirms the pairing
            //    holds rather than catching it failing — see the M1 re-measurement in the header. Kept
            //    verbatim on purpose: it is still the only place in this driver that drives a real `finalize`
            //    over a segment that reached it through the rotation review.
            fvProc.finalize([LiveCaptureProcessor.CollectionDraft(
                id: fvRecord?.collectionKey ?? "__unfiled__", finalName: fvOut.lastPathComponent,
                existingFolders: [], suggestedFolders: [], chosenExisting: fvOut,
                segmentCount: 1, photoCount: 1)])
            let fvFiled = await fvSettle {
                !fvProc.isFinalizing && !fvProc.staged.contains { $0.groupId == "V1" }
            }
            // Deliberately worded unlike Test 17's near-identical premise: the two shared a name while the
            // mutants below were being read, and a FAIL line is all a reader gets.
            check("the REGENERATED document really filed, so what follows is its post-filing state",
                  fvFiled && ((try? fm.contentsOfDirectory(at: fvOut, includingPropertiesForKeys: nil)) ?? [])
                      .contains { $0.pathExtension == "pdf" })
            check("a FILED group leaves the failed set with the finalized one — the subset survives the file",
                  !fvProc.failedGroupIds.contains("V1") && !fvProc.isFinalized("V1"))
            // WHICH shape this section builds, pinned because the cost of the leftover entry depends on it
            // and an adversarial pass corrected the fix's first claim about that. The synthetic bytes are
            // not a decodable image, so `generate` embeds the deliberate PLACEHOLDER page and finalize
            // WITHHOLDS V1's source — which keeps the group alive in `session.groups`. That is the minority
            // case where a leftover failed entry is EXPENSIVE: `retryFailed` finds the group, re-ingests it
            // and buys its OCR again. In the ordinary filed-with-a-real-scan case the source is retired,
            // `groups` (derived from `photos`) no longer has it, and the phantom button self-clears at
            // `retryFailed`'s `else` guard — confusing, but free. Both are wrong; only this one costs money.
            check("...and this is the placeholder shape, where that entry was expensive and not cosmetic",
                  fvSession.groups.contains { $0.id == "V1" }
                      && fvSession.photos.contains { $0.groupId == "V1" })
            // The operator-visible shape of the same thing, and the pairing that made it confusing rather
            // than merely wrong: `failedGroupIds.count` IS the "Retry N failed" button, and the row that
            // would have explained the count is dropped by the same finalize. Asserted as an EQUALITY
            // against the one segment that genuinely failed, so it catches both directions — the filed
            // group left in (the bug) and the unfiled one swept out with it (over-reach).
            check("...so the button counts exactly the segment that is still failed, and it has a row",
                  fvProc.failedGroupIds == ["V2"]
                      && !fvProc.statuses.contains { $0.id == "V1" }
                      && fvProc.statuses.contains { $0.id == "V2" && $0.phase == .failed })

            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
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
            if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
               !testRoot.isEmpty {
                let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                           includingPropertiesForKeys: nil)) ?? []
                for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                    try? fm.removeItem(at: e)
                }
            }
            let bwOut = tmp.appendingPathComponent("fu6out", isDirectory: true)
            let bwStaging = tmp.appendingPathComponent("APStaging-fu6-\(String(UUID().uuidString.prefix(8)))",
                                                       isDirectory: true)
            try? fm.createDirectory(at: bwStaging, withIntermediateDirectories: true)
            let bwSession = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            bwSession._recoveryTestBeginLive(
                config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    // `.human` again — no document reaches the LLM, so this runs for real, for $0, no network.
                    taggingMode: .human, rotationMode: .off,
                    // Load-bearing, not incidental: see the merge note above.
                    mergeDocuments: true,
                    outputDirectory: bwOut, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1),
                stagingDir: bwStaging)
            let bwProc = bwSession.liveProcessor
            func bwSettle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func bwChmod(_ mode: Int) {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: bwStaging.path)
            }
            // A REAL, decodable JPEG this time (Test 19 uses undecodable bytes on purpose). Two reasons: the
            // segment must reach the plain `.staged` label the item names, which a placeholder page would
            // pre-empt with `.succeededPlaceholderImage`; and the merge below only happens if both pages
            // actually produce a PDF.
            let bwBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0)
            let bwJPEG = bwBitmap?.representation(using: .jpeg, properties: [:]) ?? Data()

            // 1. PREMISE. A two-page document stages CLEANLY — the success label this section watches decay.
            for seq in [1, 2] {
                bwSession.ingest(jpeg: bwJPEG, groupId: "B1", seq: seq,
                                 type: .document, priority: nil, year: nil, month: nil, deviceName: "TestPhone")
            }
            bwProc.segmentResolved(groupId: "B1")
            let bwStagedOK = await bwSettle { bwProc.statuses.first { $0.id == "B1" }?.phase == .staged }
            let bwFirst = bwProc.staged.first { $0.groupId == "B1" }
            check("a two-page document stages cleanly as ONE merged PDF, in no failed set",
                  bwStagedOK && bwProc.failedGroupIds.isEmpty
                      && bwFirst?.pagesComplete != false && bwFirst?.pdfURLs.count == 1
                      && bwFirst?.pdfURLs.first.map { fm.fileExists(atPath: $0.path) } == true)

            // 2. PREMISE, and the one that stops this section being vacuous: the merge deleted the per-page
            //    PDFs, so the paths the regeneration will write to are ABSENT. Without this a failed write
            //    would be masked by the previous run's file and check 4 would pass for no reason.
            let bwSources = bwSession.photos.filter { $0.groupId == "B1" }.map(\.url)
            let bwPerPage = bwSources.map {
                bwStaging.appendingPathComponent($0.deletingPathExtension().lastPathComponent + ".pdf")
            }
            check("...and the merge left its per-page paths EMPTY, so the regeneration writes fresh",
                  bwSources.count == 2 && bwPerPage.allSatisfy { !fm.fileExists(atPath: $0.path) })

            // 3. PREMISE. The staged segment's pages reach the rotation review (as in Test 19, driven through
            //    the real Finish, with the operator's own toggle restored around the one synchronous call).
            bwChmod(0o555)   // from here the write cannot land — the transient failure this half needs
            let bwPriorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
            UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)
            bwProc.finishSession()
            if let bwPriorReview {
                UserDefaults.standard.set(bwPriorReview, forKey: DefaultsKeys.reviewRotation)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
            }
            check("a STAGED segment's pages enter the end-of-session rotation review",
                  bwProc.showRotationReview
                      && bwProc.rotationReviewPages.filter { $0.groupId == "B1" }.count == 2)

            // 4. PREMISE. The operator straightens a page; the regeneration runs and produces nothing.
            for i in bwProc.rotationReviewPages.indices
            where bwProc.rotationReviewPages[i].groupId == "B1" && bwProc.rotationReviewPages[i].pageIndex == 0 {
                bwProc.rotationReviewPages[i].rotationDegrees = 90
            }
            bwProc.applyRotationReviewAndFinalize()
            let bwRegen = await bwSettle { !bwProc.isFinalizing && bwProc.showFinalizeSheet }
            bwChmod(0o755)   // restore before the finalize + the temp-dir cleanup at the end of the run
            let bwRecord = bwProc.staged.first { $0.groupId == "B1" }
            check("the regeneration produced NOTHING — the record that replaced it holds no PDF at all",
                  bwRegen && bwRecord?.pdfURLs.isEmpty == true && bwRecord?.pagesComplete == false)

            // 5. THE FIX. The label went down with the record. Before this, the segment kept "Staged" over an
            //    empty record and the operator was told nothing at all; now it is `.failed` with a reason and
            //    in the retry set, which is the only way the situation is recoverable — the sources are still
            //    in the backup folder and a retry regenerates them. Asserted as an equality so a fix that
            //    marked everything failed would not pass either.
            check("...and the label went down with it: FAILED, with a reason, and offered for retry",
                  bwProc.failedGroupIds == ["B1"]
                      && bwProc.statuses.first { $0.id == "B1" }?.phase == .failed
                      && bwProc.statuses.first { $0.id == "B1" }?.failureKind == .noOutput)

            // 6. …and the outcome that was silent is now stated. `executePlans` declines to file the empty
            //    record either way — that gate is unchanged and is not what this item touched — but the
            //    segment now survives finalize with a row and a count against it, instead of vanishing from
            //    the collection with the sheet reporting nothing wrong.
            bwProc.finalize([LiveCaptureProcessor.CollectionDraft(
                id: bwRecord?.collectionKey ?? "__unfiled__", finalName: bwOut.lastPathComponent,
                existingFolders: [], suggestedFolders: [], chosenExisting: bwOut,
                segmentCount: 1, photoCount: 2)])
            let bwFinalized = await bwSettle { !bwProc.isFinalizing && !bwProc.showFinalizeSheet }
            check("finalize files nothing and SAYS so — the segment keeps its row, its count and its sources",
                  bwFinalized
                      && !((try? fm.contentsOfDirectory(at: bwOut, includingPropertiesForKeys: nil)) ?? [])
                          .contains { $0.pathExtension == "pdf" }
                      && bwProc.staged.contains { $0.groupId == "B1" }
                      && bwProc.failedGroupIds == ["B1"]
                      && bwProc.statuses.contains { $0.id == "B1" && $0.phase == .failed }
                      && bwSources.allSatisfy { fm.fileExists(atPath: $0.path) })

            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
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
        // await between, is genuinely inside the window with the write genuinely running on another thread.
        // Check 3 asserts that state rather than trusting it.
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
        //      → 3 RED: checks 4, 5 and 8. The retry buys 2 more paid calls and takes the segment's staged
        //      record, its `finalizedGroups` entry and its output files with it, mid-write. Check 8 goes down
        //      as a consequence rather than on its own account — the window's retries already spent the calls
        //      it counts — which is worth knowing when reading a future regression: 4 and 5 are the ones that
        //      name the defect. This is the mutant the section exists for.
        //   P2 the guard weakened to the bulk-only shape — `!(isFinalizing && groupIds == nil)`, refusing only
        //      the "Retry N failed" button and letting every single-group call through
        //      → 3 RED: the same three. Pins that the PER-ITEM entry is gated too, which is the item's open
        //      question answered as a measurement rather than a preference.
        //   P3 `SegmentItem.gate` returning its input unchanged (the UI half reverted)
        //      → 1 RED, check 7. The menu offers a retry that `retryFailed` would refuse.
        //   P4 `gate` filtering `.retry` only, leaving `.retryWithModel`/`.changeRotation`
        //      → 1 RED, check 7. Both of those reach `retryFailed` through the model sheet, so a gate that
        //      stops at the plain retry stops at the cheapest third of the money path.
        //   P5 the guard WIDENED to `requestFinish`'s triple — also refusing while `showFinalizeSheet` /
        //      `showRotationReview` is up
        //      → 1 RED, check 8. Recorded because it is the mutant that shows the section constrains the
        //      guard's WIDTH and not merely its presence: `beginFinalize` has raised the collection sheet by
        //      the time check 8 runs, so a widened guard turns the intended window into a ban and is caught.
        //      The widening was considered and declined on its own merits (see `retryFailed`'s comment and
        //      `W3.cap-r3-fu9`); this is what makes that a tested decision.
        // Checks 1–3 and 6 are premises, not catchers. ---
        if isolatedBackup {
            if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
               !testRoot.isEmpty {
                let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                           includingPropertiesForKeys: nil)) ?? []
                for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                    try? fm.removeItem(at: e)
                }
            }
            let rfOut = tmp.appendingPathComponent("fu7out", isDirectory: true)
            let rfStaging = tmp.appendingPathComponent("APStaging-fu7-\(String(UUID().uuidString.prefix(8)))",
                                                      isDirectory: true)
            try? fm.createDirectory(at: rfStaging, withIntermediateDirectories: true)
            let rfSession = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            rfSession._recoveryTestBeginLive(
                config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    // `.human` — no document reaches the LLM, so this runs for real, for $0, no network.
                    taggingMode: .human, rotationMode: .off,
                    // No merge here (unlike Test 20): this section wants the regeneration to SUCCEED, so the
                    // per-page PDFs it rewrites may stay exactly where the first write put them.
                    mergeDocuments: false,
                    outputDirectory: rfOut, contextCharCount: 0, sendPreviousImage: false,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                    textColumns: 1),
                stagingDir: rfStaging)
            let rfProc = rfSession.liveProcessor
            func rfSettle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
            // A real, decodable JPEG: the segment has to reach the plain `.staged` label (a placeholder page
            // would make it `.succeededPlaceholderImage`) and the regeneration has to be able to rewrite it.
            let rfBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0)
            let rfJPEG = rfBitmap?.representation(using: .jpeg, properties: [:]) ?? Data()

            // 1. PREMISE. A two-page document stages cleanly, having bought exactly one call per page.
            for seq in [1, 2] {
                rfSession.ingest(jpeg: rfJPEG, groupId: "F1", seq: seq,
                                 type: .document, priority: nil, year: nil, month: nil, deviceName: "TestPhone")
            }
            rfProc.segmentResolved(groupId: "F1")
            let rfStagedOK = await rfSettle { rfProc.statuses.first { $0.id == "F1" }?.phase == .staged }
            let rfPaidAfterStage = paidStarts()
            let rfSources = rfSession.photos.filter { $0.groupId == "F1" }.map(\.url)
            check("a two-page document stages cleanly, having bought exactly one paid call per page",
                  rfStagedOK && rfPaidAfterStage == 2 && rfSources.count == 2
                      && rfProc.failedGroupIds.isEmpty && rfProc.isFinalized("F1")
                      && rfProc.staged.first { $0.groupId == "F1" }?.pdfURLs.isEmpty == false)

            // 2. PREMISE. Its pages reach the rotation review, through the real Finish, with the operator's
            //    own "Review rotation" preference restored around the one synchronous call that reads it.
            let rfPriorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
            UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)
            rfProc.finishSession()
            if let rfPriorReview {
                UserDefaults.standard.set(rfPriorReview, forKey: DefaultsKeys.reviewRotation)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
            }
            check("a STAGED segment's pages enter the end-of-session rotation review",
                  rfProc.showRotationReview
                      && rfProc.rotationReviewPages.filter { $0.groupId == "F1" }.count == 2)

            // 3. PREMISE, and the one that makes the rest non-vacuous: the operator straightens a page, and
            //    the regeneration is IN FLIGHT — `isFinalizing`, no sheet over the panel (so the retry
            //    affordances are on screen), and the record + its file still the pre-write ones. Everything
            //    from here to check 5 runs on this same MainActor turn, so the detached write cannot land in
            //    the middle of it.
            for i in rfProc.rotationReviewPages.indices
            where rfProc.rotationReviewPages[i].groupId == "F1" && rfProc.rotationReviewPages[i].pageIndex == 0 {
                rfProc.rotationReviewPages[i].rotationDegrees = 90
            }
            let rfPDFsBefore = rfProc.staged.first { $0.groupId == "F1" }?.pdfURLs ?? []
            rfProc.applyRotationReviewAndFinalize()
            check("the regeneration is in flight, with the panel on screen and nothing over it",
                  rfProc.isFinalizing && !rfProc.showFinalizeSheet && !rfProc.showRotationReview
                      && !rfPDFsBefore.isEmpty && rfPDFsBefore.allSatisfy { fm.fileExists(atPath: $0.path) })

            // 4. THE FIX, money half. Both retry entries are refused: the per-item one, and the one the model
            //    sheet defers (`onApply` fires whenever the operator gets round to it, so no enabled-ness
            //    computed when the button was drawn can speak for this moment — which is why the refusal has
            //    to live in `retryFailed` and not only in the view).
            rfProc.retryFailed(groupIds: ["F1"])
            rfProc.retryFailed(groupIds: ["F1"], override: LiveCaptureProcessor.OCROverride(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "", rotation: 180))
            check("a retry mid-regeneration buys NO second OCR — neither entry, override or not",
                  paidStarts() == rfPaidAfterStage)

            // 5. THE FIX, state half. Nothing the retry would have torn down moved: the staged record, the
            //    `finalizedGroups` entry the late-page branch depends on, `retained`, and the output files the
            //    regeneration is at this instant writing over.
            check("...and it tears nothing down under the write: record, finalized entry and files all intact",
                  rfProc.staged.contains { $0.groupId == "F1" }
                      && rfProc.isFinalized("F1")
                      && rfProc.retainedText(for: "F1") != nil
                      && rfPDFsBefore.allSatisfy { fm.fileExists(atPath: $0.path) })

            // 6. PREMISE. The regeneration then lands normally — the refusal cost the finish nothing. The
            //    segment is still filable, still unfailed, and both sources are still in the backup folder.
            let rfRegen = await rfSettle { !rfProc.isFinalizing && rfProc.showFinalizeSheet }
            let rfRecord = rfProc.staged.first { $0.groupId == "F1" }
            check("the regeneration lands intact and the segment is still filable",
                  rfRegen && rfProc.failedGroupIds.isEmpty
                      && rfRecord?.pagesComplete != false
                      && rfRecord?.pdfURLs.isEmpty == false
                      && rfRecord?.pdfURLs.allSatisfy { fm.fileExists(atPath: $0.path) } == true
                      && rfSources.allSatisfy { fm.fileExists(atPath: $0.path) })

            // 7. THE FIX, UI half — the per-item menu, answering the item's open question with a measurement
            //    rather than a decision note. Every state that offers a retry withholds the whole retry family
            //    while finalizing and keeps the two read-only actions; and the SAME states still offer them
            //    when not, so a gate that withheld unconditionally fails here too.
            let rfGatedStates: [ItemState] = [.failed(.noOutput), .succeededNoText, .succeededPlaceholderImage]
            let rfWithheld = rfGatedStates.allSatisfy { st in
                let gated = SegmentItem.actions(for: st, finalizing: true)
                let ungated = SegmentItem.actions(for: st, finalizing: false)
                return !gated.contains(.retry) && !gated.contains(.retryWithModel)
                    && !gated.contains(.changeRotation)
                    && gated.contains(.viewText) && gated.contains(.revealFiles)
                    && ungated.contains(.retry) && ungated.contains(.retryWithModel)
            }
            check("the per-item menu withholds the retry family mid-regeneration, and only then",
                  rfWithheld
                      && SegmentItem.actions(for: .succeeded, finalizing: true) == [.viewText, .revealFiles])

            // 8. …and the refusal is a WINDOW, not a ban. Once the regeneration is done, the same per-item
            //    retry works again and buys the segment's pages back — the recovery affordance the operator
            //    depends on is unchanged outside the race. Deliberately last: it re-processes the segment.
            //    This also measures the guard's WIDTH: `beginFinalize` has raised the collection sheet by now,
            //    so a guard widened to `!showFinalizeSheet` (mutant P5) would fail here.
            rfProc.retryFailed(groupIds: ["F1"])
            let rfReStaged = await rfSettle { rfProc.statuses.first { $0.id == "F1" }?.phase == .staged }
            check("after the window closes the retry works again — a window, not a ban",
                  rfReStaged && paidStarts() == rfPaidAfterStage + 2
                      && rfProc.staged.contains { $0.groupId == "F1" })

            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
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
