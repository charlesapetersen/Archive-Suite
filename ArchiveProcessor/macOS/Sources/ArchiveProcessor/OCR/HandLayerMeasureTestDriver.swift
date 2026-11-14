#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import ArchiveCore
import Foundation
import PDFKit
import VisionOCRKit

/// Headless, $0 measurement of the hand placer in the app (W42.int-s5-hands), gated by `HAND_MEASURE=1` (does nothing in
/// normal use). Run by `scripts/measure-hands.sh`. When `HAND_MEASURE_INSTALL=1` the placer is first downloaded through
/// the app's own path (`HandPlacerDownload`, so the size and hash check run) from `VISIONOCR_MODEL_SOURCE` into
/// `VISIONOCR_MODEL_HOME`. Then each image in `HAND_MEASURE_IN` (a scratch copy, never the corpus) is written as a
/// handwritten page through `PDFGenerator`, its reading the `<name>.txt` beside it when there is one, else Apple Vision's,
/// and read back through PDFKit: two pages with the text page second, a layer on the image page exactly when the page
/// passed the 0.67 gate, every word on the image page one of the reading's, and the time and memory of each page.
/// Writes into `HAND_MEASURE_OUT` only.
@MainActor
enum HandLayerMeasureTestDriver {
    /// The share of the image page's layer lines, as PDFKit selects them, whose centre falls on a line Apple Vision
    /// finds on the page as rendered (its box grown by half its height each way). Page space throughout, so it does
    /// not depend on where the image sits on the page.
    static func onInk(_ page: PDFPage) async -> Double {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, let text = page.string else { return 0 }
        var centres: [CGPoint] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { sub, range, _, _ in
            guard let sub, !sub.trimmingCharacters(in: .whitespaces).isEmpty,
                  let b = page.selection(for: range)?.bounds(for: page), b.width > 0 else { return }
            centres.append(CGPoint(x: (b.midX - bounds.minX) / bounds.width, y: 1 - (b.midY - bounds.minY) / bounds.height))
        }
        let scale = 2400 / max(bounds.width, bounds.height)
        let thumb = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard !centres.isEmpty, let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let boxes = await Task.detached { TextLayer.visionLines(of: cg)?.lines.map(\.box) ?? [] }.value
        let hits = centres.filter { c in boxes.contains { $0.insetBy(dx: -$0.height / 2, dy: -$0.height / 2).contains(c) } }
        return Double(hits.count) / Double(centres.count)
    }

