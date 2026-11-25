#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import ArchiveCore
import Foundation
import PDFKit

/// Key-free, no-network contract for W49.proc-unified-pipeline-2. A standard Process Files run journals each reading in
/// `pending_run.json` before its write, so the output PDF waits for the reviews: `handleOCRResult` only maps the
/// reserved path, a rotation or class settled in review and the last tags a review aimed at the file are carried, a page
/// removed in review is never written, and `materializeDeferredOutputs` writes each output once with the page's
/// settled reading. A failed held write maps nothing and fails its row; a route with no journal (a paid batch, a retry
/// after the run) still writes at once; a resume holds back the outputs it is missing and files them.
/// The journal is redirected into a temporary directory the way `RunQuitResumeContract` does it; nothing outside it is
/// read or written.
///
/// Run via `scripts/test-deferred-output.sh`.
@MainActor
enum DeferredOutputContract {
    nonisolated static let envKey = "DEFERRED_OUTPUT_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APDeferredOutput-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        var results: [String] = []
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)\(condition || detail.isEmpty ? "" : " — \(detail)")")
        }

        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let saved = ["BATCHRESUME_TEST", "ARCHIVEPROC_TEST_STATE_ROOT"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("BATCHRESUME_TEST", "1", 1)
        setenv("ARCHIVEPROC_TEST_STATE_ROOT", stateRoot.path, 1)
        defer { for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }
        let manifest = OCRProcessor.pendingRunURL
        guard manifest.deletingLastPathComponent().standardizedFileURL == stateRoot.standardizedFileURL,
              OCRProcessor.pendingCatalogueURL.deletingLastPathComponent().standardizedFileURL
                == stateRoot.standardizedFileURL else {
            finish(["FAIL: the run journals are redirected into scratch — \(manifest.path)"])
            return
        }
        try? fm.createDirectory(at: stateRoot, withIntermediateDirectories: true)

        // Landscape pages, so a quarter turn shows on the written image page.
        let input = root.appendingPathComponent("input", isDirectory: true)
        let pages = (1...4).map { input.appendingPathComponent(String(format: "p%02d.jpg", $0)) }
        guard pages.enumerated().allSatisfy({ makeJPEG($1, shade: 0.2 + 0.15 * Double($0)) }) else {
            finish(["FAIL: fixture JPEGs could not be created"])
            return
        }
        let model = LLMModel.appleVisionModels[0]
        var config = SessionProcessingConfig.fromProcessFilesRunStart()
        config.visionTextLLM = nil

        func pendingRun(_ processor: OCRProcessor, files: [URL], output: URL,
                        completed: [String: OCRResult] = [:], paths: [String: String]? = nil) -> OCRProcessor.PendingRun? {
            var run = OCRProcessor.PendingRun(
                provider: .appleVision, model: model, thinkingLevel: nil, fileURLs: files, outputDirectory: output,
                enableTagging: false, enableSegmentJSON: false, enableCollectionSegmentation: false,
                confirmCollectionIDs: false, reviewDocumentSegmentation: false, preOCRedInput: false,
                previousTextCharCount: 0, sendPreviousImage: false, customPrompt: nil, startedAt: Date(),
                gatewayConfig: nil, completedResults: completed, runFingerprint: nil, exportOriginals: false,
                localAgent: nil,
                runtimeConfig: processor.makePendingRunRuntimeConfig(imageScale: 1, gatewayConfig: nil, runConfig: config))
            run.completedOutputPaths = paths
            run.runFingerprint = OCRProcessor.pendingRunFingerprintV2(run)
            guard OCRProcessor.pendingRunIsSelfConsistent(run),
                  OCRProcessor._testWritePendingRun(run, to: manifest) else { return nil }
            return run
        }
        func reading(_ n: Int) -> OCRResult {
            OCRResult(text: "DEFERRED PAGE \(n) READING", classification: .documentStart, errorMessage: nil, errorCode: nil)
        }
        // The image sits on a letter page, so its turn shows only in the drawn area: the extent of its dark pixels.
        func landscape(_ url: URL?) -> Bool? {
            guard let url, let page = PDFDocument(url: url)?.page(at: 0),
                  let cg = page.thumbnail(of: CGSize(width: 240, height: 320), for: .mediaBox)
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let (w, h) = (cg.width, cg.height)
            var pixels = [UInt8](repeating: 255, count: w * h)
            guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var (minX, maxX, minY, maxY) = (w, -1, h, -1)
            for y in 0..<h { for x in 0..<w where pixels[y * w + x] < 200 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
            guard maxX > minX, maxY > minY else { return nil }
            return (maxX - minX) > (maxY - minY)
        }

        // 1. A standard run's readings: journaled, mapped, and no PDF yet.
        let output = root.appendingPathComponent("output", isDirectory: true)
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        let p = OCRProcessor()
        p.taggingMode = .none
        p.rotationMode = .off
        guard await p.beginCatalogueRun(outputRoot: output, sources: pages), let catalogue = p.catalogueRun,
              let run = pendingRun(p, files: pages, output: output) else {
            finish(results + ["FAIL: the run's catalogue and journal are set up in scratch"])
            return
        }
        p.activePendingRun = run
        p.jobs = pages.map { OCRJob(sourceURL: $0) }
        p.defersOutputWrites = true
        var saved3 = true
        for i in 0..<3 {
            saved3 = await p.handleOCRResult(reading(i), index: i, jobID: p.jobs[i].id, url: pages[i], model: model,
                                             outputDirectory: output, runConfig: config) && saved3
        }
        let outputs = (0..<3).map { p.outputURLMap[pages[$0]] }
        let held = outputs.compactMap { $0 }
        func workingPDFs() -> [String] {
            ((try? fm.subpathsOfDirectory(atPath: catalogue.workingRoot.path)) ?? []).filter { $0.hasSuffix(".pdf") }
        }
        check("a journaled reading reports saved", saved3)
        check("each output's path is reserved and mapped", held.count == 3 && Set(held).count == 3,
              "\(held.map(\.lastPathComponent))")
        check("no PDF is written while the reviews are still to come", workingPDFs().isEmpty, "\(workingPDFs())")
        check("every reading is in the journal", OCRProcessor._testReadPendingRun(from: manifest)?.completedResults.count == 3)
        check("every held output is recorded", p.deferredOutputs.count == 3 && held.allSatisfy { p.deferredOutputs[$0] != nil })

        // 2. The reviews: a quarter turn and a box on page 1, a folder on page 2, page 3 removed.
        p.jobs[0].result = p.jobs[0].result?.with(classification: .boxLabel, rotationDegrees: 90)
        p.jobs[0].classification = .boxLabel
        p.journalHeldRotation(at: 0)
        check("a turn made in review on an unwritten output is journaled for a resume",
              OCRProcessor._testReadPendingRun(from: manifest)?.completedResults["0"]?.rotationDegrees == 90
                && OCRProcessor._testReadPendingRun(from: manifest)?.completedResults["0"]?.text == reading(0).text)
        let held0 = p.tagOutput(["Alpha", "Beta"], at: held[0], source: pages[0], stampUnread: false)
        check("a tag write aimed at an unwritten output is held, not failed",
              held0 && p.untaggedOutputs.isEmpty && p.deferredOutputs[held[0]]?.tags?.tags == ["Alpha", "Beta"]
                && !fm.fileExists(atPath: held[0].path))
        p.updateClassification(at: 1, to: .folderLabel, runConfig: config)
        check("a class edit before the write rewrites nothing and keeps the run's message",
              !fm.fileExists(atPath: held[1].path) && !p.statusMessage.contains("could not be updated"), p.statusMessage)
        let removed = p.discardGeneratedOutput(for: pages[2])
        p.jobs[2].status = .removed
        check("a page removed before the write is dropped", removed && p.deferredOutputs[held[2]] == nil
              && p.outputURLMap[pages[2]] == nil)

        // 3. The one write.
        await p.materializeDeferredOutputs()
        check("the outputs are written once the reviews are done", fm.fileExists(atPath: held[0].path)
              && fm.fileExists(atPath: held[1].path) && workingPDFs().count == 2, "\(workingPDFs())")
        check("nothing is left held and later writes go straight through",
              p.deferredOutputs.isEmpty && !p.defersOutputWrites)
        check("the removed page is never written", !fm.fileExists(atPath: held[2].path))
        check("the quarter turn is on the written image page", landscape(held[0]) == false && landscape(held[1]) == true,
              "page 1 landscape \(String(describing: landscape(held[0]))), page 2 \(String(describing: landscape(held[1])))")
        let header0 = PDFHeaderParser.extract(held[0])
        let header1 = PDFHeaderParser.extract(held[1])
        check("each page's settled class is in its header with no rewrite",
              header0?.classification == DocumentClassification.boxLabel.displayName
                && header1?.classification == DocumentClassification.folderLabel.displayName,
              "\(header0?.classification ?? "nil"), \(header1?.classification ?? "nil")")
        check("each written output holds its own reading",
              header0?.fullBody.contains("DEFERRED PAGE 0 READING") == true
                && header1?.fullBody.contains("DEFERRED PAGE 1 READING") == true)
        let tags0 = (try? MacOSTagger.readTags(from: held[0])) ?? []
        check("the held tags are on the written file", tags0.contains("Alpha") && tags0.contains("Beta"), "\(tags0)")
        check("the written outputs carry no catalogue identity until filing",
              !OutputFileSafety.hasCatalogueIdentity(at: held[0]) && !OutputFileSafety.hasCatalogueIdentity(at: held[1]))

        // 4. A held write that fails maps nothing and fails its row, with the reading kept.
        let missingFolder = output.appendingPathComponent("gone", isDirectory: true).appendingPathComponent("p04.pdf")
        p.jobs[3].result = reading(3)
        p.jobs[3].status = .succeeded
        p.outputURLMap[pages[3]] = missingFolder
        p.deferredOutputs[missingFolder] = DeferredOutput(request: p.outputWriteRequest(
            imageURL: pages[3], source: pages[3], outputURL: missingFolder, result: reading(3), model: model,
            runConfig: config))
        await p.materializeDeferredOutputs()
        check("a failed held write maps nothing and fails its row with the reading kept",
              p.outputURLMap[pages[3]] == nil && p.jobs[3].status == .failed
                && p.jobs[3].result?.errorCode == "pdf_write_failed" && p.jobs[3].result?.text == reading(3).text,
              "\(p.jobs[3].result?.errorCode ?? "nil")")
        p.catalogueRunLease = nil
        try? fm.removeItem(at: manifest)
        try? fm.removeItem(at: OCRProcessor.pendingCatalogueURL)

        // 5. A route with no journal before its write still writes at once.
        let eagerOut = root.appendingPathComponent("eager", isDirectory: true)
        try? fm.createDirectory(at: eagerOut, withIntermediateDirectories: true)
        let e = OCRProcessor()
        e.jobs = [OCRJob(sourceURL: pages[0])]
        e.defersOutputWrites = true   // set, but there is no journal: a paid batch's sweep
        _ = await e.handleOCRResult(reading(0), index: 0, jobID: e.jobs[0].id, url: pages[0], model: model,
                                    outputDirectory: eagerOut, runConfig: config)
        check("a write with no journal before it is made at once",
              e.outputURLMap[pages[0]].map { fm.fileExists(atPath: $0.path) } == true && e.deferredOutputs.isEmpty)

        // A retry's own converted page is deleted when the retry returns, so its output is written at once.
        let retryOut = root.appendingPathComponent("retry", isDirectory: true)
        try? fm.createDirectory(at: retryOut, withIntermediateDirectories: true)
        let r = OCRProcessor()
        r.taggingMode = .none
        guard await r.beginCatalogueRun(outputRoot: retryOut, sources: [pages[1]]),
              let retryRun = pendingRun(r, files: [pages[1]], output: retryOut) else {
            finish(results + ["FAIL: the retry's run is set up in scratch"])
            return
        }
        r.activePendingRun = retryRun
        r.jobs = [OCRJob(sourceURL: pages[1])]
        r.defersOutputWrites = true
        let converted = root.appendingPathComponent("retry-page.jpg")
        try? fm.copyItem(at: pages[1], to: converted)
        _ = await r.handleOCRResult(reading(1), index: 0, jobID: r.jobs[0].id, url: converted, model: model,
                                    outputDirectory: retryOut, runConfig: config)
        check("an output read from a short-lived converted page is written at once",
              r.outputURLMap[pages[1]].map { fm.fileExists(atPath: $0.path) } == true && r.deferredOutputs.isEmpty)
        r.catalogueRunLease = nil
        try? fm.removeItem(at: manifest)
        try? fm.removeItem(at: OCRProcessor.pendingCatalogueURL)

        // 6. A resume holds back the outputs it is missing, writes them once and files them.
        let resumeOut = root.appendingPathComponent("resume", isDirectory: true)
        try? fm.createDirectory(at: resumeOut, withIntermediateDirectories: true)
        let builder = OCRProcessor()
        builder.taggingMode = .none
        builder.rotationMode = .off
        let pair = Array(pages[0...1])
        guard await builder.beginCatalogueRun(outputRoot: resumeOut, sources: pair), let resumeCatalogue = builder.catalogueRun,
              pendingRun(builder, files: pair, output: resumeOut, completed: ["0": reading(10), "1": reading(11)],
                         paths: ["0": resumeCatalogue.workingRoot.appendingPathComponent("p01.pdf").path,
                                 "1": resumeCatalogue.workingRoot.appendingPathComponent("p02.pdf").path]) != nil else {
            finish(results + ["FAIL: the interrupted run is set up in scratch"])
            return
        }
        builder.catalogueRunLease = nil
        let resumed = OCRProcessor()
        await resumed.resumeRun(apiKey: "")
        let filed = pair.compactMap { resumed.outputURLMap[$0] }
        let filedText = filed.compactMap { PDFHeaderParser.extract($0)?.fullBody }
        check("a resume writes its missing outputs from the saved readings and files them",
              filed.count == 2 && filed.allSatisfy { OutputFileSafety.hasCatalogueIdentity(at: $0) }
                && filedText.contains { $0.contains("DEFERRED PAGE 10 READING") }
                && filedText.contains { $0.contains("DEFERRED PAGE 11 READING") }
                && resumed.deferredOutputs.isEmpty && OCRProcessor.savedCatalogueRun() == nil
                && !fm.fileExists(atPath: manifest.path),
              "\(filed.map(\.path)) — \(resumed.statusMessage)")

        finish(results)
    }

    private static func makeJPEG(_ url: URL, shade: Double) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let pixels = bitmap.bitmapData else { return false }
        memset(pixels, Int32(shade * 255), bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let data = bitmap.representation(using: .jpeg, properties: [:]) else { return false }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func finish(_ results: [String]) {
        let passed = !results.isEmpty && !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["DEFERRED_OUTPUT_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-deferred-output.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}

#endif
