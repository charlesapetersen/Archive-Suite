import Foundation
import AppKit
import PDFKit
import ArchiveCore

/// Headless, $0 self-test of the Process Files OUTPUT-WARNING contract (W23.m5 + W23.h5-fu), gated by
/// `PROCESSFILES_TAGWARN_TEST=1` (does nothing in normal use). Synthetic files in a temp dir — no OCR, no
/// network, no cost, no GUI, and it never opens the corpus.
///
/// What has to be true for the warning to be worth anything:
///   1. The VERDICT is real — a tag write the filesystem refuses returns `false` (and the file really is
///      untagged), while a write that lands returns `true` and the tags are readable back off disk.
///   2. The seam did not become a new way to guess a colour — the `GeneratedTags` overload keeps a subject
///      tag that is literally "Red" searchable and label-less, while the app's own colour still lands.
///   3. The RECORD is keyed by the INPUT file (the one name `organizeOutput`'s move + renumber cannot
///      invalidate) and self-heals — a later successful re-write clears an earlier failure, so a rotation
///      regen or review retry does not leave a warning about work that is now fine.
///   4. Merge keeps the record honest — one merged PDF now covers every page, so its successful tag write
///      RESOLVES each page's earlier tag failure, while a placeholder page copied into the merge stays
///      recorded against the photo it came from.
///   5. The SUMMARY says so — silence when clean, names when not, and it never claims a file is untagged
///      and un-embedded in the same breath unless both are true.
///   6. `PDFGenerator`'s image-page outcome is really WIRED to the placeholder record (W23.h5-fu).
///   7. A read-append-rewrite reproduces the label the FRESH write intended (W23.m5-fu) — the two sites
///      that re-apply tags read back off disk take the colour from the page's classification, so a
///      subject tag "Red" is never promoted to the box label and a real box/folder never loses one.
///
/// Writes a PASS/FAIL report to `PROCESSFILES_TAGWARN_TEST_OUT` (or a temp file) + NSLog. Test scaffolding.
@MainActor
enum ProcessFilesTagWarningTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["PROCESSFILES_TAGWARN_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("TAGWARN \(ok ? "PASS" : "FAIL"): \(name)")
        }

        let tmp = fm.temporaryDirectory.appendingPathComponent("APTagWarn-\(UUID().uuidString)",
                                                               isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let originalStampUnread = MacOSTagger.stampUnread
        defer {
            MacOSTagger.stampUnread = originalStampUnread
            // Clear every immutable flag first, or the temp tree cannot be removed. (`FileManager`'s
            // enumerator is unavailable from an async context, so walk the paths it already knows.)
            let allPaths = (try? fm.subpathsOfDirectory(atPath: tmp.path)) ?? []
            for p in allPaths {
                try? fm.setAttributes([.immutable: false],
                                      ofItemAtPath: tmp.appendingPathComponent(p).path)
            }
            try? fm.removeItem(at: tmp)
        }

        func tagsOf(_ u: URL) -> [String] {
            if case .success(let names, _) = TagReading.read(u) { return names }
            return []
        }
        /// A cleared label reads back as 0 or absent depending on the write path; both mean "no colour".
        func labelOf(_ u: URL) -> Int {
            if case .success(_, let label) = TagReading.read(u) { return label ?? 0 }
            return -1
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        func makeJPEG(_ name: String, in dir: URL) -> URL {
            let u = dir.appendingPathComponent(name)
            if let d = bitmap?.representation(using: .jpeg, properties: [:]) { try? d.write(to: u) }
            return u
        }
        func writeOnePagePDF(_ url: URL) {
            var mediaBox = CGRect(x: 0, y: 0, width: 72, height: 72)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
        }

        // --- 1. The verdict is real. `uchg` is the permission class the old `_ = try?` erased. ---
        let verdictDir = tmp.appendingPathComponent("verdict", isDirectory: true)
        try? fm.createDirectory(at: verdictDir, withIntermediateDirectories: true)
        let writable = verdictDir.appendingPathComponent("writable.pdf")
        writeOnePagePDF(writable)
        let wroteOK = OCRProcessor.writeOutputTags(["1948", "Correspondence"], to: writable, stampUnread: true)
        check("a tag write that lands is reported succeeded", wroteOK)
        check("...and the tags it claims are genuinely ON DISK",
              tagsOf(writable).contains("1948") && tagsOf(writable).last == "Unread")

        let locked = verdictDir.appendingPathComponent("locked.pdf")
        writeOnePagePDF(locked)
        try? fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        let lockedVerdict = OCRProcessor.writeOutputTags(["1948"], to: locked, stampUnread: true)
        check("a tag write the filesystem refuses is reported FAILED, not swallowed", lockedVerdict == false)
        check("...and the refusal was real — the file carries no tags", tagsOf(locked).isEmpty)
        try? fm.setAttributes([.immutable: false], ofItemAtPath: locked.path)

        // --- 2. The seam never guesses a colour (the `GeneratedTags` overload stays authoritative). ---
        let redDoc = verdictDir.appendingPathComponent("redscare.pdf")
        writeOnePagePDF(redDoc)
        _ = OCRProcessor.writeOutputTags(GeneratedTags(subjectTags: ["Red", "1948"]), to: redDoc,
                                         stampUnread: true)
        check("a subject tag that is literally \"Red\" survives as a searchable tag",
              tagsOf(redDoc).contains("Red") && tagsOf(redDoc).contains("1948"))
        check("...and is NOT promoted to a Finder colour label", labelOf(redDoc) == 0)
        let boxPDF = verdictDir.appendingPathComponent("boxlabel.pdf")
        writeOnePagePDF(boxPDF)
        _ = OCRProcessor.writeOutputTags(GeneratedTags(subjectTags: ["Box"], colorTag: "Red"), to: boxPDF,
                                         stampUnread: true)
        check("the app's OWN colour still writes the Finder RED label", labelOf(boxPDF) == 6)
        check("...and \"Red\" appears exactly once in its tags",
              tagsOf(boxPDF).filter { $0 == "Red" }.count == 1)

        // --- 3. The record is keyed by the INPUT file and self-heals. The key matters: `organizeOutput`
        // both MOVES and RENUMBERS every output ("00003 Box 12.pdf"), so an output name or URL recorded
        // during the run names a file that no longer exists by the time the summary is written. ---
        let recorder = OCRProcessor()
        let photo = verdictDir.appendingPathComponent("IMG_2043.jpg")
        recorder.recordTagWrite(succeeded: false, forSource: photo)
        recorder.recordTagWrite(succeeded: false, forSource: photo)
        check("a repeated failure is recorded exactly once", recorder.untaggedOutputs == ["IMG_2043.jpg"])
        check("the record names the INPUT file, which organizeOutput's renumbering cannot invalidate",
              recorder.untaggedOutputs.allSatisfy { !$0.contains(".pdf") })
        recorder.recordTagWrite(succeeded: true, forSource: photo)
        check("a later successful re-write CLEARS the earlier failure", recorder.untaggedOutputs.isEmpty)
        recorder.recordImagePage(.placeholder, forSource: photo)
        check("a placeholder image page is recorded", recorder.placeholderOutputs == ["IMG_2043.jpg"])
        recorder.recordImagePage(.embedded, forSource: photo)
        check("...and a regen that embeds the scan clears it", recorder.placeholderOutputs.isEmpty)
        recorder.recordTagWrite(succeeded: false, forSource: photo)
        recorder.recordImagePage(.placeholder, forSource: photo)
        recorder.forgetOutputWarnings(forSources: [photo])
        check("excluding a file from the run drops both of its warnings",
              recorder.untaggedOutputs.isEmpty && recorder.placeholderOutputs.isEmpty)
        recorder.recordTagWrite(succeeded: false, forSource: photo)
        recorder.clearOutputWarnings()
        check("a new run starts with both records empty",
              recorder.untaggedOutputs.isEmpty && recorder.placeholderOutputs.isEmpty)

        // --- 3b. THE WIRING. A verdict nothing reads is worth nothing, so drive a REAL production tag
        // site (`applyBoxFolderLabelTags`, the box/folder pass) against an output the filesystem refuses
        // and prove the record fills — the seam and the record are actually connected. ---
        let wireDir = tmp.appendingPathComponent("wiring", isDirectory: true)
        try? fm.createDirectory(at: wireDir, withIntermediateDirectories: true)
        let wireSource = wireDir.appendingPathComponent("boxphoto.jpg")
        let wireOutput = wireDir.appendingPathComponent("boxphoto.pdf")
        writeOnePagePDF(wireOutput)
        try? fm.setAttributes([.immutable: true], ofItemAtPath: wireOutput.path)
        let wired = OCRProcessor()
        wired.taggingMode = .none            // → the box/folder colour pass runs
        var boxJob = OCRJob(sourceURL: wireSource)
        boxJob.result = OCRResult(text: "BOX 12", classification: .boxLabel,
                                  errorMessage: nil, errorCode: nil)
        wired.jobs = [boxJob]
        wired.outputURLMap = [wireSource: wireOutput]
        wired.applyBoxFolderLabelTags(enableTagging: false)
        check("a production tag site records the refusal (the wiring)",
              wired.untaggedOutputs == ["boxphoto.jpg"])
        check("...and the end-of-run summary carries it", OCRProcessor.outputWarningSuffix(
                untagged: wired.untaggedOutputs, placeholders: wired.placeholderOutputs)
                .contains("boxphoto.jpg"))
        try? fm.setAttributes([.immutable: false], ofItemAtPath: wireOutput.path)
        wired.applyBoxFolderLabelTags(enableTagging: false)
        check("...and re-running it once the file is writable clears the warning",
              wired.untaggedOutputs.isEmpty && tagsOf(wireOutput).contains("Box"))

        // --- 3c. A step that ATTEMPTS no tag write must not read as a success. `handleOCRResult`
        // regenerates the PDF on a post-run retry and (outside copy-source) does not re-tag it, so if
        // "no attempt" were recorded as `true`, that retry would silently clear a warning about a file
        // that is still untagged. Drive the real production path: a retry-shaped second pass through
        // `handleOCRResult` in a non-copy-source mode must leave the standing warning alone.
        let retryDir = tmp.appendingPathComponent("retry", isDirectory: true)
        try? fm.createDirectory(at: retryDir, withIntermediateDirectories: true)
        let retrySource = makeJPEG("IMG_9001.jpg", in: retryDir)
        let retrier = OCRProcessor()
        retrier.taggingMode = .automatic          // NOT copy-source → no tag write in handleOCRResult
        retrier.jobs = [OCRJob(sourceURL: retrySource)]
        retrier.recordTagWrite(succeeded: false, forSource: retrySource)   // the tagging phase's verdict
        let retryModel = LLMModel(id: "test-model", displayName: "Test Model", provider: .gemini,
                                  supportsThinking: false, returnsMd: false,
                                  inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
        _ = await retrier.handleOCRResult(
            OCRResult(text: "retried text", classification: nil, errorMessage: nil, errorCode: nil),
            index: 0, url: retrySource, model: retryModel, outputDirectory: retryDir)
        check("a retry that re-writes the PDF without re-tagging leaves the warning standing",
              retrier.untaggedOutputs == ["IMG_9001.jpg"])
        check("...and that retry really did produce a fresh output", retrier.outputURLMap[retrySource] != nil)

        // --- 4. Merge keeps the record honest. ---
        // Two component PDFs: one whose tag write failed, one carrying a placeholder image page. After the
        // merge BOTH are deleted, so neither may still be named — but the placeholder pages are copied into
        // the merged PDF, so that half has to move across rather than vanish.
        let mergeDir = tmp.appendingPathComponent("merge", isDirectory: true)
        try? fm.createDirectory(at: mergeDir, withIntermediateDirectories: true)
        let src1 = mergeDir.appendingPathComponent("source-1.jpg")
        let src2 = mergeDir.appendingPathComponent("source-2.jpg")
        let page1 = mergeDir.appendingPathComponent("page-1.pdf")
        let page2 = mergeDir.appendingPathComponent("page-2.pdf")
        writeOnePagePDF(page1); writeOnePagePDF(page2)
        let merger = OCRProcessor()
        merger.taggingMode = .automatic
        var job1 = OCRJob(sourceURL: src1)
        job1.appliedTags = ["1948", "Correspondence"]
        merger.jobs = [job1, OCRJob(sourceURL: src2)]
        merger.segments = [DocumentSegment(pdfURLs: [src1, src2])]
        merger.outputURLMap = [src1: page1, src2: page2]
        merger.recordTagWrite(succeeded: false, forSource: src1)
        merger.recordImagePage(.placeholder, forSource: src2)
        merger.performDocumentMerging(files: [src1, src2], outputDirectory: mergeDir)
        let mergedURL = merger.outputURLMap[src1]
        check("merge produced one durable output",
              mergedURL != nil && mergedURL == merger.outputURLMap[src2]
              && fm.fileExists(atPath: mergedURL?.path ?? "/nonexistent"))
        check("merge RESOLVES a page's earlier tag failure — the merged PDF's own write covers it",
              merger.untaggedOutputs.isEmpty)
        check("merge KEEPS the placeholder warning against the page it belongs to",
              merger.placeholderOutputs == ["source-2.jpg"])

        // --- 5. The summary. Silence when clean; specific when not; truncated past three. ---
        check("no warning at all when both records are empty",
              OCRProcessor.outputWarningSuffix(untagged: [], placeholders: []).isEmpty)
        let oneUntagged = OCRProcessor.outputWarningSuffix(untagged: ["A.pdf"], placeholders: [])
        check("an untagged output is named, and the warning says tag search will miss it",
              oneUntagged.contains("A.pdf") && oneUntagged.contains("NOT be tagged")
              && oneUntagged.contains("Reader will not find it"))
        check("...and it does not also claim a missing scan", !oneUntagged.contains("placeholder"))
        let onePlaceholder = OCRProcessor.outputWarningSuffix(untagged: [], placeholders: ["B.pdf"])
        check("a placeholder output is named, and the warning says the source was NOT touched",
              onePlaceholder.contains("B.pdf") && onePlaceholder.contains("placeholder, not the scan")
              && onePlaceholder.contains("NOT touched"))
        check("...and it does not also claim a tag failure", !onePlaceholder.contains("NOT be tagged"))
        let many = OCRProcessor.outputWarningSuffix(
            untagged: ["A.pdf", "B.pdf", "C.pdf", "D.pdf", "E.pdf"], placeholders: [])
        check("five untagged files report the count, three names and a remainder",
              many.contains("5 files' output") && many.contains("A.pdf, B.pdf, C.pdf +2 more")
              && !many.contains("D.pdf"))
        let both = OCRProcessor.outputWarningSuffix(untagged: ["A.pdf"], placeholders: ["B.pdf"])
        check("both failures on one run are reported together",
              both.contains("A.pdf") && both.contains("B.pdf"))

        // --- 6. The W23.h5-fu wiring: a real `PDFGenerator` outcome drives the placeholder record. ---
        let genDir = tmp.appendingPathComponent("pdfgen", isDirectory: true)
        try? fm.createDirectory(at: genDir, withIntermediateDirectories: true)
        let gen = PDFGenerator()
        let ocr = OCRResult(text: "page text", classification: nil, errorMessage: nil, errorCode: nil)
        let stubModel = LLMModel(id: "test-model", displayName: "Test Model", provider: .gemini,
                                 supportsThinking: false, returnsMd: false,
                                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
        let wiring = OCRProcessor()
        let realJPEG = makeJPEG("real.jpg", in: genDir)
        let realOut = genDir.appendingPathComponent("real.pdf")
        if let outcome = try? gen.generate(imageURL: realJPEG, result: ocr, model: stubModel,
                                           outputURL: realOut) {
            wiring.recordImagePage(outcome, forSource: realJPEG)
        }
        check("a decodable image records NO placeholder warning", wiring.placeholderOutputs.isEmpty)
        let junk = genDir.appendingPathComponent("corrupt.jpg")
        try? Data("this is not a JPEG".utf8).write(to: junk)
        let junkOut = genDir.appendingPathComponent("corrupt.pdf")
        if let outcome = try? gen.generate(imageURL: junk, result: ocr, model: stubModel, outputURL: junkOut) {
            wiring.recordImagePage(outcome, forSource: junk)
        }
        check("an undecodable image records the placeholder warning (the wiring)",
              wiring.placeholderOutputs == ["corrupt.jpg"])
        check("...and the PDF was still written with both pages — nothing is withheld",
              PDFDocument(url: junkOut)?.pageCount == 2)
        check("...and the source image was NOT touched", fm.fileExists(atPath: junk.path))
        let wiredSuffix = OCRProcessor.outputWarningSuffix(untagged: wiring.untaggedOutputs,
                                                           placeholders: wiring.placeholderOutputs)
        check("the end-of-run summary names exactly that file", wiredSuffix.contains("corrupt.jpg")
              && !wiredSuffix.contains("real.jpg"))

        // --- 7. W23.m5-fu — a READ-APPEND-REWRITE reproduces the label the FRESH write intended. ---
        // Both remaining rewrite sites re-apply an array of tag NAMES read back off the PDF. Detection
        // over those names stamped Finder label 6 on any document whose subject is literally "Red" —
        // and the Reader reads a red label as a BOX photo. The other half matters just as much: a
        // genuine box/folder PDF has to KEEP its label through the rewrite, which is exactly why
        // "make the colour authoritative" alone (with no colour to pass) is NOT the fix.
        let colourDir = tmp.appendingPathComponent("colour", isDirectory: true)
        try? fm.createDirectory(at: colourDir, withIntermediateDirectories: true)
        /// One processor holding a single job, wired the way the pre-grouped Live Capture path leaves it.
        func wiredProcessor(source: URL, output: URL,
                            classification: DocumentClassification?) -> OCRProcessor {
            let p = OCRProcessor()
            p.taggingMode = .automatic          // stampsUnread → a real-tagging rewrite, label written
            var job = OCRJob(sourceURL: source)
            job.classification = classification
            p.jobs = [job]
            p.outputURLMap = [source: output]
            return p
        }

        // 7a. `applyCapturePriorityTags` — the phone's per-page priority, layered on after tagging.
        let redSource = colourDir.appendingPathComponent("IMG_7001.jpg")
        let redPDF = colourDir.appendingPathComponent("redscare.pdf")
        writeOnePagePDF(redPDF)
        _ = OCRProcessor.writeOutputTags(GeneratedTags(subjectTags: ["Red", "1948"]), to: redPDF,
                                         stampUnread: true)
        let redCapture = wiredProcessor(source: redSource, output: redPDF,
                                        classification: .documentStart)
        redCapture.preGroupedPriorities = ["P10"]
        redCapture.applyCapturePriorityTags()
        check("a phone-priority rewrite does NOT promote the subject tag \"Red\" to a Finder label",
              labelOf(redPDF) == 0)
        check("...and it still layered the phone's priority on", tagsOf(redPDF).contains("P10"))
        check("...and \"Red\" is still a searchable subject tag", tagsOf(redPDF).contains("Red"))

        let boxSource = colourDir.appendingPathComponent("IMG_7002.jpg")
        let boxLabelPDF = colourDir.appendingPathComponent("box12.pdf")
        writeOnePagePDF(boxLabelPDF)
        _ = OCRProcessor.writeOutputTags(GeneratedTags(subjectTags: ["Box"], colorTag: "Red"),
                                         to: boxLabelPDF, stampUnread: true)
        let boxCapture = wiredProcessor(source: boxSource, output: boxLabelPDF,
                                        classification: .boxLabel)
        boxCapture.preGroupedPriorities = ["P9"]
        boxCapture.applyCapturePriorityTags()
        check("a genuine box label KEEPS its red Finder label through that rewrite",
              labelOf(boxLabelPDF) == 6)
        check("...with the priority added and \"Red\" still present exactly once",
              tagsOf(boxLabelPDF).contains("P9")
              && tagsOf(boxLabelPDF).filter { $0 == "Red" }.count == 1)

        // 7b. `exportOriginalImages` — the dual output's image mirrors its PDF's tags.
        let originalExportMB = OCRProcessor.exportedImageMB
        OCRProcessor.exportedImageMB = 5     // a tiny synthetic JPEG takes the pristine byte-copy path
        defer { OCRProcessor.exportedImageMB = originalExportMB }
        let exportSource = makeJPEG("IMG_7003.jpg", in: colourDir)
        // Name the PDF off the source's base and the exported image WOULD be the source itself, which
        // the same-file guard skips; a distinct base is what a real run's dedup'd output looks like.
        let exportPDF = colourDir.appendingPathComponent("page-7003.pdf")
        writeOnePagePDF(exportPDF)
        _ = OCRProcessor.writeOutputTags(GeneratedTags(subjectTags: ["Red", "1948"]), to: exportPDF,
                                         stampUnread: true)
        let exporter = wiredProcessor(source: exportSource, output: exportPDF,
                                      classification: .documentStart)
        exporter.exportOriginals = true
        await exporter.exportOriginalImages()
        let exportedImage = colourDir.appendingPathComponent("page-7003.jpg")
        check("the dual output's image was written", fm.fileExists(atPath: exportedImage.path))
        check("...and it mirrors the PDF's tags",
              tagsOf(exportedImage).contains("Red") && tagsOf(exportedImage).contains("1948"))
        check("...without inventing a Finder colour from the subject tag \"Red\"",
              labelOf(exportedImage) == 0)

        let folderSource = makeJPEG("IMG_7004.jpg", in: colourDir)
        let folderPDF = colourDir.appendingPathComponent("page-7004.pdf")
        writeOnePagePDF(folderPDF)
        _ = OCRProcessor.writeOutputTags(GeneratedTags(subjectTags: ["Folder"], colorTag: "Purple"),
                                         to: folderPDF, stampUnread: true)
        let folderExporter = wiredProcessor(source: folderSource, output: folderPDF,
                                            classification: .folderLabel)
        folderExporter.exportOriginals = true
        await folderExporter.exportOriginalImages()
        let folderImage = colourDir.appendingPathComponent("page-7004.jpg")
        check("a folder label's exported image carries the PURPLE label, matching its PDF",
              labelOf(folderImage) == 3)
        check("...and its tags match the PDF's", tagsOf(folderImage).contains("Folder"))

        // 7c. The rule itself: the colour comes from the classification, and from nothing else.
        check("box → Red, folder → Purple, ordinary document → no colour",
              OCRProcessor.authoritativeColor(for: .boxLabel) == "Red"
              && OCRProcessor.authoritativeColor(for: .folderLabel) == "Purple"
              && OCRProcessor.authoritativeColor(for: .documentStart) == nil
              && OCRProcessor.authoritativeColor(for: .documentContinuation) == nil
              && OCRProcessor.authoritativeColor(for: nil) == nil)
        var resultOnlyJob = OCRJob(sourceURL: colourDir.appendingPathComponent("IMG_7005.jpg"))
        resultOnlyJob.result = OCRResult(text: "BOX 13", classification: .boxLabel,
                                         errorMessage: nil, errorCode: nil)
        check("a job carrying its classification only on the OCR result still resolves its colour",
              OCRProcessor.authoritativeColor(forJob: resultOnlyJob) == "Red")

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["PROCESSFILES_TAGWARN_TEST_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("archiveprocessor-tagwarn-result.txt")
        try? Data(report.utf8).write(to: outPath, options: .atomic)
        NSLog("TAGWARN DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath.path)")
    }
}
