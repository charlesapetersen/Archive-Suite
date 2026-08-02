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

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["LIVECAPTURE_RECOVERYTEST_OUT"]
            ?? fm.temporaryDirectory.appendingPathComponent("APRecoveryTest-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: tmp)
        NSLog("RECOVERYTEST DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}
