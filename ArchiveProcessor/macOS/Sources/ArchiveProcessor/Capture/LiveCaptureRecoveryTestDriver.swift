import Foundation
import AppKit
import PDFKit

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
///
/// Writes a PASS/FAIL report to `LIVECAPTURE_RECOVERYTEST_OUT` (or a temp file) + NSLog. Test scaffolding.
@MainActor
enum LiveCaptureRecoveryTestDriver {
    private static var didRun = false

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

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["LIVECAPTURE_RECOVERYTEST_OUT"]
            ?? fm.temporaryDirectory.appendingPathComponent("APRecoveryTest-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: tmp)
        NSLog("RECOVERYTEST DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}
