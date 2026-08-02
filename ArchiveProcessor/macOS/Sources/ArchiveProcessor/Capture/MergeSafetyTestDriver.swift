import Foundation
import CoreGraphics

/// Headless, key-free test of merged-document tag-transfer safety, gated by `MERGESAFETY_TEST=1`.
/// Uses only generated one-page PDFs in a temporary directory and an injected tag writer; it never
/// opens or modifies the archive corpus or Finder metadata.
@MainActor
enum MergeSafetyTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["MERGESAFETY_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "APMergeSafety-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }
        func writePDF(_ url: URL) -> Bool {
            var mediaBox = CGRect(x: 0, y: 0, width: 72, height: 72)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return false }
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
            return fm.fileExists(atPath: url.path)
        }
        func configuredProcessor(in directory: URL, tags: [String] = ["Subject"])
            -> (OCRProcessor, URL, URL, URL, URL) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let source1 = directory.appendingPathComponent("source-1.jpg")
            let source2 = directory.appendingPathComponent("source-2.jpg")
            let pdf1 = directory.appendingPathComponent("page-1.pdf")
            let pdf2 = directory.appendingPathComponent("page-2.pdf")
            _ = writePDF(pdf1); _ = writePDF(pdf2)
            let processor = OCRProcessor()
            var job1 = OCRJob(sourceURL: source1)
            job1.appliedTags = tags
            processor.jobs = [job1, OCRJob(sourceURL: source2)]
            processor.segments = [DocumentSegment(pdfURLs: [source1, source2])]
            processor.outputURLMap = [source1: pdf1, source2: pdf2]
            return (processor, source1, source2, pdf1, pdf2)
        }

        let failureDir = root.appendingPathComponent("failure", isDirectory: true)
        let (failedProcessor, failedSource1, failedSource2, failedPDF1, failedPDF2) = configuredProcessor(in: failureDir)
        var failedWriterSawSources = false
        var failedMergedURL: URL?
        failedProcessor.performDocumentMerging(files: [failedSource1, failedSource2], outputDirectory: failureDir) {
            _, mergedURL, _, _ in
            failedMergedURL = mergedURL
            failedWriterSawSources = fm.fileExists(atPath: failedPDF1.path)
                && fm.fileExists(atPath: failedPDF2.path)
                && fm.fileExists(atPath: mergedURL.path)
            throw NSError(domain: "MergeSafetyTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "injected tag verification failure"])
        }
        check("failed tag writer runs while every component is present", failedWriterSawSources)
        check("failed tag transfer preserves every component PDF",
              fm.fileExists(atPath: failedPDF1.path) && fm.fileExists(atPath: failedPDF2.path))
        check("failed tag transfer preserves original output mappings",
              failedProcessor.outputURLMap[failedSource1] == failedPDF1
              && failedProcessor.outputURLMap[failedSource2] == failedPDF2)
        check("failed tag transfer preserves the merged recovery copy",
              failedMergedURL.map { fm.fileExists(atPath: $0.path) } == true)
        check("failed tag transfer is reported", failedProcessor.statusMessage.contains("Failed to merge"))

        let successDir = root.appendingPathComponent("success", isDirectory: true)
        let (successProcessor, successSource1, successSource2, successPDF1, successPDF2) = configuredProcessor(in: successDir)
        var successWriterSawSources = false
        successProcessor.performDocumentMerging(files: [successSource1, successSource2], outputDirectory: successDir) {
            _, _, _, _ in
            successWriterSawSources = fm.fileExists(atPath: successPDF1.path)
                && fm.fileExists(atPath: successPDF2.path)
        }
        let merged1 = successProcessor.outputURLMap[successSource1]
        let merged2 = successProcessor.outputURLMap[successSource2]
        check("successful tag writer runs before component cleanup", successWriterSawSources)
        check("successful tag transfer retires component PDFs",
              !fm.fileExists(atPath: successPDF1.path) && !fm.fileExists(atPath: successPDF2.path))
        check("successful merge maps every source to one durable PDF",
              merged1 == merged2 && merged1.map { fm.fileExists(atPath: $0.path) } == true)

        // An otherwise-empty generated tag set still carries the adapter's implicit Unread tag.
        // W16.cfg4: stamping is driven by the RUN'S `taggingMode` — `performDocumentMerging` reads
        // `taggingMode.stampsUnread`. Setting the mode on this processor is the WHOLE input; W16.cfg6-fu
        // deleted the redundant `MacOSTagger.stampUnread` assignment that used to sit here.
        let stampedDir = root.appendingPathComponent("empty-stamped", isDirectory: true)
        let (stampedProcessor, stampedSource1, stampedSource2, stampedPDF1, stampedPDF2) =
            configuredProcessor(in: stampedDir, tags: [])
        stampedProcessor.taggingMode = .automatic   // a real-tagging mode → stampsUnread == true
        var stampedWriterCalled = false
        stampedProcessor.performDocumentMerging(files: [stampedSource1, stampedSource2], outputDirectory: stampedDir) {
            tags, _, _, _ in
            stampedWriterCalled = tags.isEmpty
                && fm.fileExists(atPath: stampedPDF1.path)
                && fm.fileExists(atPath: stampedPDF2.path)
        }
        check("empty real-tag set still invokes writer for implicit Unread", stampedWriterCalled)
        check("empty stamped merge retires components only after writer success",
              !fm.fileExists(atPath: stampedPDF1.path) && !fm.fileExists(atPath: stampedPDF2.path))

        // With stamping disabled and no explicit tags, no metadata transfer is required.
        // `configuredProcessor` builds a fresh OCRProcessor whose `taggingMode` DEFAULTS to `.automatic`
        // (stampsUnread == true), so setting the mode explicitly is REQUIRED here — without it this case
        // would read `true` and the "skips unnecessary tag writer" assertion below would flip.
        let plainDir = root.appendingPathComponent("empty-plain", isDirectory: true)
        let (plainProcessor, plainSource1, plainSource2, plainPDF1, plainPDF2) =
            configuredProcessor(in: plainDir, tags: [])
        plainProcessor.taggingMode = .none          // not a real-tagging mode → stampsUnread == false
        var plainWriterCalled = false
        plainProcessor.performDocumentMerging(files: [plainSource1, plainSource2], outputDirectory: plainDir) {
            _, _, _, _ in plainWriterCalled = true
        }
        check("empty non-stamping merge skips unnecessary tag writer", !plainWriterCalled)
        check("empty non-stamping merge still completes",
              !fm.fileExists(atPath: plainPDF1.path) && !fm.fileExists(atPath: plainPDF2.path))

        // A JSON-only collision must advance the PDF and sidecar together before component cleanup.
        let jsonDir = root.appendingPathComponent("json-collision", isDirectory: true)
        let (jsonProcessor, jsonSource1, jsonSource2, jsonPDF1, jsonPDF2) = configuredProcessor(in: jsonDir)
        let existingJSON = jsonDir.appendingPathComponent("page-1_merged.json")
        let sourceJSON = jsonDir.appendingPathComponent("page-1.json")
        try? Data("KEEP".utf8).write(to: existingJSON)
        try? Data("NEW".utf8).write(to: sourceJSON)
        jsonProcessor.performDocumentMerging(files: [jsonSource1, jsonSource2], outputDirectory: jsonDir) {
            _, _, _, _ in
        }
        let collisionMerged = jsonProcessor.outputURLMap[jsonSource1]
        let collisionJSON = collisionMerged?.deletingPathExtension().appendingPathExtension("json")
        check("JSON-only collision preserves the prior-run sidecar",
              (try? String(contentsOf: existingJSON, encoding: .utf8)) == "KEEP")
        check("JSON-only collision advances merged PDF and new sidecar together",
              collisionMerged?.lastPathComponent == "page-1_merged (2).pdf"
              && collisionMerged == jsonProcessor.outputURLMap[jsonSource2]
              && collisionJSON.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "NEW")
        check("JSON sidecar is durable before component retirement",
              !fm.fileExists(atPath: sourceJSON.path)
              && !fm.fileExists(atPath: jsonPDF1.path)
              && !fm.fileExists(atPath: jsonPDF2.path))

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["MERGESAFETY_TEST_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("archiveprocessor-merge-safety-result.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
    }
}
