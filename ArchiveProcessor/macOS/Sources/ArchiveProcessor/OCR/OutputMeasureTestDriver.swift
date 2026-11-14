#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import ArchiveCore
import Foundation
import PDFKit

/// Headless, $0 measurement of the output forms on a smoke set (W42.int-s5 step 7), gated by `OUTPUT_MEASURE=1` (does
/// nothing in normal use). Run by `scripts/measure-output.sh`. Each image in `OUTPUT_MEASURE_IN` (a scratch copy, never
/// the corpus), and the self-test's drawn memo page, is read by Apple Vision through the app's own client and written
/// three ways: image-plus-text with the layer and straightening (the default), with the layer and no straightening, and
/// with no layer (the output before W42.int-s5). Each is read back through PDFKit (two pages, the text page's first
/// line, text on the image page where it was placed), gets Finder tags written and read back, and the default outputs
/// are merged into one document whose pages are checked in order. Writes into `OUTPUT_MEASURE_OUT` only.
@MainActor
enum OutputMeasureTestDriver {
    private static var didRun = false
    private static var lines: [String] = []
    private static var failures = 0

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard !didRun, env["OUTPUT_MEASURE"] == "1", let input = env["OUTPUT_MEASURE_IN"],
              let output = env["OUTPUT_MEASURE_OUT"], let report = env["OUTPUT_MEASURE_REPORT"] else { return }
        didRun = true
        Task { @MainActor in
            await run(input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output))
            lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: report, atomically: true, encoding: .utf8)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else { failures += 1; lines.append("FAIL \(name) \(detail())") }
    }

    private static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    static func run(input: URL, output: URL) async {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: output, withIntermediateDirectories: true)) != nil else {
            check("output folder", false); return
        }
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff"]
        var inputs = ((try? fm.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if let memo = TextLayerTestDriver.drawPage(TextLayerTestDriver.memo,
                                                   to: output.appendingPathComponent("smoke-memo.jpg"), type: "public.jpeg") {
            inputs.insert(memo, at: 0)
        }
        let model = LLMModel.appleVisionModels[0]
        let forms: [(name: String, options: PDFGenerator.TextLayerOptions?)] = [
            ("layer", .standard), ("layer-unstraightened", .init(placeHandOnImage: true, straighten: false)), ("plain", nil),
        ]
        lines.append("MEASURE\tinput\tform\tbytes\tseconds\tlayer\tlines\tstraightened\tinput bytes")
        var merged: [URL] = []
        for image in inputs {
            let name = image.deletingPathExtension().lastPathComponent
            guard let result = try? await VisionClient(settings: .default).ocr(imageURL: image), result.text?.isEmpty == false else {
                check("\(name) read by Vision", false); continue
            }
            for form in forms {
                let out = output.appendingPathComponent("\(name).\(form.name).pdf")
                let start = Date()
                let written = await Task.detached { () -> PDFGenerator.Output? in
                    try? PDFGenerator().generateOutput(imageURL: image, result: result, model: model, outputURL: out,
                                                       originalFileName: image.lastPathComponent, pdfImageMB: 2.0,
                                                       textLayer: form.options)
                }.value
                let seconds = Date().timeIntervalSince(start)
                guard let written, let doc = PDFDocument(url: out) else { check("\(name) \(form.name) written", false); continue }
                lines.append("MEASURE\t\(name)\t\(form.name)\t\(size(out))\t\(String(format: "%.1f", seconds))\t"
                             + "\(written.layer.route.rawValue)\t\(written.layer.lines)\t"
                             + "\(written.straightenedDegrees.map { String(format: "%.1f", $0) } ?? "-")\t\(size(image))")
                check("\(name) \(form.name): two pages, the text page second", doc.pageCount == 2
                      && doc.page(at: 1)?.string?.hasPrefix("Extracted text.") == true)
                let imageText = (doc.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let placed = written.layer.route != .textPage
                check("\(name) \(form.name): the image page's text is selectable where placed", placed == !imageText.isEmpty,
                      "placed \(placed), \(imageText.count) characters")
                // Finder tags on the output, written as the app writes them and read back from a fresh URL.
                let tagged = (try? CoordinatedTagWriter.write(out) { tags, color in (tags + ["Measure", "1958"], color) }) != nil
                let back = (try? URL(fileURLWithPath: out.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
                check("\(name) \(form.name): Finder tags present", tagged && back.contains("Measure") && back.contains("1958"),
                      "\(back)")
                if form.name == "layer" { merged.append(out) }
            }
        }
        // The default outputs merged into one document: every pair, in order, each text page where it was.
        let document = output.appendingPathComponent("merged.layer.pdf")
        do {
            try PDFGenerator().mergeDocumentPDFs(sourcePDFs: merged, outputURL: document)
            let doc = PDFDocument(url: document)
            let inOrder = merged.enumerated().allSatisfy { i, url in
                PDFDocument(url: url)?.page(at: 1)?.string == doc?.page(at: 2 * i + 1)?.string
                    && PDFDocument(url: url)?.page(at: 0)?.string == doc?.page(at: 2 * i)?.string
            }
            check("merged: every page, each pair in order", doc?.pageCount == 2 * merged.count && inOrder)
            lines.append("MEASURE\tmerged\tlayer\t\(size(document))\t-\t-\t-\t-\t\(merged.map(size).reduce(0, +))")
        } catch { check("merged written", false, "\(error)") }
    }
}
#endif
