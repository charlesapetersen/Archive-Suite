#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import Foundation

/// Key-free, no-network contract for W46.post-read-quality-flag: the weighted confidence and its cut, the flag riding
/// on the result through a reclassification and a save, the run's summary and history naming the flagged pages, and
/// Apple Vision leaving a clean page unflagged. Every file is in one temporary directory.
///
/// Run via `scripts/test-read-quality-flag.sh`.
@MainActor
enum ReadQualityFlagTestDriver {
    nonisolated static let envKey = "READQUALITY_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APReadQuality-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. The weighted confidence and the cut.
        typealias F = ReadQualityFlag
        let sure = String(repeating: "a", count: 97), unsure = String(repeating: "b", count: 3)
        check("1 the confidence is weighted by characters",
              abs((F.weightedConfidence([(sure, 1), (unsure, 0.5)]) ?? 0) - 0.985) < 1e-9)
        check("1 no characters, no confidence", F.weightedConfidence([]) == nil && F.weightedConfidence([("", 0.3)]) == nil)
        check("1 the cut is the fitted one", F.flagBelow == 0.9815)
        check("1 a page read with confidence is not flagged", F.assess([(sure, 1), ("cc", 0.5)]) == nil)   // 0.98990
        let flagged = F.assess([(sure, 1), (String(repeating: "d", count: 5), 0.5)])                         // 0.97549
        check("1 a page with more unsure text is flagged", flagged != nil && abs(flagged!.visionConfidence - 0.975490) < 1e-5)
        check("1 just under the cut is flagged, at it is not",
              F.assess([("x", 0.9814)]) != nil && F.assess([("x", 0.9815)]) == nil)

        var fast = VisionOCRSettings.default; fast.usesFastRecognition = true
        var floor = VisionOCRSettings.default; floor.minimumConfidence = 0.5
        var german = VisionOCRSettings.default; german.languages = ["de-DE"]
        check("1 the cut applies under the settings it was fitted with", F.applies(to: .default))
        check("1 and not under fast recognition, a confidence floor or other languages",
              !F.applies(to: fast) && !F.applies(to: floor) && !F.applies(to: german))

        // 2. The flag on the result.
        let read = OCRResult(text: "t", classification: .documentStart, errorMessage: nil, errorCode: nil, readPoorly: flagged)
        check("2 the result carries it", read.readPoorly == flagged)
        check("2 it survives a reclassification and a turn",
              read.with(classification: .documentContinuation, rotationDegrees: 90).readPoorly == flagged)
        check("2 a failed result carries none",
              OCRResult(text: nil, classification: nil, errorMessage: "x", errorCode: "500", readPoorly: flagged).readPoorly == nil)
        let coded = try? JSONDecoder().decode(OCRResult.self, from: JSONEncoder().encode(read))
        check("2 it persists with the run's results", coded?.readPoorly == flagged)
        let legacy = #"{"text":"t","rotationDegrees":0}"#
        check("2 a result saved before it decodes as unflagged",
              (try? JSONDecoder().decode(OCRResult.self, from: Data(legacy.utf8)))?.readPoorly == nil)

        // 3. The run's summary and history.
        check("3 no flagged pages, no clause", OCRProcessor.readPoorlyClause([]).isEmpty)
        check("3 one page is named",
              OCRProcessor.readPoorlyClause(["a.jpg"]) == " 1 page may have read poorly (Apple Vision was unsure); check a.jpg.")
        check("3 past three, the rest are counted",
              OCRProcessor.readPoorlyClause(["a", "b", "c", "d", "e"])
                == " 5 pages may have read poorly (Apple Vision was unsure); check a, b, c and 2 more.")
        let processor = OCRProcessor()
        var good = OCRJob(sourceURL: root.appendingPathComponent("good.jpg"))
        good.result = OCRResult(text: "t", classification: .documentStart, errorMessage: nil, errorCode: nil)
        var poor = OCRJob(sourceURL: root.appendingPathComponent("poor.jpg"))
        poor.result = read
        var unwritten = OCRJob(sourceURL: root.appendingPathComponent("unwritten.jpg"))
        unwritten.result = OCRResult(text: "t", classification: .documentStart, errorMessage: "pdf", errorCode: "pdf_write_failed",
                                     readPoorly: flagged)
        processor.jobs = [good, poor, unwritten]
        check("3 the run names the succeeded flagged page only", processor.readPoorlyNames == ["poor.jpg"])
        check("3 the run summary says so", processor.runDoneMessage(succeeded: 2, failed: 1)
              == "Done. 2 succeeded, 1 failed. 1 page may have read poorly (Apple Vision was unsure); check poor.jpg.")
        let snapshot = RunHistorySnapshot(
            startedAt: Date(), provider: .appleVision, gatewayConfig: nil, localAgent: nil, imageTokenProvider: nil,
            model: LLMModel.appleVisionModels[0], visionTextProvider: nil, visionTextModel: nil, batchMode: false,
            enableTagging: false, enableCollectionSegmentation: false, preOCRedInput: false, reOCRMultiPagePDF: false,
            mixedReOCR: false, sendPreviousImage: false, contextCharCount: 0, imageScale: 1, rotationMode: .agreement,
            fileCount: 3)
        check("3 the history counts them", snapshot.makeRun(succeeded: 3, readPoorly: 2).readPoorlyPages == 2)
        check("3 a run with none records none", snapshot.makeRun(succeeded: 3).readPoorlyPages == nil)

        // 4. Apple Vision on a clean page: read, and not flagged.
        if let page = makePage(at: root.appendingPathComponent("clean.jpg")) {
            let r = try? await VisionClient(settings: .default).ocr(imageURL: page)
            check("4 Vision reads the clean page", (r?.text?.count ?? 0) > 200)
            check("4 and does not flag it", r != nil && r?.readPoorly == nil)
        } else {
            check("4 the clean page was drawn", false)
        }

        finish(results)
    }

    /// A page of dark text lines on white, upright.
    private static func makePage(at url: URL) -> URL? {
        let size = NSSize(width: 850, height: 1100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
        for line in 0..<30 {
            ("The committee met on the fourth of March to consider the report, line \(line)." as NSString)
                .draw(at: NSPoint(x: 60, y: 1040 - CGFloat(line) * 33), withAttributes: attrs)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func finish(_ results: [String]) {
        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["READQUALITY_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-read-quality.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
#endif
