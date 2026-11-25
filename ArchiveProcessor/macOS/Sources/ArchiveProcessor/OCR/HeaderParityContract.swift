#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import ArchiveCore
import Foundation
import PDFKit

/// Key-free, no-network contract for W49.proc-catalogue-cutover: Process Files and Live Capture write the same page-2
/// provenance header for the same pages. Each case stages the pages the way Live Capture's Finish does
/// (`LiveCaptureProcessor._recoveryTestStageSegment`, the real `writeSegmentFiles`) and writes them the way a Process
/// Files run of the same phone grouping does (`applyPreGroupedClassifications`, `outputWriteRequest`, `writeOutput`),
/// then compares the parsed headers field by field. Synthetic JPEGs in a temporary directory; nothing else is read or
/// written.
///
/// Run via `scripts/test-header-parity.sh`.
@MainActor
enum HeaderParityContract {
    nonisolated static let envKey = "HEADER_PARITY_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APHeaderParity-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        var results: [String] = []
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)\(condition || detail.isEmpty ? "" : " — \(detail)")")
        }
        let model = LLMModel.appleVisionModels[0]
        var config = SessionProcessingConfig.fromProcessFilesRunStart()
        config.gateway = nil
        config.localAgent = nil

        let cases: [(name: String, type: CaptureGroupType, pages: Int, reader: DocumentClassification?,
                     expected: [String])] = [
            ("a two-page document", .document, 2, nil, ["Document Start", "Continuation"]),
            ("a box photo", .box, 1, nil, ["Box"]),
            ("a folder photo", .folder, 1, nil, ["Folder"]),
            // The reader's own guess disagrees with the phone's grouping: the grouping is what page 2 says.
            ("a box photo the reader called a document", .box, 1, .documentStart, ["Box"]),
            ("a document whose pages the reader called starts", .document, 2, .documentStart,
             ["Document Start", "Continuation"]),
        ]
        for (caseIndex, item) in cases.enumerated() {
            let dir = root.appendingPathComponent("case\(caseIndex)", isDirectory: true)
            let sources = (0..<item.pages).map { dir.appendingPathComponent(String(format: "IMG_%04d.jpg", 9000 + $0)) }
            guard sources.enumerated().allSatisfy({ makeJPEG($1, shade: 0.3 + 0.2 * Double($0)) }) else {
                check("\(item.name): fixture JPEGs", false)
                continue
            }
            let staging = dir.appendingPathComponent("live", isDirectory: true)
            let processed = dir.appendingPathComponent("process-files", isDirectory: true)
            try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try? fm.createDirectory(at: processed, withIntermediateDirectories: true)

            let live = LiveCaptureProcessor._recoveryTestStageSegment(sources: sources, stagingDir: staging, model: model,
                                                                      type: item.type, taggingMode: TaggingMode.none,
                                                                      readerClassification: item.reader)
            let processor = OCRProcessor()
            processor.jobs = sources.map { source in
                var job = OCRJob(sourceURL: source)
                job.result = OCRResult(text: "text", classification: item.reader, errorMessage: nil, errorCode: nil)
                return job
            }
            processor.preGroupedTypes = Array(repeating: item.type, count: sources.count)
            processor.preGroupedBoundaries = sources.indices.map { $0 == 0 }
            processor.applyPreGroupedClassifications(files: sources)
            var written: [URL] = []
            for (index, source) in sources.enumerated() {
                guard let result = processor.jobs[index].result else { continue }
                let output = processed.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")
                let request = processor.outputWriteRequest(imageURL: source, source: source, outputURL: output,
                                                           result: result, model: model, runConfig: config)
                if OCRProcessor.writeOutput(request).success { written.append(output) }
            }

            let liveHeaders = live.pdfURLs.map(header(of:))
            let processHeaders = written.map(header(of:))
            check("\(item.name): both routes wrote every page",
                  liveHeaders.count == item.pages && processHeaders.count == item.pages,
                  "live \(liveHeaders.count), Process Files \(processHeaders.count)")
            check("\(item.name): Live Capture names the settled class on page 2",
                  liveHeaders.map { $0?.classification } == item.expected.map(Optional.some),
                  "\(liveHeaders.map { $0?.classification ?? "none" })")
            for (index, pair) in zip(liveHeaders, processHeaders).enumerated() {
                let (liveHeader, processHeader) = pair
                check("\(item.name), page \(index + 1): the page-2 headers are identical",
                      liveHeader != nil && liveHeader == processHeader,
                      "live \(String(describing: liveHeader)) / Process Files \(String(describing: processHeader))")
            }
        }
        finish(results)
    }

    /// The parsed header of the file's first text (or searchable) page.
    private static func header(of pdf: URL) -> PDFPageHeader? {
        guard let doc = PDFDocument(url: pdf) else { return nil }
        return PDFHeaderParser.textPageHeaders(doc).compactMap { $0 }.first
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
        let output = ProcessInfo.processInfo.environment["HEADER_PARITY_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-header-parity.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}

#endif
