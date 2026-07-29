import Foundation
import CoreGraphics
import CoreText
import PDFKit

/// Headless, key-free ($0) functional test of the "re-OCR multi-page PDF" mode, gated by
/// `MULTIPAGE_REOCR_TEST=1`. Builds synthetic multi-page PDFs in a temporary directory and injects a
/// fake per-page OCR result (no network), then asserts that the rebuilt output PDF alternates
/// image / OCR-text pages in page order, that the text lands on the right pages, and — the file-safety
/// invariant — that the input PDF is never overwritten even when the output directory coincides with it.
/// It never opens or modifies the archive corpus or any Finder metadata.
@MainActor
enum MultiPageReOCRTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["MULTIPAGE_REOCR_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    /// Hands out sequential page indices so the injected OCR returns deterministic per-page text
    /// (pages are OCR'd strictly in order within one document).
    private actor PageIndexer {
        private var i = 0
        func next() -> Int { defer { i += 1 }; return i }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "APMultiPageReOCR-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }

        // A multi-page source PDF with a visible label per page (so each rendered page image is real).
        func writeMultiPagePDF(_ url: URL, pages: Int) -> Bool {
            var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return false }
            for p in 0..<pages {
                ctx.beginPDFPage(nil)
                ctx.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
                ctx.fill(CGRect(x: 10, y: 10, width: 280, height: 380))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                let attr = NSAttributedString(string: "SOURCE PAGE \(p + 1)", attributes: [.font: font])
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: 40, y: 200)
                CTLineDraw(line, ctx)
                ctx.endPDFPage()
            }
            ctx.closePDF()
            return fm.fileExists(atPath: url.path)
        }
        func isDecodableImage(_ url: URL) -> Bool {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            return CGImageSourceGetCount(src) > 0
        }
        func makeInjectedOCR() -> @Sendable (URL) async -> OCRResult {
            let indexer = PageIndexer()
            return { _ in
                let idx = await indexer.next()
                return OCRResult(text: "OCRPAGE\(idx)", classification: nil, errorMessage: nil, errorCode: nil)
            }
        }
        // Deterministic PDF output for the assembly path (no image re-encode size games in a synthetic test).
        OCRProcessor.pdfImageMB = 0
        OCRProcessor.textColumns = 1

        // ── 1. renderAllPages: count + per-page decodability, and nil on a non-PDF. ─────────────────
        let renderDir = root.appendingPathComponent("render", isDirectory: true)
        try? fm.createDirectory(at: renderDir, withIntermediateDirectories: true)
        let threePage = renderDir.appendingPathComponent("three.pdf")
        _ = writeMultiPagePDF(threePage, pages: 3)
        let rendered = PDFToImageConverter.renderAllPages(of: threePage)
        check("renderAllPages returns one image per page", rendered?.count == 3)
        check("renderAllPages images are all decodable", (rendered ?? []).allSatisfy(isDecodableImage))
        let bogus = renderDir.appendingPathComponent("not-a.pdf")
        try? Data("not a pdf".utf8).write(to: bogus)
        check("renderAllPages returns nil for a non-PDF", PDFToImageConverter.renderAllPages(of: bogus) == nil)
        for u in rendered ?? [] { try? fm.removeItem(at: u) }

        // ── 1b. Auto-route detection: a MULTI-page PDF drops to re-OCR; a single-page PDF, an image,
        //        and (unreadable) non-PDFs do not. `preOCRedInput` (the tagging pipeline) wins when on.
        //        This mirrors the pipeline's `autoReOCR = !preOCRedInput && files.contains(isMultiPagePDF)`
        //        so the routing is asserted at $0 without a live OCR run. ─────────────────────────────
        let singlePage = renderDir.appendingPathComponent("one.pdf")
        _ = writeMultiPagePDF(singlePage, pages: 1)
        let imageInput = PDFToImageConverter.imageURL(for: singlePage)   // a real .jpg temp
        check("isMultiPagePDF: true for a 3-page PDF", PDFToImageConverter.isMultiPagePDF(threePage))
        check("isMultiPagePDF: false for a 1-page PDF", !PDFToImageConverter.isMultiPagePDF(singlePage))
        check("isMultiPagePDF: false for an image file", !PDFToImageConverter.isMultiPagePDF(imageInput))
        check("isMultiPagePDF: false for an unreadable .pdf", !PDFToImageConverter.isMultiPagePDF(bogus))
        func autoReOCR(_ files: [URL], preOCRed: Bool) -> Bool {
            !preOCRed && files.contains(where: PDFToImageConverter.isMultiPagePDF)
        }
        check("auto-route: multi-page PDF → re-OCR", autoReOCR([threePage], preOCRed: false))
        check("auto-route: single-page PDF → standard (not re-OCR)", !autoReOCR([singlePage], preOCRed: false))
        check("auto-route: image → standard (not re-OCR)", !autoReOCR([imageInput], preOCRed: false))
        check("auto-route: preOCRedInput wins over a multi-page PDF", !autoReOCR([threePage], preOCRed: true))
        check("auto-route: a multi-page PDF anywhere in a mixed drop still routes to re-OCR",
              autoReOCR([imageInput, threePage], preOCRed: false))
        try? fm.removeItem(at: imageInput)

        // ── 2. Full pipeline: 3-page PDF → 6-page alternating image/OCR-text PDF, text on odd pages. ─
        let runDir = root.appendingPathComponent("run", isDirectory: true)
        let outDir = root.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: runDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let src = runDir.appendingPathComponent("doc.pdf")
        _ = writeMultiPagePDF(src, pages: 3)

        let processor = OCRProcessor()
        processor.jobs = [OCRJob(sourceURL: src)]
        let model = LLMModel.geminiModels[0]   // only feeds the text-page subheader; OCR is injected
        await processor.performMultiPagePDFReOCR(
            files: [src], provider: .gemini, model: model, thinkingLevel: nil,
            apiKey: "", outputDirectory: outDir, ocrOverride: makeInjectedOCR())

        let outURL = processor.outputURLMap[src]
        check("output PDF mapped and on disk",
              outURL.map { fm.fileExists(atPath: $0.path) } == true)
        check("job marked succeeded", processor.jobs.first?.status == .succeeded)
        let outDoc = outURL.flatMap { PDFDocument(url: $0) }
        check("output PDF has 2× the source page count (image+text per page)", outDoc?.pageCount == 6)
        func pageText(_ i: Int) -> String { outDoc?.page(at: i)?.string ?? "" }
        check("text pages carry each page's OCR text in order",
              pageText(1).contains("OCRPAGE0") && pageText(3).contains("OCRPAGE1") && pageText(5).contains("OCRPAGE2"))
        check("image pages carry no OCR-text marker (proves alternation)",
              !pageText(0).contains("OCRPAGE") && !pageText(2).contains("OCRPAGE") && !pageText(4).contains("OCRPAGE"))

        // ── 3. File-safety: output must NOT overwrite the input when the dir coincides. ─────────────
        let sameDir = root.appendingPathComponent("same", isDirectory: true)
        try? fm.createDirectory(at: sameDir, withIntermediateDirectories: true)
        let inplace = sameDir.appendingPathComponent("doc.pdf")
        _ = writeMultiPagePDF(inplace, pages: 2)               // 2-page ORIGINAL
        let inplaceProc = OCRProcessor()
        inplaceProc.jobs = [OCRJob(sourceURL: inplace)]
        await inplaceProc.performMultiPagePDFReOCR(
            files: [inplace], provider: .gemini, model: model, thinkingLevel: nil,
            apiKey: "", outputDirectory: sameDir, ocrOverride: makeInjectedOCR())
        let inplaceOut = inplaceProc.outputURLMap[inplace]
        check("output reserved a non-colliding name (doc (2).pdf), not the input's",
              inplaceOut?.lastPathComponent == "doc (2).pdf")
        check("original input PDF still exists, untouched (still 2 pages)",
              fm.fileExists(atPath: inplace.path) && PDFDocument(url: inplace)?.pageCount == 2)
        check("re-OCR output is the 4-page alternating rebuild (2 pages × 2)",
              inplaceOut.flatMap { PDFDocument(url: $0)?.pageCount } == 4)

        // ── 4. MIXED DROP: a non-PDF sibling must fail *loudly*, not silently. ──────────────────────
        // Regression for the 2026-07-29 bug: an owner dropped two .jpg files alongside one 3-page PDF.
        // Because `autoReOCR` is presence-based (section 1, checks at 107-108), the whole run took this
        // PDF-only route, `renderAllPages` returned nil for each JPEG, and the guard marked them .failed
        // WITHOUT setting `result` — so the UI rendered "No OCR text" (blaming the model) and no output was
        // written. The route's own comment claimed such a sibling "fails render loudly"; it did not.
        // These checks pin the reason being attached. NOTE: the ROUTING itself is unchanged and still skips
        // non-PDFs — the per-file partition is a separate, owner-gated follow-up (it changes tagging
        // semantics for a mixed run). What is fixed here is that the skip can no longer be silent.
        let mixDir = root.appendingPathComponent("mixed", isDirectory: true)
        let mixOut = root.appendingPathComponent("mixedout", isDirectory: true)
        try? fm.createDirectory(at: mixDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: mixOut, withIntermediateDirectories: true)
        let mixPDF = mixDir.appendingPathComponent("doc.pdf")
        _ = writeMultiPagePDF(mixPDF, pages: 2)
        // A genuine .jpg, via the same idiom section 1 uses: render a 1-page PDF's page to a real JPEG.
        // (`mixSingle` is only the source for that render — it is NOT one of the run's inputs.)
        let mixSingle = mixDir.appendingPathComponent("single.pdf")
        _ = writeMultiPagePDF(mixSingle, pages: 1)
        let mixIMG = PDFToImageConverter.imageURL(for: mixSingle)

        let mixProc = OCRProcessor()
        // Job order deliberately puts the IMAGE first, so an index-mapping regression (jobs[index] vs the
        // files array) would show up as the wrong job being marked.
        mixProc.jobs = [OCRJob(sourceURL: mixIMG), OCRJob(sourceURL: mixPDF)]
        await mixProc.performMultiPagePDFReOCR(
            files: [mixIMG, mixPDF], provider: .gemini, model: model, thinkingLevel: nil,
            apiKey: "", outputDirectory: mixOut, ocrOverride: makeInjectedOCR())

        let imgJob = mixProc.jobs.first { $0.sourceURL == mixIMG }
        let pdfJob = mixProc.jobs.first { $0.sourceURL == mixPDF }
        check("mixed: the non-PDF sibling is marked failed", imgJob?.status == .failed)
        check("mixed: the non-PDF sibling now carries an errorMessage (was nil → 'No OCR text')",
              imgJob?.result?.errorMessage?.isEmpty == false)
        check("mixed: its errorCode identifies the ROUTING skip, not an OCR/model fault",
              imgJob?.result?.errorCode == "not_a_pdf_in_reocr_run")
        check("mixed: the reason names the actual cause (multi-page PDF routed the run)",
              imgJob?.result?.errorMessage?.contains("multi-page") == true)
        check("mixed: the non-PDF sibling produced NO output (unchanged, but now explained)",
              mixProc.outputURLMap[mixIMG] == nil)
        check("mixed: the multi-page PDF in the same run still succeeds", pdfJob?.status == .succeeded)
        check("mixed: the PDF's own output landed (index mapping intact, image listed first)",
              mixProc.outputURLMap[mixPDF].map { fm.fileExists(atPath: $0.path) } == true)
        check("mixed: the PDF's output is the 4-page alternating rebuild (2 × 2)",
              mixProc.outputURLMap[mixPDF].flatMap { PDFDocument(url: $0)?.pageCount } == 4)
        check("mixed: the source image is untouched on disk (route only writes output)",
              fm.fileExists(atPath: mixIMG.path))

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["MULTIPAGE_REOCR_TEST_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("archiveprocessor-multipage-reocr-result.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        // Headless test binary: terminate once the report is durable so a runner gets a clean exit code.
        exit(passed ? 0 : 1)
    }
}
