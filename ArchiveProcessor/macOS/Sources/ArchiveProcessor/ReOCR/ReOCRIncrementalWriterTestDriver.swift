#if DEBUG // a test driver, compiled out of Release
import AppKit
import ArchiveCore
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Headless, $0 proof of the Improve OCR writer on the pinned PDFium (W44.reocr-processor), gated by
/// `REOCR_WRITER_TEST=1` (does nothing in normal use). The fixtures are real Processor output, written by
/// `PDFGenerator.generate` from a JPEG it draws and merged by `mergeDocumentPDFs`, into `REOCR_WRITER_TEST_DIR`
/// (a scratch folder the script makes). No model call, no network, no window, never the corpus. Run by
/// `scripts/test-reocr-writer.sh`.
///
/// What has to be true:
///   1. A two-page file: replacing page 2 gives a candidate that passes `ReOCRPreservationCheck`, reads the new text
///      on page 2 and not the old, and begins with the original byte for byte.
///   2. A three-pair file: replacing pages 2 and 6 keeps pages 1, 3, 4 and 5, page 4's old text included.
///   3. A candidate can itself be improved again (a second revision on the first).
///   4. Refusals: nothing to replace, a page out of range, a replacement that is not one page, an unreadable
///      original or replacement, an encrypted original.
///   5. A PDFKit whole-file save of the same change is refused by the check, the save this writer exists to avoid.
///   6. Pages inheriting MediaBox, Rotate and Resources from the page tree, an annotation and an information
///      dictionary all survive; a certified file or a form with signatures is refused.
///   7. A file ending in a cross-reference stream (qpdf, when installed) is refused: the pinned PDFium extends one
///      into a file Quartz cannot open. Every Processor fixture above ends in a table.
///   8. Optionally, scratch copies in `REOCR_WRITER_TEST_EXTRA` (never the corpus itself).
@MainActor
enum ReOCRIncrementalWriterTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["REOCR_WRITER_TEST"] == "1" else { return }
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

    private static func ocr(_ text: String) -> OCRResult {
        OCRResult(text: text, classification: nil, errorMessage: nil, errorCode: nil)
    }

    /// A JPEG with some structure in it, so a recompression would change its bytes and its pixels.
    private static func writeJPEG(_ url: URL, seed: Int) -> Bool {
        let w = 240, h = 320
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        for i in 0..<12 {
            let v = CGFloat((i * 37 + seed * 53) % 255) / 255
            ctx.setFillColor(CGColor(red: v, green: 1 - v, blue: CGFloat(i) / 12, alpha: 1))
            ctx.fill(CGRect(x: (i * 19) % w, y: (i * 29 + seed * 7) % h, width: 60, height: 40))
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// A Processor two-page PDF for one image.
    private static func pair(_ dir: URL, _ n: Int, text: String) throws -> URL {
        let jpg = dir.appendingPathComponent("page\(n).jpg"), pdf = dir.appendingPathComponent("page\(n).pdf")
        guard writeJPEG(jpg, seed: n) else { throw CocoaError(.fileWriteUnknown) }
        let outcome = try PDFGenerator().generate(imageURL: jpg, result: ocr(text), model: model, outputURL: pdf,
                                                  originalFileName: "page\(n).jpg", pageKind: .typewritten)
        guard outcome == .embedded else { throw CocoaError(.fileWriteUnknown) }
        return pdf
    }

    private static func pageText(_ data: Data, _ index: Int) -> String {
        PDFDocument(data: data)?.page(at: index)?.string ?? ""
    }

    private static func newText(_ text: String) -> Data? {
        PDFGenerator().textPageData(result: ocr(text), model: model, originalFileName: "page.jpg", pageKind: .handwritten)
    }

    private static func refuses(_ name: String, _ original: Data, _ replacements: [Int: Data],
                                _ expected: (ReOCRIncrementalWriter.Failure) -> Bool) {
        do {
            _ = try ReOCRIncrementalWriter.candidate(original: original, replacements: replacements)
            check(name, false, "a candidate was returned")
        } catch let f as ReOCRIncrementalWriter.Failure {
            check(name, expected(f), "\(f)")
        } catch {
            check(name, false, "\(error)")
        }
    }

    static func run() {
        defer { finish() }
        guard let dirPath = ProcessInfo.processInfo.environment["REOCR_WRITER_TEST_DIR"] else {
            check("0 REOCR_WRITER_TEST_DIR is set", false); return
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        do {
            // 1. Two pages.
            let two = try Data(contentsOf: pair(dir, 1, text: "The old reading of page one."))
            check("0 the two-page fixture has two pages", PDFDocument(data: two)?.pageCount == 2)
            guard let replacement = newText("A better reading of page one.") else {
                check("0 the new text page is made", false); return
            }
            let cand = try ReOCRIncrementalWriter.candidate(original: two, replacements: [1: replacement])
            check("1 the candidate begins with the original", cand.prefix(two.count) == two)
            check("1 page 2 reads the new text", pageText(cand, 1).contains("A better reading of page one."),
                  pageText(cand, 1))
            check("1 page 2 no longer reads the old text", !pageText(cand, 1).contains("The old reading"))
            check("1 the new page header says its kind",
                  pageText(cand, 1).contains("\(PDFHeaderParser.kindPrefix)handwritten"))
            check("1 the candidate passes the preservation check on its own",
                  ReOCRPreservationCheck.problems(original: two, candidate: cand, replacing: [1]).isEmpty)
            lines.append("INFO two-page: original \(two.count) bytes, candidate \(cand.count) bytes")

            // 2. Three pairs, two replaced.
            let parts = try [2, 3, 4].map { try pair(dir, $0, text: "The old reading of image \($0).") }
            let merged = dir.appendingPathComponent("three.pdf")
            try PDFGenerator().mergeDocumentPDFs(sourcePDFs: parts, outputURL: merged)
            let six = try Data(contentsOf: merged)
            check("0 the three-pair fixture has six pages", PDFDocument(data: six)?.pageCount == 6)
            guard let r2 = newText("New reading of image 2."), let r4 = newText("New reading of image 4.") else {
                check("0 the new text pages are made", false); return
            }
            let cand6 = try ReOCRIncrementalWriter.candidate(original: six, replacements: [1: r2, 5: r4])
            check("2 page 2 reads its new text", pageText(cand6, 1).contains("New reading of image 2."))
            check("2 page 6 reads its new text", pageText(cand6, 5).contains("New reading of image 4."))
            check("2 page 4 keeps its old text", pageText(cand6, 3).contains("The old reading of image 3."))
            check("2 the page count is kept", PDFDocument(data: cand6)?.pageCount == 6)

            // 3. A second improvement over the first.
            guard let again = newText("A third reading of page one.") else { check("0 made", false); return }
            let cand2 = try ReOCRIncrementalWriter.candidate(original: cand, replacements: [1: again])
            check("3 a candidate improves again", pageText(cand2, 1).contains("A third reading of page one."))
            check("3 the first revision is its prefix", cand2.prefix(cand.count) == cand)

            // 4. Refusals.
            refuses("4 nothing to replace is refused", two, [:]) { $0 == .noReplacements }
            refuses("4 a page out of range is refused", two, [2: replacement]) { $0 == .pageOutOfRange(page: 2) }
            refuses("4 a negative page is refused", two, [-1: replacement]) { $0 == .pageOutOfRange(page: -1) }
            refuses("4 a two-page replacement is refused", two, [1: two]) { $0 == .replacementNotOnePage(page: 1) }
            refuses("4 an unreadable replacement is refused", two, [1: Data("not a pdf".utf8)]) {
                $0 == .replacementUnreadable(page: 1)
            }
            refuses("4 an unreadable original is refused", Data("not a pdf".utf8), [1: replacement]) {
                if case .originalUnreadable = $0 { return true } else { return false }
            }
            let encURL = dir.appendingPathComponent("encrypted.pdf")
            if let doc = PDFDocument(data: two),
               doc.write(to: encURL, withOptions: [.userPasswordOption: "", .ownerPasswordOption: "owner"]),
               let enc = try? Data(contentsOf: encURL) {
                refuses("4 an encrypted original is refused", enc, [1: replacement]) { $0 == .encrypted }
            } else {
                check("4 the encrypted fixture is written", false)
            }

            // 5. The whole-file save this writer replaces fails at the prefix. (An override of a kept object inside a
            // valid incremental revision is refused by the object comparison: ReOCRPreservationCheckTestDriver §2.)
            if let doc = PDFDocument(data: two), let newDoc = PDFDocument(data: replacement), let page = newDoc.page(at: 0) {
                doc.removePage(at: 1)
                doc.insert(page, at: 1)
                if let whole = doc.dataRepresentation() {
                    let p = ReOCRPreservationCheck.problems(original: two, candidate: whole, replacing: [1])
                    check("5 a PDFKit whole-file save is refused at the prefix", p.contains { $0.contains("byte for byte") },
                          "\(p)")
                } else { check("5 PDFKit saves", false) }
            }

            // 6. Pages that inherit their resources, box and rotation from the page tree, with an annotation and an
            // information dictionary: none of it may move.
            let inherited = handFile(catalog: "<< /Type /Catalog /Pages 2 0 R >>")
            try inherited.write(to: dir.appendingPathComponent("inherited.pdf"))
            passes("6 a page tree with inherited attributes keeps them", inherited, replacement)
            refuses("6 a certified file (/Perms) is refused",
                    handFile(catalog: "<< /Type /Catalog /Pages 2 0 R /Perms << /DocMDP 12 0 R >> >>"),
                    [1: replacement]) { $0 == .signed }
            refuses("6 a form that says it holds signatures is refused",
                    handFile(catalog: "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [] /SigFlags 3 >> >>"),
                    [1: replacement]) { $0 == .signed }

            // 7. Cross-reference and object streams, made by qpdf when present; refused up front.
            for (name, data) in [("two-page", two), ("three-pair", six), ("inherited", inherited)] {
                check("7 the \(name) fixture ends in an xref table", !ReOCRIncrementalWriter.endsInCrossReferenceStream(data))
            }
            let qpdf = ["/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf"].first { FileManager.default.isExecutableFile(atPath: $0) }
            if let qpdf {
                for name in ["page1.pdf", "inherited.pdf", "three.pdf"] {
                    let src = dir.appendingPathComponent(name), out = dir.appendingPathComponent("objstm-" + name)
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: qpdf)
                    p.arguments = ["--object-streams=generate", src.path, out.path]
                    try p.run(); p.waitUntilExit()
                    // qpdf exits 3 when it wrote the file with warnings.
                    guard [0, 3].contains(p.terminationStatus), let data = try? Data(contentsOf: out) else {
                        check("7 qpdf writes object streams for \(name)", false, "status \(p.terminationStatus)"); continue
                    }
                    check("7 \(name) is rewritten with a cross-reference stream",
                          ReOCRIncrementalWriter.endsInCrossReferenceStream(data))
                    refuses("7 \(name) with object streams is refused before PDFium", data, [1: replacement]) {
                        $0 == .crossReferenceStream
                    }
                }
            } else {
                lines.append("INFO 7 skipped: qpdf is not installed")
            }

            // 8. Optional: scratch copies of other files (REOCR_WRITER_TEST_EXTRA, a folder), page 2 replaced.
            if let extra = ProcessInfo.processInfo.environment["REOCR_WRITER_TEST_EXTRA"] {
                let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: extra),
                                                                         includingPropertiesForKeys: nil)) ?? []
                for url in urls.filter({ $0.pathExtension.lowercased() == "pdf" }).sorted(by: { $0.path < $1.path }) {
                    guard let data = try? Data(contentsOf: url), (PDFDocument(data: data)?.pageCount ?? 0) >= 2 else {
                        lines.append("INFO 8 skipped \(url.lastPathComponent): fewer than two pages"); continue
                    }
                    passes("8 \(url.lastPathComponent)", data, replacement)
                }
            }
        } catch {
            check("no error is thrown", false, "\(error)")
        }
    }

    private static func passes(_ name: String, _ original: Data, _ replacement: Data) {
        do {
            let c = try ReOCRIncrementalWriter.candidate(original: original, replacements: [1: replacement])
            check(name, pageText(c, 1).contains("A better reading of page one."), "the new text is not on page 2")
            lines.append("INFO \(name): original \(original.count) bytes, revision \(c.count - original.count) bytes")
        } catch {
            check(name, false, "\(error)")
        }
    }

    /// A hand-written two-page file whose pages inherit MediaBox, Rotate and Resources from the page tree; page 1
    /// draws an image and carries an annotation, and the trailer names an information dictionary.
    private static func handFile(catalog: String) -> Data {
        func stream(_ dict: String, _ bytes: Data) -> Data {
            var d = Data("<< \(dict) /Length \(bytes.count) >>\nstream\n".utf8)
            d.append(bytes); d.append(Data("\nendstream".utf8))
            return d
        }
        let objects: [Int: Data] = [
            1: Data(catalog.utf8),
            2: Data(("<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /MediaBox [0 0 300 400] /Rotate 90 "
                     + "/Resources << /XObject << /Im1 5 0 R >> /Font << /F1 8 0 R >> >> >>").utf8),
            3: Data("<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [11 0 R] >>".utf8),
            4: stream("", Data("q 200 0 0 200 20 20 cm /Im1 Do Q".utf8)),
            5: stream("/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8",
                      Data([0x00, 0xFF, 0x80, 0x40])),
            6: Data("<< /Type /Page /Parent 2 0 R /Contents 7 0 R >>".utf8),
            7: stream("", Data("BT /F1 12 Tf 20 100 Td (Extracted text. the old reading) Tj ET".utf8)),
            8: Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
            10: Data("<< /Title (Inherited fixture) /Author (W44) >>".utf8),
            11: Data("<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (note) /P 3 0 R >>".utf8),
            12: Data("<< /Type /Sig /Filter /Adobe.PPKLite >>".utf8),
        ]
        var out = Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int: Int] = [:]
        for n in objects.keys.sorted() {
            offsets[n] = out.count
            out.append(Data("\(n) 0 obj\n".utf8)); out.append(objects[n]!); out.append(Data("\nendobj\n".utf8))
        }
        let size = objects.keys.max()! + 1, xref = out.count
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for n in 1..<size {
            table += offsets[n].map { String(format: "%010d 00000 n \n", $0) } ?? "0000000000 65535 f \n"
        }
        table += "trailer\n<< /Size \(size) /Root 1 0 R /Info 10 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["REOCR_WRITER_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
#endif
