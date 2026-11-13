#if DEBUG // a test driver, compiled out of Release
import AppKit
import ArchiveCore
import PDFKit

/// Headless, $0 self-test of Improve OCR's pair validation and replacement pages (W44.reocr-processor), gated by
/// `REOCR_PAIRS_TEST=1` (does nothing in normal use). Fixtures are Processor output written into
/// `REOCR_PAIRS_TEST_DIR`, a scratch folder the script makes; never the corpus. Run by `scripts/test-reocr-pairs.sh`.
///
/// What has to be true:
///   1. A two-page and a three-pair Processor file validate, with each pair's header read.
///   2. Refused: one page, three pages, a text page without the suite header, an image page that reads as a text
///      page (pages in the wrong order), an encrypted file, a header-like trap on a one-page file.
///   3. A replacement page keeps the pair's original filename, classification and source-date lines, names the new
///      reader and Kind, carries the new text and not the old; a failed or empty reading makes no page.
///   4. End to end: replacing pair 2 of three through `ReOCRIncrementalWriter` gives a candidate whose page 4 has
///      the new header and text and whose other text pages are unchanged.
@MainActor
enum ReOCRPairsTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["REOCR_PAIRS_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static let model = LLMModel.geminiModels[0]
    private static var dir = URL(fileURLWithPath: "/nonexistent")

    private static func jpeg(_ name: String) throws -> URL {
        let w = 100, h = 140
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 50, height: 80))
        guard let image = ctx.makeImage(), let rep = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        let url = dir.appendingPathComponent(name)
        try rep.write(to: url)
        return url
    }

    private static func pair(_ n: Int, classification: DocumentClassification?, dates: PDFSourceDates?) throws -> URL {
        let out = dir.appendingPathComponent("pair\(n).pdf")
        try PDFGenerator().generate(imageURL: jpeg("IMG_\(n).jpg"),
                                    result: OCRResult(text: "Old reading of image \(n).", classification: classification,
                                                      errorMessage: nil, errorCode: nil),
                                    model: model, outputURL: out, originalFileName: "IMG_\(n).jpg", sourceDates: dates,
                                    pageKind: .typewritten)
        return out
    }

    /// A one-page PDF drawing `text` with Core Text: no suite structure.
    private static func textPDF(_ text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: s.length),
                                             CGPath(rect: box.insetBy(dx: 20, dy: 20), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private static func pages(_ docs: [Data]) -> Data {
        let out = PDFDocument()
        for d in docs {
            guard let doc = PDFDocument(data: d) else { continue }
            for i in 0..<doc.pageCount { if let p = doc.page(at: i) { out.insert(p, at: out.pageCount) } }
        }
        return out.dataRepresentation() ?? Data()
    }

    private static func refused(_ name: String, _ data: Data, _ expect: (ReOCRPairs.Refusal) -> Bool) {
        switch ReOCRPairs.validate(data) {
        case .success(let p): check(name, false, "validated with \(p.count) pairs")
        case .failure(let r): check(name, expect(r), "\(r)")
        }
    }

    static func run() {
        defer { finish() }
        guard let path = ProcessInfo.processInfo.environment["REOCR_PAIRS_TEST_DIR"] else {
            check("0 REOCR_PAIRS_TEST_DIR is set", false); return
        }
        dir = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let dated = PDFSourceDates(documentDate: "12 March 1952", sentWith: nil)
            let one = try Data(contentsOf: pair(1, classification: .documentStart, dates: dated))
            let urls = try [
                pair(2, classification: .documentStart, dates: dated),
                pair(3, classification: .documentContinuation, dates: nil),
                pair(4, classification: nil, dates: PDFSourceDates(documentDate: "1952", sentWith: "12 March 1952")),
            ]
            let merged = dir.appendingPathComponent("three.pdf")
            try PDFGenerator().mergeDocumentPDFs(sourcePDFs: urls, outputURL: merged)
            let three = try Data(contentsOf: merged)

            // 1. Valid files.
            guard case .success(let p1) = ReOCRPairs.validate(one) else { check("1 a two-page file validates", false); return }
            check("1 a two-page file validates as one pair", p1.count == 1 && p1[0].imageIndex == 0 && p1[0].textIndex == 1)
            check("1 its header is read", p1[0].header.originalFilename?.replacingOccurrences(of: "\n", with: "") == "IMG_1.jpg" && p1[0].header.classification == "Document Start"
                  && p1[0].header.kind == .typewritten && p1[0].header.documentDate == "12 March 1952", "\(p1[0].header)")
            guard case .success(let p3) = ReOCRPairs.validate(three) else { check("1 a three-pair file validates", false); return }
            check("1 a three-pair file validates as three pairs", p3.map(\.textIndex) == [1, 3, 5])

            // 2. Refusals.
            refused("2 a single page is refused", textPDF("A letter.")) { $0 == .notPaired(pages: 1) }
            refused("2 a header-like single page is refused", textPDF("Extracted text.\nGemini · Flash · 1 May 2026\n\nTrap")) {
                $0 == .notPaired(pages: 1)
            }
            refused("2 three pages are refused", pages([one, textPDF("x")])) {
                $0 == .notPaired(pages: 3)
            }
            refused("2 a text page without the header is refused", pages([textPDF("image stand-in"), textPDF("Plain text.")])) {
                $0 == .textPageWithoutHeader(page: 1)
            }
            if let doc = PDFDocument(data: one), let image = doc.page(at: 0), let text = doc.page(at: 1) {
                let swapped = PDFDocument()
                swapped.insert(text, at: 0); swapped.insert(image, at: 1)
                refused("2 pages in the wrong order are refused", swapped.dataRepresentation() ?? Data()) {
                    $0 == .imagePageLooksLikeText(page: 0)
                }
            }
            if let doc = PDFDocument(data: one),
               let enc = doc.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "",
                                                          PDFDocumentWriteOption.ownerPasswordOption: "o"]) {
                refused("2 an encrypted file is refused", enc) { $0 == .locked }
            } else { check("2 the encrypted fixture is written", false) }
            refused("2 something that is not a PDF is refused", Data("no".utf8)) { $0 == .unreadable }

            // 3. Replacement pages.
            let reading = OCRResult(text: "A much better reading of image 1.", classification: .folderLabel,
                                    errorMessage: nil, errorCode: nil)
            let page = try ReOCRPairs.replacementPage(for: p1[0], result: reading, model: model, kind: .handwritten)
            guard let newPage = PDFDocument(data: page)?.page(at: 0) else { check("3 the page is made", false); return }
            let parsed = PDFHeaderParser.parse(newPage)
            let h = parsed.header
            check("3 the original filename reads back as before", h?.originalFilename == p1[0].header.originalFilename, "\(String(describing: h))")
            check("3 the classification is the pair's, not the reading's", h?.classification == "Document Start")
            check("3 the source date is kept", h?.documentDate == "12 March 1952" && h?.sentWith == nil)
            check("3 the new Kind is written", h?.kind == .handwritten)
            check("3 the new reader is named", h?.provenance?.model == model.displayName, "\(String(describing: h?.provenance))")
            check("3 the body is the new text", parsed.body.contains("A much better reading") && !parsed.body.contains("Old reading"))
            do {
                _ = try ReOCRPairs.replacementPage(for: p1[0], result: OCRResult(text: "  \n", classification: nil,
                                                   errorMessage: nil, errorCode: nil), model: model, kind: nil)
                check("3 an empty reading makes no page", false)
            } catch { check("3 an empty reading makes no page", { if case ReOCRPairs.Refusal.noReading = error { return true }; return false }()) }
            do {
                _ = try ReOCRPairs.replacementPage(for: p1[0], result: .cutOff, model: model, kind: nil)
                check("3 a cut-off reading makes no page", false)
            } catch { check("3 a cut-off reading makes no page", { if case ReOCRPairs.Refusal.noReading = error { return true }; return false }()) }

            // A long name with underscores, wrapped across lines, reads back the same.
            let long = try pair(9, classification: nil, dates: nil)
            let longName = "Herrnstein_Papers_Box_12_Folder_3_Correspondence_with_the_Dean_1952_IMG_0042.jpg"
            try PDFGenerator().generate(imageURL: jpeg("long.jpg"), result: OCRResult(text: "x", classification: nil,
                                        errorMessage: nil, errorCode: nil), model: model, outputURL: long,
                                        originalFileName: longName)
            if case .success(let pl) = ReOCRPairs.validate(try Data(contentsOf: long)) {
                check("3 a long underscored name is read", pl[0].header.originalFilename?.replacingOccurrences(of: "\n", with: "") == longName,
                      "\(String(describing: pl[0].header.originalFilename))")
                let made = try? ReOCRPairs.replacementPage(for: pl[0], result: reading, model: model, kind: nil)
                check("3 a long underscored name is kept", made != nil)
            } else if case .failure(let r) = ReOCRPairs.validate(try Data(contentsOf: long)) {
                // Core's parser looks for the reader line only in the first three header slots, so a name that wraps
                // onto three lines hides it (W44.reocr-header-longname). Refusing is the safe answer until then.
                check("3 a long name that hides the reader line is refused, not guessed", r == .textPageWithoutProvenance(page: 1), "\(r)")
                lines.append("INFO 3 long underscored name: refused (\(r)); see W44.reocr-header-longname")
            }

            // 4. End to end on the middle pair.
            let mid = try ReOCRPairs.replacementPage(for: p3[1], result: OCRResult(text: "New reading of image 3.",
                                                     classification: nil, errorMessage: nil, errorCode: nil),
                                                     model: model, kind: .printed)
            let cand = try ReOCRIncrementalWriter.candidate(original: three, replacements: [p3[1].textIndex: mid])
            guard case .success(let after) = ReOCRPairs.validate(cand) else { check("4 the candidate validates", false); return }
            check("4 the candidate still has three pairs", after.count == 3)
            check("4 pair 2 has its new Kind and kept classification",
                  after[1].header.kind == .printed && after[1].header.classification == "Continuation", "\(after[1].header)")
            check("4 pairs 1 and 3 keep their headers", after[0].header == p3[0].header && after[2].header == p3[2].header)
            let text = PDFDocument(data: cand)?.page(at: 3)?.string ?? ""
            check("4 page 4 reads the new text", text.contains("New reading of image 3.") && !text.contains("Old reading of image 3."))
            check("4 page 6 keeps the old text", (PDFDocument(data: cand)?.page(at: 5)?.string ?? "").contains("Old reading of image 4."))
        } catch {
            check("no error is thrown", false, "\(error)")
        }
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["REOCR_PAIRS_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
#endif
