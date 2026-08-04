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

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["LIVECAPTURE_RECOVERYTEST_OUT"]
            ?? fm.temporaryDirectory.appendingPathComponent("APRecoveryTest-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: tmp)
        NSLog("RECOVERYTEST DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}