    private static var didRun = false
    private static var lines: [String] = []
    private static var failures = 0

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard !didRun, env["HAND_MEASURE"] == "1", let input = env["HAND_MEASURE_IN"],
              let output = env["HAND_MEASURE_OUT"], let report = env["HAND_MEASURE_REPORT"] else { return }
        didRun = true
        Task { @MainActor in
            await run(input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output),
                      install: env["HAND_MEASURE_INSTALL"] == "1")
            lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: report, atomically: true, encoding: .utf8)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else { failures += 1; lines.append("FAIL \(name) \(detail())") }
    }

    static func run(input: URL, output: URL, install: Bool) async {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: output, withIntermediateDirectories: true)) != nil else {
            check("output folder", false); return
        }
        if install {
            let download = HandPlacerDownload()
            let start = Date()
            download.start()
            while case .fetching = download.state { try? await Task.sleep(nanoseconds: 200_000_000) }
            check("the placer downloads, checked and installed whole", download.state == .installed && HandPlacer.isInstalled(),
                  "\(download.state)")
            lines.append(String(format: "INSTALL\t%.1f s", Date().timeIntervalSince(start)))
        }
        check("the placer is installed", HandPlacer.isInstalled())
        check("the sheet no longer offers the download once installed",
              SettingsSheetModel.switchPending.isEmpty && HandPlacerDownload().state == .installed)
        let exts: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]
        let inputs = ((try? fm.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let model = LLMModel.appleVisionModels[0]
        lines.append("HAND\tinput\treading\troute\tconfidence\tlines\tseconds\tpeak MB\twords on image\treading words found")
        var placed = 0, gated = 0
        var onInkShares: [Double] = []
        for image in inputs {
            let name = image.deletingPathExtension().lastPathComponent
            let readingFile = image.deletingPathExtension().appendingPathExtension("txt")
            let source: String
            let result: OCRResult
            if let text = try? String(contentsOf: readingFile, encoding: .utf8), !text.isEmpty {
                result = OCRResult(text: text, classification: nil, rotationDegrees: 0, errorMessage: nil, errorCode: nil)
                source = "own"
            } else if let read = try? await VisionClient(settings: .default).ocr(imageURL: image), read.text?.isEmpty == false {
                result = read
                source = "vision"
            } else { check("\(name) read", false); continue }
            let out = output.appendingPathComponent("\(name).hand.pdf")
            let start = Date()
            let written = await Task.detached { () -> PDFGenerator.Output? in
                try? PDFGenerator().generateOutput(imageURL: image, result: result, model: model, outputURL: out,
                                                   originalFileName: image.lastPathComponent, pdfImageMB: 2.0,
                                                   pageKind: .handwritten, textLayer: .standard)
            }.value
            let seconds = Date().timeIntervalSince(start)
            guard let written, let doc = PDFDocument(url: out) else { check("\(name) written", false); continue }
            let layer = written.layer
            let imageText = doc.page(at: 0)?.string ?? ""
            let reading = result.text ?? ""
            func words(_ s: String) -> [String] { s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
            let onImage = words(imageText), readingWords = words(reading)
            // The reading's words the image page holds (Find), as the searchable form counts them.
            let found = readingWords.isEmpty ? 0
                : 1 - Double(OutputForm.missingWords(imageText, reading).count) / Double(readingWords.count)
            lines.append("HAND\t\(name)\t\(source)\t\(layer.route.rawValue)\t"
                         + "\(layer.handConfidence.map { String(format: "%.3f", $0) } ?? "-")\t\(layer.lines)\t"
                         + String(format: "%.1f", seconds) + "\t\(layer.handPeakMB.map(String.init) ?? "-")\t"
                         + "\(onImage.count)\t" + String(format: "%.2f", found)
                         + (layer.reason.map { "\t\($0)" } ?? ""))
            check("\(name): two pages, the text page second", doc.pageCount == 2
                  && doc.page(at: 1)?.string?.hasPrefix("Extracted text.") == true)
            check("\(name): the placer ran", layer.handConfidence != nil, layer.reason ?? "")
            let passes = (layer.handConfidence ?? 0) >= HandPlacer.gate
            check("\(name): a layer exactly when the page passed the gate",
                  passes == (layer.route == .handBllaCtc) && (layer.route == .handBllaCtc) == !onImage.isEmpty,
                  "\(layer.route.rawValue) \(layer.handConfidence ?? -1) \(onImage.count) words")
            // The writer joins a word broken by a hyphen at a line end (`SearchableWriter.compose`), so its whole form counts.
            let joined = reading + "\n" + reading.replacingOccurrences(of: #"-[ \t]*\n[ \t]*"#, with: "", options: .regularExpression)
            check("\(name): every word on the image page is the reading's", OutputForm.holds(joined, every: imageText),
                  "\(OutputForm.missingWords(joined, imageText).prefix(8))")
            if layer.route == .handBllaCtc, let page = doc.page(at: 0) {
                placed += 1
                let share = await onInk(page)
                onInkShares.append(share)
                lines.append("GEOMETRY\t\(name)\t" + String(format: "%.2f", share))
            } else if layer.handConfidence != nil { gated += 1 }
        }
        lines.append("HAND\tsummary\t\(inputs.count) pages\t\(placed) placed\t\(gated) to the text page by the gate")
        // Where the layer sits: a layer drawn in the wrong frame (flipped, shifted, the image frame ignored) would pass
        // every check above. Vision's own lines on the rendered page are the reference; it misses some handwriting.
        let mean = onInkShares.isEmpty ? 0 : onInkShares.reduce(0, +) / Double(onInkShares.count)
        check("the placed layers sit on the written lines (mean share on Vision's lines at least 0.6)",
              !onInkShares.isEmpty && mean >= 0.6, String(format: "%.2f over %d pages", mean, onInkShares.count))
    }
}
#endif
