#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import ArchiveCore
import PDFKit

/// Headless, $0 self-test of `CollectionSegmenter.organizeOutput`, gated by `COLLECTIONORGANIZE_TEST=1`
/// (inert in normal use). No OCR, no network, no cost, no GUI — synthetic files in a temp dir.
///
/// Proves KNOWN_ISSUES #2 (B3) is fixed: with dual (image) output + document merge + collection
/// organization, a merged multi-page document's per-page exported images (`page1.jpg`, `page2.jpg`, …)
/// are NUMBERED and MOVED into the collection folder (mirroring the Live Capture merged branch) instead
/// of being left loose/unrenamed in the output root, and the merged PDF takes the first page's number.
/// Also guards the regression surfaces: non-merged dual output still pairs image↔PDF by base name, the
/// no-export path is untouched, and no source file is ever overwritten or deleted.
///
/// Writes a PASS/FAIL report to `COLLECTIONORGANIZE_TEST_OUT` (or a temp file) + NSLog. Test scaffolding.
@MainActor
enum CollectionOrganizeTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["COLLECTIONORGANIZE_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("ORGANIZETEST \(ok ? "PASS" : "FAIL"): \(name)")
        }
        func writeFile(_ url: URL, _ s: String) { try? Data(s.utf8).write(to: url) }

        let seg = CollectionSegmenter()

        // Confirm the organizer guards destinations even when called without the review sheet.
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("APOrgTest-boundary-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let out = root.appendingPathComponent("output")
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let pdf = out.appendingPathComponent("working.pdf")
            let pdfBytes = Data("PDF".utf8)
            try pdfBytes.write(to: pdf)
            let json = out.appendingPathComponent("working.json")
            let jsonBytes = Data("{}".utf8)
            try jsonBytes.write(to: json)
            let redirected = out.appendingPathComponent("Redirected")
            let safe = out.appendingPathComponent("Safe")
            try fm.createSymbolicLink(at: redirected, withDestinationURL: root)
            try fm.createDirectory(at: safe, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: safe.appendingPathComponent("JSON Output"), withDestinationURL: root)

            for name in ["", " ", ".", "..", "a/b", "Redirected", "Safe"] {
                let collection = CollectionSegment(collectionName: name, fileURLs: [pdf])
                for planning in [false, true] {
                    var planned = false
                    let recordPlan: ((URL, [OutputFileSafety.ArtifactMove]) -> Void)? =
                        planning ? { _, _ in planned = true } : nil
                    do {
                        try seg.organizeOutput(collections: [collection], outputDirectory: out,
                                               outputURLMap: [pdf: pdf], moveSiblingImages: false,
                                               planMoves: recordPlan)
                        check("filing guard: rejects invalid or redirected destination '\(name)' (planning=\(planning))", false)
                    } catch {
                        check("filing guard: retains working artifacts for '\(name)' (planning=\(planning))",
                              !planned && (try? Data(contentsOf: pdf)) == pdfBytes
                                  && (try? Data(contentsOf: json)) == jsonBytes
                                  && (try? fm.contentsOfDirectory(atPath: root.path)) == ["output"])
                    }
                }
            }
        } catch {
            check("filing guard: scratch setup failed: \(error)", false)
        }

        // ============================================================================================
        // Case 1 — THE BUG: merged 2-page document + dual output. Per-page images page1.jpg/page2.jpg
        // exist; merge collapsed page1.pdf+page2.pdf into page1_merged.pdf and repointed BOTH source URLs
        // at it. Expect: both images filed + numbered in the folder, merged PDF at 000001, output root
        // left with NO loose page images.
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-merged-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let src1 = out.appendingPathComponent("page1.jpg")   // stand-in for source URLs (any URL works as a key)
            let src2 = out.appendingPathComponent("page2.jpg")
            let img1 = out.appendingPathComponent("page1.jpg")   // exported per-page images (pre-merge naming)
            let img2 = out.appendingPathComponent("page2.jpg")
            let merged = out.appendingPathComponent("page1_merged.pdf")
            writeFile(img1, "img1"); writeFile(img2, "img2"); writeFile(merged, "MERGEDPDF")
            writeFile(out.appendingPathComponent("page1_merged.json"), "{}")

            let coll = CollectionSegment(collectionName: "Test Coll", fileURLs: [src1, src2])
            do {
                try seg.organizeOutput(
                    collections: [coll],
                    outputDirectory: out,
                    outputURLMap: [src1: merged, src2: merged],
                    moveSiblingImages: true,
                    exportedImageMap: [src1: img1, src2: img2])
            } catch { check("merged: organizeOutput threw \(error)", false) }

            let folder = out.appendingPathComponent("Test Coll")
            let jpg1 = folder.appendingPathComponent("000001 Test Coll.jpg")
            let jpg2 = folder.appendingPathComponent("000002 Test Coll.jpg")
            let pdf = folder.appendingPathComponent("000001 Test Coll.pdf")
            let json = folder.appendingPathComponent("JSON Output/000001 Test Coll.json")
            check("merged: page-1 image filed as 000001 (numbered, in collection folder)", fm.fileExists(atPath: jpg1.path))
            check("merged: page-2 image filed as 000002 (numbered, in collection folder)", fm.fileExists(atPath: jpg2.path))
            check("merged: merged PDF filed at the first image's number (000001)", fm.fileExists(atPath: pdf.path))
            check("merged: JSON sidecar filed", fm.fileExists(atPath: json.path))
            // The bug's signature: page images left loose in the output ROOT. Must be gone (moved).
            check("merged: NO loose page image left in the output root", !fm.fileExists(atPath: img1.path) && !fm.fileExists(atPath: img2.path))
            check("merged: merged PDF no longer loose in the output root", !fm.fileExists(atPath: merged.path))
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // Case 5 — safety: a JSON-only collision is invisible to highestLeadingNumber (which scans the
        // collection root). It must advance the whole artifact set instead of deleting the existing JSON.
        // The exported image uses a collision-renamed source path to prove exportedImageMap is authoritative.
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-jsoncollision-\(UUID().uuidString)", isDirectory: true)
            let folder = out.appendingPathComponent("JC")
            let jsonFolder = folder.appendingPathComponent("JSON Output")
            try? fm.createDirectory(at: jsonFolder, withIntermediateDirectories: true)
            let existingJSON = jsonFolder.appendingPathComponent("000001 JC.json")
            writeFile(existingJSON, "KEEP")
            let source = out.appendingPathComponent("source.jpg")
            let pdf = out.appendingPathComponent("source.pdf")
            let json = out.appendingPathComponent("source.json")
            let collisionRenamedImage = out.appendingPathComponent("source (2).jpg")
            writeFile(pdf, "PDF"); writeFile(json, "NEWJSON"); writeFile(collisionRenamedImage, "IMAGE")
            let coll = CollectionSegment(collectionName: "JC", fileURLs: [source])
            do {
                try seg.organizeOutput(
                    collections: [coll], outputDirectory: out,
                    outputURLMap: [source: pdf], moveSiblingImages: true,
                    exportedImageMap: [source: collisionRenamedImage])
            } catch { check("JSON collision: organizeOutput threw \(error)", false) }
            let preserved = (try? String(contentsOf: existingJSON, encoding: .utf8)) == "KEEP"
            check("JSON collision: existing 000001 sidecar preserved", preserved)
            check("JSON collision: new PDF/JSON/image advanced together to 000002",
                  fm.fileExists(atPath: folder.appendingPathComponent("000002 JC.pdf").path)
                  && fm.fileExists(atPath: jsonFolder.appendingPathComponent("000002 JC.json").path)
                  && fm.fileExists(atPath: folder.appendingPathComponent("000002 JC.jpg").path))
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // Case 2 — regression: NON-merged dual output (one PDF per page). Each page's image shares its
        // PDF's base name; organizeOutput pairs them by base name and numbers each page independently.
        // Must be unchanged by the fix (merged branch must NOT fire when each source has its own PDF).
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-nonmerged-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let s1 = out.appendingPathComponent("a.src"); let s2 = out.appendingPathComponent("b.src")
            let p1 = out.appendingPathComponent("a.pdf"); let p2 = out.appendingPathComponent("b.pdf")
            let i1 = out.appendingPathComponent("a.jpg"); let i2 = out.appendingPathComponent("b.jpg")
            writeFile(p1, "P1"); writeFile(p2, "P2"); writeFile(i1, "I1"); writeFile(i2, "I2")
            let coll = CollectionSegment(collectionName: "NM", fileURLs: [s1, s2])
            _ = try? seg.organizeOutput(
                collections: [coll], outputDirectory: out,
                outputURLMap: [s1: p1, s2: p2], moveSiblingImages: true,
                exportedImageMap: [s1: i1, s2: i2])   // present but each source has its OWN pdf → sibling-by-name path
            let folder = out.appendingPathComponent("NM")
            let ok = fm.fileExists(atPath: folder.appendingPathComponent("000001 NM.pdf").path)
                && fm.fileExists(atPath: folder.appendingPathComponent("000001 NM.jpg").path)
                && fm.fileExists(atPath: folder.appendingPathComponent("000002 NM.pdf").path)
                && fm.fileExists(atPath: folder.appendingPathComponent("000002 NM.jpg").path)
            check("non-merged dual output: each page filed as its own numbered PDF + image (unchanged)", ok)
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // Case 3 — regression: merged doc but NO export (moveSiblingImages=false). Existing behavior:
        // move the merged PDF once, no image handling. Merged branch must NOT fire.
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-noexport-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let s1 = out.appendingPathComponent("x.src"); let s2 = out.appendingPathComponent("y.src")
            let merged = out.appendingPathComponent("x_merged.pdf"); writeFile(merged, "M")
            let coll = CollectionSegment(collectionName: "NE", fileURLs: [s1, s2])
            _ = try? seg.organizeOutput(
                collections: [coll], outputDirectory: out,
                outputURLMap: [s1: merged, s2: merged], moveSiblingImages: false)
            let folder = out.appendingPathComponent("NE")
            check("no-export merged: merged PDF filed once at 000001 (unchanged)",
                  fm.fileExists(atPath: folder.appendingPathComponent("000001 NE.pdf").path)
                  && !fm.fileExists(atPath: merged.path))
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // Case 4 — safety: never overwrite. Pre-populate the collection folder with an existing file filed
        // under the old five-digit width (00001); the merged run must continue numbering at six digits
        // (000002/000003, W49.proc-six-digit-names) and leave the existing file intact and unrenamed.
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-nooverwrite-\(UUID().uuidString)", isDirectory: true)
            let folder = out.appendingPathComponent("OW")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = folder.appendingPathComponent("00001 OW.pdf"); writeFile(existing, "EXISTING")
            let s1 = out.appendingPathComponent("m1.src"); let s2 = out.appendingPathComponent("m2.src")
            let i1 = out.appendingPathComponent("m1.jpg"); let i2 = out.appendingPathComponent("m2.jpg")
            let merged = out.appendingPathComponent("m1_merged.pdf")
            writeFile(i1, "I1"); writeFile(i2, "I2"); writeFile(merged, "M")
            let coll = CollectionSegment(collectionName: "OW", fileURLs: [s1, s2])
            _ = try? seg.organizeOutput(
                collections: [coll], outputDirectory: out,
                outputURLMap: [s1: merged, s2: merged], moveSiblingImages: true,
                exportedImageMap: [s1: i1, s2: i2])
            let preserved = (try? String(contentsOf: existing, encoding: .utf8)) == "EXISTING"
            let newImg = fm.fileExists(atPath: folder.appendingPathComponent("000002 OW.jpg").path)
                && fm.fileExists(atPath: folder.appendingPathComponent("000003 OW.jpg").path)
            let newPdf = fm.fileExists(atPath: folder.appendingPathComponent("000002 OW.pdf").path)
            check("no-overwrite: existing 00001 file preserved (not overwritten/deleted)", preserved)
            check("no-overwrite: merged run continued numbering at 000002/000003", newImg && newPdf)
            check("no-overwrite: nothing filed at the old width beyond the existing file",
                  !fm.fileExists(atPath: folder.appendingPathComponent("00002 OW.pdf").path))
            try? fm.removeItem(at: out)
        }

        // W49.proc-six-digit-names — the leading number reads both widths, and only those.
        do {
            let cases: [(String, Int?)] = [("00041 A.pdf", 41), ("000042 A.pdf", 42), ("123456 A.jpg", 123456),
                                           ("0042 A.pdf", nil), ("1234567 A.pdf", nil), ("A 00001.pdf", nil),
                                           ("000007-g1.jpg", 7), (".archivesuite", nil)]
            let wrong = cases.filter { CollectionNumbering.leadingNumber(of: $0.0) != $0.1 }.map(\.0)
            check("six digits: leadingNumber reads five- and six-digit names only (wrong: \(wrong))", wrong.isEmpty)
            check("six digits: format pads to six", CollectionNumbering.format(42) == "000042")
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-mixedwidth-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            for name in ["00040 W.pdf", "00041 W.jpg", "000039 W.pdf"] { writeFile(out.appendingPathComponent(name), "x") }
            check("six digits: a mixed folder continues past its highest number (41)",
                  CollectionNumbering.highestLeadingNumber(in: out, fm: fm) == 41)
            try? fm.removeItem(at: out)
        }

        // Merged JSON-only collision: reserve the entire image/PDF/JSON set at the next free range.
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-merged-jsoncollision-\(UUID().uuidString)", isDirectory: true)
            let folder = out.appendingPathComponent("MJ")
            let jsonFolder = folder.appendingPathComponent("JSON Output")
            try? fm.createDirectory(at: jsonFolder, withIntermediateDirectories: true)
            let existingJSON = jsonFolder.appendingPathComponent("000001 MJ.json")
            writeFile(existingJSON, "KEEP")
            let s1 = out.appendingPathComponent("p1.src"); let s2 = out.appendingPathComponent("p2.src")
            let i1 = out.appendingPathComponent("p1.jpg"); let i2 = out.appendingPathComponent("p2.jpg")
            let merged = out.appendingPathComponent("p1_merged.pdf")
            let mergedJSON = out.appendingPathComponent("p1_merged.json")
            writeFile(i1, "I1"); writeFile(i2, "I2"); writeFile(merged, "PDF"); writeFile(mergedJSON, "JSON")
            let coll = CollectionSegment(collectionName: "MJ", fileURLs: [s1, s2])
            do {
                try seg.organizeOutput(
                    collections: [coll], outputDirectory: out,
                    outputURLMap: [s1: merged, s2: merged], moveSiblingImages: true,
                    exportedImageMap: [s1: i1, s2: i2])
            } catch { check("merged JSON collision: organizeOutput threw \(error)", false) }
            check("merged JSON collision: existing 000001 JSON preserved",
                  (try? String(contentsOf: existingJSON, encoding: .utf8)) == "KEEP")
            check("merged JSON collision: new set advanced together to 000002/000003",
                  fm.fileExists(atPath: folder.appendingPathComponent("000002 MJ.jpg").path)
                  && fm.fileExists(atPath: folder.appendingPathComponent("000003 MJ.jpg").path)
                  && fm.fileExists(atPath: folder.appendingPathComponent("000002 MJ.pdf").path)
                  && fm.fileExists(atPath: jsonFolder.appendingPathComponent("000002 MJ.json").path))
            try? fm.removeItem(at: out)
        }

        // Failed collision-renamed export: never fall back to and move the unrelated preferred-name image.
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-missing-export-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let source = out.appendingPathComponent("page.src")
            let pdf = out.appendingPathComponent("page.pdf")
            let unrelatedPreferred = out.appendingPathComponent("page.jpg")
            let missingTracked = out.appendingPathComponent("page (2).jpg")
            writeFile(pdf, "PDF"); writeFile(unrelatedPreferred, "USER")
            let coll = CollectionSegment(collectionName: "ME", fileURLs: [source])
            var didThrow = false
            do {
                try seg.organizeOutput(
                    collections: [coll], outputDirectory: out,
                    outputURLMap: [source: pdf], moveSiblingImages: true,
                    exportedImageMap: [source: missingTracked])
            } catch { didThrow = true }
            check("missing tracked export: organization stops safely", didThrow)
            check("missing tracked export: unrelated preferred image remains untouched",
                  (try? String(contentsOf: unrelatedPreferred, encoding: .utf8)) == "USER")
            check("missing tracked export: PDF source remains retryable", fm.fileExists(atPath: pdf.path))
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // W47.ct-processor-capture — Process Files' box and folder labels: organisation reports where each PDF
        // went, and the labels' fields land in the collection folder's container file, naming the filed PDFs.
        // ============================================================================================
        do {
            let out = fm.temporaryDirectory.appendingPathComponent("APOrgTest-labels-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let names = ["box", "doc", "folder", "doc2"]
            let sources = names.map { out.appendingPathComponent("\($0).jpg") }   // not images: no gateway read
            let pdfs = names.map { out.appendingPathComponent("\($0).pdf") }
            for (src, pdf) in zip(sources, pdfs) { writeFile(src, "src"); writeFile(pdf, "PDF \(pdf.lastPathComponent)") }
            let map = Dictionary(uniqueKeysWithValues: zip(sources, pdfs))
            var moves: [URL: URL] = [:]
            do {
                moves = try seg.organizeOutput(collections: [CollectionSegment(collectionName: "Glotzer", fileURLs: sources)],
                                               outputDirectory: out, outputURLMap: map, moveSiblingImages: false)
            } catch { check("labels: organizeOutput threw \(error)", false) }
            let folder = out.appendingPathComponent("Glotzer")
            check("labels: organizeOutput reports each PDF's new place",
                  moves[pdfs[0]] == folder.appendingPathComponent("000001 Glotzer.pdf")
                  && moves[pdfs[2]] == folder.appendingPathComponent("000003 Glotzer.pdf") && moves.count == 4)

            let texts = ["HOOVER INSTITUTION ARCHIVES\nBOX NO. 17", "Dear Sir", "Folder 8\nCorrespondence", "More"]
            let kinds: [DocumentClassification] = [.boxLabel, .documentStart, .folderLabel, .documentStart]
            let processor = OCRProcessor()
            processor.jobs = (0..<4).map { i in
                var job = OCRJob(sourceURL: sources[i])
                job.status = .succeeded
                job.classification = kinds[i]
                job.result = OCRResult(text: texts[i], classification: kinds[i], errorMessage: nil, errorCode: nil)
                return job
            }
            processor.outputURLMap = map
            // The pre-OCRed route reads no labels, and nothing is written beside a source.
            let preOCRed = await processor.recordContainerLabels(moves: moves, outputDirectory: out, preOCRedInput: true)
            check("labels: the pre-OCRed route writes no container file",
                  preOCRed == nil && ContainerFileStore.load(directory: folder) == .missing)
            processor.outputURLMap = Dictionary(uniqueKeysWithValues: zip(sources, sources))
            let asSource = await processor.recordContainerLabels(moves: [:], outputDirectory: out, preOCRedInput: false)
            check("labels: an output that is its own source is never written beside",
                  asSource != nil && ContainerFileStore.load(directory: out) == .missing)
            processor.outputURLMap = map
            let problem = await processor.recordContainerLabels(moves: moves, outputDirectory: out, preOCRedInput: false)
            let file = ContainerFileStore.load(directory: folder).document
            let at4 = file.map { ContainerResolver.resolve(fileName: "000004 Glotzer.pdf", scopes: [ContainerScope(file: $0)]) }
            let at2 = file.map { ContainerResolver.resolve(fileName: "000002 Glotzer.pdf", scopes: [ContainerScope(file: $0)]) }
            // With no gateway and no local label model (as here), the run says so; any other note is a problem
            // (W49.proc-gemma-offer-download added that note; W49.proc-fix-red-checks-1125).
            func onlyNoModelNote(_ note: String?, labels: Int) -> Bool {
                note == nil || note == "No model supplied suggestions for \(labels) box or folder label\(labels == 1 ? "" : "s"). "
                    + "Check the proposals in Archive Reader."
            }
            check("labels: the box and folder labels' runs are written beside the filed PDFs, as proposals",
                  onlyNoModelNote(problem, labels: 2) && at4?.values[.container]?.value == "Box 17" && at4?.values[.folder]?.value == "8"
                  && at4?.values[.container]?.source == .label && at2?.values[.folder] == nil
                  && at2?.values[.repository]?.value == "HOOVER INSTITUTION ARCHIVES")
            let filed = (try? fm.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
            check("labels: nothing but .archivesuite is added, and no PDF is changed",
                  filed == [".archivesuite", "000001 Glotzer.pdf", "000002 Glotzer.pdf", "000003 Glotzer.pdf", "000004 Glotzer.pdf"]
                  && (try? String(contentsOf: folder.appendingPathComponent("000003 Glotzer.pdf"), encoding: .utf8))
                      == "PDF folder.pdf")
            try? fm.removeItem(at: out)
        }

        // ============================================================================================
        // W47.ct-processor-intake — Route B in Process Files: a dropped tree is read recursively, each output is
        // filed in the same folders below the output folder, the level map is offered once and written there, a
        // merged document stays in its folder, organisation leaves the tree's outputs alone, a resume keeps the tree.
        // ============================================================================================
        do {
            let base = fm.temporaryDirectory.appendingPathComponent("APOrgTest-tree-\(UUID().uuidString)", isDirectory: true)
            let input = base.appendingPathComponent("in", isDirectory: true)
            let out = base.appendingPathComponent("out", isDirectory: true)
            let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
            for dir in [out, elsewhere] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            func put(_ path: String) -> URL {
                let url = input.appendingPathComponent(path)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                writeFile(url, "src \(path)")
                return url
            }
            func writePDF(_ url: URL) {
                var box = CGRect(x: 0, y: 0, width: 72, height: 72)
                guard let consumer = CGDataConsumer(url: url as CFURL),
                      let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
                context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
            }
            let made = ["Glotzer papers/label.jpg", "Glotzer papers/Box 17/Folder 8/0001.jpg",
                        "Glotzer papers/Box 17/Folder 8/0002.jpg", "Glotzer papers/Box 17/Folder 9/0001.jpg"].map(put)
            _ = put("Glotzer papers/Box 17/.archivesuite/x.jpg")
            let loose = put("loose.jpg")
            // Sources older than any output, set before anything reads their dates (a URL caches what it read).
            for url in made + [loose] {
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
            }
            let flat = input.appendingPathComponent("Flat", isDirectory: true)
            try? fm.createDirectory(at: flat, withIntermediateDirectories: true)
            for n in ["b.jpg", "a.jpg"] { writeFile(flat.appendingPathComponent(n), "flat") }
            let sources = Set((made + [loose]).map(\.path))
            let isJPEG: (URL) -> Bool = { $0.pathExtension == "jpg" }

            let flatOnly = ProcessFilesTree.collect([flat], accept: isJPEG, sortAll: true)
            check("tree: a folder with no subfolders is read flat, as before",
                  flatOnly.files.map(\.lastPathComponent) == ["a.jpg", "b.jpg"] && flatOnly.subfolders.isEmpty)
            // W49.proc-six-digit-names: a folder filed under both widths is read in filing order, not string order
            // (where "000042" would sort before "00040").
            let mixed = fm.temporaryDirectory.appendingPathComponent("APOrgTest-mixedintake-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: mixed, withIntermediateDirectories: true)
            for n in ["000042 M.jpg", "00041 M.jpg", "00040 M.jpg"] { writeFile(mixed.appendingPathComponent(n), "m") }
            let mixedOrder = ["00040 M.jpg", "00041 M.jpg", "000042 M.jpg"]
            check("six digits: a mixed-width folder is read in filing order, dropped or chosen",
                  ProcessFilesTree.collect([mixed], accept: isJPEG, sortAll: true).files.map(\.lastPathComponent) == mixedOrder
                  && ProcessFilesTree.collect([mixed], accept: isJPEG, sortAll: false).files.map(\.lastPathComponent) == mixedOrder)
            try? fm.removeItem(at: mixed)
            let intake = ProcessFilesTree.collect([input.appendingPathComponent("Glotzer papers"), loose],
                                                  accept: isJPEG, sortAll: true)
            // The tree's own URLs from here on (the walk may spell the scratch path with /private).
            let found = intake.files.count == 5 ? intake.files : made + [loose]
            let (label, a, b, c) = (found[0], found[1], found[2], found[3])
            check("tree: a folder with subfolders is read depth-first, each file with its folders",
                  intake.files.map { $0.pathComponents.suffix(2).joined(separator: "/") }
                    == ["Glotzer papers/label.jpg", "Folder 8/0001.jpg", "Folder 8/0002.jpg", "Folder 9/0001.jpg", "in/loose.jpg"]
                  && intake.files[4] == loose
                  && intake.subfolders[a] == "Glotzer papers/Box 17/Folder 8"
                  && intake.subfolders[label] == "Glotzer papers" && intake.subfolders[loose] == nil)

            let glotzer = input.appendingPathComponent("Glotzer papers")
            check("tree: a folder holding folders is asked about, a flat one is not",
                  ProcessFilesTree.hasSubfolders(glotzer) && !ProcessFilesTree.hasSubfolders(flat)
                  && !ProcessFilesTree.hasSubfolders(loose))
            let ownOnly = ProcessFilesTree.collect([glotzer], accept: isJPEG, sortAll: true, readSubfolders: false)
            check("tree: answering “only its own files” reads it flat, as before",
                  ownOnly.files.map(\.lastPathComponent) == ["label.jpg"] && ownOnly.subfolders.isEmpty)
            // Nothing is filed among the sources: an output folder that is the tree, inside it, or holds it is refused.
            check("tree: an output folder that holds the given folder is refused",
                  ProcessFilesTree.treeHoldingOutput(subfolders: intake.subfolders, outputDirectory: input) == "Glotzer papers")
            check("tree: an output folder inside the given folder is refused",
                  ProcessFilesTree.treeHoldingOutput(subfolders: intake.subfolders,
                                                     outputDirectory: glotzer.appendingPathComponent("Box 17")) == "Glotzer papers"
                  && ProcessFilesTree.treeHoldingOutput(subfolders: intake.subfolders, outputDirectory: glotzer) == "Glotzer papers")
            check("tree: an output folder apart from it is accepted",
                  ProcessFilesTree.treeHoldingOutput(subfolders: intake.subfolders, outputDirectory: out) == nil
                  && ProcessFilesTree.treeHoldingOutput(subfolders: intake.subfolders, outputDirectory: base) == nil)

            // The level map: offered for a tree's files while the output folder has none, then written there.
            let offered = ProcessFilesTree.levelsToOffer(files: intake.files, subfolders: intake.subfolders,
                                                         outputDirectory: out)
            check("tree: the level map is offered, pre-filled from the folder names",
                  offered?.map.levels == [.collection, .box, .folder])
            check("tree: no map is offered for files not from a tree",
                  ProcessFilesTree.levelsToOffer(files: [loose], subfolders: [:], outputDirectory: out) == nil)
            check("tree: Save writes the map at the output folder", offered.flatMap(ProcessFilesTree.saveLevels) == nil
                  && ContainerFileStore.loadLevelMap(root: out).document?.levels == [.collection, .box, .folder])
            check("tree: with a map there, it is not offered again",
                  ProcessFilesTree.levelsToOffer(files: intake.files, subfolders: intake.subfolders,
                                                 outputDirectory: out) == nil)

            // Placement: in the tree's folders, made as needed; a base name shared across folders does not collide.
            let processor = OCRProcessor()
            processor.outputSubfolders = OCRProcessor.keyedSubfolders(intake.subfolders)
            let outputs = intake.files.map {
                processor.uniqueOutputURL(baseName: $0.deletingPathExtension().lastPathComponent, ext: "pdf", in: out, for: $0)
            }
            let tree = out.appendingPathComponent("Glotzer papers/Box 17")
            check("tree: each output goes in its folders below the output folder",
                  outputs == [out.appendingPathComponent("Glotzer papers/label.pdf"),
                              tree.appendingPathComponent("Folder 8/0001.pdf"), tree.appendingPathComponent("Folder 8/0002.pdf"),
                              tree.appendingPathComponent("Folder 9/0001.pdf"), out.appendingPathComponent("loose.pdf")]
                  && fm.fileExists(atPath: tree.appendingPathComponent("Folder 9").path))
            // A link in the tree's place is never followed: that output goes in the output folder itself.
            try? fm.createSymbolicLink(at: out.appendingPathComponent("Linked"), withDestinationURL: elsewhere)
            let linkedSource = input.appendingPathComponent("Linked/Box 1/0001.jpg")
            processor.outputSubfolders[linkedSource.standardizedFileURL.path] = "Linked/Box 1"
            let linked = processor.uniqueOutputURL(baseName: "0009", ext: "pdf", in: out, for: linkedSource)
            check("tree: a link in the way is not followed, and the summary names the output",
                  linked == out.appendingPathComponent("0009.pdf")
                  && ((try? fm.contentsOfDirectory(atPath: elsewhere.path)) ?? ["?"]).isEmpty
                  && processor.outputsOutsideTheirTree == [linkedSource.standardizedFileURL.path] && processor.treeFallbackSuffix.contains("0001.jpg"))
            processor.clearOutputWarnings()
            processor.outputSubfolders[linkedSource.standardizedFileURL.path] = nil
            check("tree: a folder name that would leave the output folder is refused",
                  OCRProcessor.keyedSubfolders([loose: "../escape"]).isEmpty)

            // Organisation leaves the tree's outputs; merging stays within a folder and beside its pages.
            processor.outputURLMap = Dictionary(uniqueKeysWithValues: zip(intake.files, outputs))
            processor.collectionSegments = [CollectionSegment(collectionName: "Glotzer", fileURLs: [a, b, c]),
                                            CollectionSegment(collectionName: "Loose", fileURLs: [label, loose])]
            check("tree: collection organisation is given only the outputs and collections outside the tree",
                  processor.outputURLMapOutsideTrees == [loose: out.appendingPathComponent("loose.pdf")]
                  && processor.collectionsOutsideTrees.map(\.collectionName) == ["Loose"]
                  && processor.treeFallbackSuffix.isEmpty)
            for pdf in outputs { writePDF(pdf) }
            let documentFiles = [a, b, c]
            processor.jobs = documentFiles.enumerated().map { i, source in
                let classification: DocumentClassification = i == 0 ? .documentStart : .documentContinuation
                var job = OCRJob(sourceURL: source)
                job.classification = classification
                job.result = OCRResult(text: ["Apricot", "Blossom", "Cedar"][i], classification: classification,
                                       errorMessage: nil, errorCode: nil)
                return job
            }
            processor.rebuildSegments(files: documentFiles)
            check("tree: a continuation in the next folder starts its own segment with only its own text",
                  processor.segments.map(\.pdfURLs) == [[a, b], [c]]
                  && processor.segments.map(\.texts) == [["Apricot", "Blossom"], ["Cedar"]])

            let manualFiles = [a, c, b]
            let starts = processor.treeFolderStarts(in: manualFiles)
            processor.manualSegImages = manualFiles.enumerated().map { i, url in
                ManualSegImage(fileIndex: i, url: url, rotationDegrees: 0, kind: .document,
                               startsTreeFolder: starts.contains(i))
            }
            processor.manualSegRemoved = [1]
            processor.manualSegFocus = 2
            check("tree: the manual tag card stops at a folder break even when that folder's page is removed",
                  processor.manualSegPendingRange == (0...0)
                  && processor.treeFolderStarts(in: manualFiles, excluding: [c]) == [2])

            // Even an explicit enclosure flag must find its cover in the same folder.
            let enclosureResult = DocumentSegmenter().segment(
                files: [a, b, c], classifications: [.documentStart, .documentStart, .documentStart],
                texts: [], enclosureFlags: [false, true, true],
                folderStarts: processor.treeFolderStarts(in: documentFiles))
            check("tree: an enclosure can point to a cover in its folder only",
                  enclosureResult.map(\.enclosureOf) == [nil, 0, nil])

            // Seed distinct tag replies without calling a provider, then let the normal tagging path write them.
            processor.preGroupedSubjects = [["Apricot"], [], ["Cedar"]]
            let model = LLMModel.geminiModels[0]
            await processor.performTaggingPhase(provider: .gemini, model: model, apiKey: "", outputDirectory: out,
                                              enableSegmentJSON: true)
            func tags(at pdf: URL) -> [String] { (try? MacOSTagger.readTags(from: pdf)) ?? [] }
            check("tree: separate PDFs carry only their folder's subject",
                  tags(at: outputs[1]).contains("Apricot") && !tags(at: outputs[1]).contains("Cedar")
                  && tags(at: outputs[2]).contains("Apricot") && !tags(at: outputs[2]).contains("Cedar")
                  && tags(at: outputs[3]).contains("Cedar") && !tags(at: outputs[3]).contains("Apricot"))

            await processor.performDocumentMerging(files: documentFiles, outputDirectory: out)
            let merged = tree.appendingPathComponent("Folder 8/0001_merged.pdf")
            let second = tree.appendingPathComponent("Folder 9/0001.pdf")
            check("tree: a document is merged within its folder, beside its pages, with its own tags",
                  processor.outputURLMap[a] == merged && processor.outputURLMap[b] == merged
                  && PDFDocument(url: merged)?.pageCount == 2
                  && processor.outputURLMap[c] == second && fm.fileExists(atPath: second.path)
                  && tags(at: merged).contains("Apricot") && !tags(at: merged).contains("Cedar")
                  && tags(at: second).contains("Cedar") && !tags(at: second).contains("Apricot"))

            func sidecar(for pdf: URL) -> [String: Any]? {
                let url = pdf.deletingPathExtension().appendingPathExtension("json")
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            let firstSidecar = sidecar(for: merged)
            let secondSidecar = sidecar(for: second)
            check("tree: each sidecar carries only its own pages, text and subject",
                  firstSidecar?["files"] as? [String] == [a.lastPathComponent, b.lastPathComponent]
                  && firstSidecar?["subjects"] as? [String] == ["Apricot"]
                  && (firstSidecar?["body"] as? String)?.contains("Blossom") == true
                  && (firstSidecar?["body"] as? String)?.contains("Cedar") == false
                  && secondSidecar?["files"] as? [String] == [c.lastPathComponent]
                  && secondSidecar?["subjects"] as? [String] == ["Cedar"]
                  && (secondSidecar?["body"] as? String)?.contains("Cedar") == true
                  && (secondSidecar?["body"] as? String)?.contains("Apricot") == false)

            // Incremental skip looks in each source's own folder: Folder 9's 0001.pdf is there, Folder 8's is not
            // (merged), and the output folder's own 0001.pdf never stands in for either.
            writePDF(out.appendingPathComponent("0001.pdf"))
            let partition = OCRProcessor.incrementalPartition([a, c, loose], outputDirectory: out,
                                                               subfolders: intake.subfolders)
            check("tree: incremental skip checks each source's own folder",
                  partition.skipped == [c, loose] && partition.toProcess == [a])

            // A resume keeps the tree: the snapshot carries it, and a run without one records nothing new.
            let config = processor.makePendingRunSnapshot(imageScale: 1, gatewayConfig: nil)
            let encoded = try? JSONEncoder().encode(config)
            let decoded = encoded.flatMap { try? JSONDecoder().decode(OCRProcessor.PendingRunSnapshot.self, from: $0) }
            check("tree: the resume snapshot carries the tree", decoded?.outputSubfolders == processor.outputSubfolders)
            let plain = OCRProcessor().makePendingRunSnapshot(imageScale: 1, gatewayConfig: nil)
            let plainJSON = (try? JSONEncoder().encode(plain)).flatMap { String(data: $0, encoding: .utf8) } ?? "outputSubfolders"
            check("tree: a run with no tree writes the snapshot as before", !plainJSON.contains("outputSubfolders"))

            // A box label filed in the tree: its run is written beside it, in the tree's folder.
            processor.jobs = [{ var j = OCRJob(sourceURL: label); j.status = .succeeded; j.classification = .boxLabel
                                j.result = OCRResult(text: "BOX 17", classification: .boxLabel, errorMessage: nil, errorCode: nil)
                                return j }()]
            let problem = await processor.recordContainerLabels(moves: [:], outputDirectory: out, preOCRedInput: false)
            let labelFile = ContainerFileStore.load(directory: out.appendingPathComponent("Glotzer papers")).document
            check("tree: a label filed in the tree is recorded in its folder",
                  (problem == nil || problem == "No model supplied suggestions for 1 box or folder label. "
                      + "Check the proposals in Archive Reader.")
                  && labelFile?.runs.first?.start == "label.pdf")

            let left = (fm.enumerator(atPath: input.path)?.allObjects as? [String] ?? [])
                .map { input.appendingPathComponent($0).path }
                .filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && !d.boolValue }
            check("tree: no source is changed, moved or added to",
                  Set(left) == sources.union([flat.appendingPathComponent("a.jpg").path, flat.appendingPathComponent("b.jpg").path,
                                              input.appendingPathComponent("Glotzer papers/Box 17/.archivesuite/x.jpg").path])
                  && (made + [loose]).allSatisfy { (try? String(contentsOf: $0, encoding: .utf8))?.hasPrefix("src ") == true })
            try? fm.removeItem(at: base)
        }

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["COLLECTIONORGANIZE_TEST_OUT"]
            ?? fm.temporaryDirectory.appendingPathComponent("APOrganizeTest-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        NSLog("ORGANIZETEST DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}

#endif
