#if DEBUG // a test driver, compiled out of Release
import CoreGraphics
import Foundation

/// Headless, $0 self-test of the Improve OCR preservation check (W44.reocr-processor), gated by
/// `REOCR_PRESERVATION_TEST=1` (does nothing in normal use). Works on PDFs it writes in memory; no file, no corpus,
/// no network, no window. Run by `scripts/test-reocr-preservation.sh`.
///
/// The fixture is a suite-shaped pair: page 1 an image page (a content stream drawing an image XObject, with an
/// annotation pointing back to its page), page 2 a text page. Candidates are incremental revisions appended to it,
/// each with the object numbers it overrides, so a test can replace exactly the objects it means to.
///
/// What has to be true:
///   1. Substituting page 2 through a new page object and a new page-tree node passes, and so does re-stating an
///      original object unchanged.
///   2. Any change to page 1's active graph fails though the prefix is intact: its content stream, its image's bytes,
///      a key on the page, an attribute it inherits from the page tree.
///   3. A broken prefix, a changed page count, an unlisted replacement or an out-of-range page fails, and so does a
///      catalog change beside the page tree.
@MainActor
enum ReOCRPreservationCheckTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["REOCR_PRESERVATION_TEST"] == "1" else { return }
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

    // MARK: A tiny PDF writer for fixtures

    /// One indirect object's body, as bytes between `N 0 obj` and `endobj`.
    private static func dict(_ s: String) -> Data { Data(s.utf8) }

    private static func stream(_ dict: String, _ bytes: Data) -> Data {
        var d = Data("<< \(dict) /Length \(bytes.count) >>\nstream\n".utf8)
        d.append(bytes)
        d.append(Data("\nendstream".utf8))
        return d
    }

    private static func xrefLine(_ offset: Int) -> String { String(format: "%010d 00000 n \n", offset) }

    /// A whole file, and its xref offset for a later revision's `/Prev`.
    private static func file(_ objects: [Int: Data]) -> (Data, Int) {
        var out = Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int: Int] = [:]
        for n in objects.keys.sorted() {
            offsets[n] = out.count
            out.append(Data("\(n) 0 obj\n".utf8)); out.append(objects[n]!); out.append(Data("\nendobj\n".utf8))
        }
        let size = (objects.keys.max() ?? 0) + 1
        let xref = out.count
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for n in 1..<size { table += offsets[n].map(xrefLine) ?? "0000000000 65535 f \n" }
        table += "trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return (out, xref)
    }

    /// `base` with one incremental revision that defines (or redefines) `objects`.
    private static func revise(_ base: (Data, Int), _ objects: [Int: Data], size: Int) -> Data {
        var out = base.0
        var offsets: [Int: Int] = [:]
        for n in objects.keys.sorted() {
            offsets[n] = out.count
            out.append(Data("\(n) 0 obj\n".utf8)); out.append(objects[n]!); out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n"
        for n in objects.keys.sorted() { table += "\(n) 1\n" + xrefLine(offsets[n]!) }
        table += "trailer\n<< /Size \(size) /Root 1 0 R /Prev \(base.1) >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }

    private static let imageContent = Data("q 200 0 0 200 0 0 cm /Im1 Do Q".utf8)
    private static let imageBytes = Data([0x00, 0xFF, 0xFF, 0x00])
    private static let imageDict = "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private static let imagePage = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] "
        + "/Resources << /XObject << /Im1 5 0 R >> >> /Contents 4 0 R /Annots [11 0 R] >>"

    private static func textPage(_ contents: Int) -> Data {
        dict("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 8 0 R >> >> /Contents \(contents) 0 R >>")
    }

    private static func textStream(_ text: String) -> Data {
        stream("", Data("BT /F1 12 Tf 20 100 Td (\(text)) Tj ET".utf8))
    }

    static func run() {
        defer { finish() }
        let base = file([
            1: dict("<< /Type /Catalog /Pages 2 0 R >>"),
            2: dict("<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>"),
            3: dict(imagePage),
            4: stream("", imageContent),
            5: stream(imageDict, imageBytes),
            6: textPage(7),
            7: textStream("Extracted text. the old reading"),
            8: dict("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
            11: dict("<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (note) /P 3 0 R >>"),
        ])
        let original = base.0
        let substitute: [Int: Data] = [
            2: dict("<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>"),
            9: textPage(10),
            10: textStream("Extracted text. the new reading"),
        ]
        func problems(_ candidate: Data, replacing: Set<Int> = [1]) -> [String] {
            ReOCRPreservationCheck.problems(original: original, candidate: candidate, replacing: replacing)
        }
        func with(_ extra: [Int: Data]) -> Data {
            revise(base, substitute.merging(extra) { _, new in new }, size: 12)
        }

        // 1. Passing candidates.
        let good = with([:])
        check("0 the fixture opens with two pages", ReOCRPreservationCheck.document(original)?.numberOfPages == 2)
        check("0 the candidate shows the new text page",
              ReOCRPreservationCheck.document(good)?.page(at: 2).flatMap { p -> Bool? in
                  guard let d = p.dictionary else { return nil }
                  var c: CGPDFStreamRef?
                  guard CGPDFDictionaryGetStream(d, "Contents", &c), let c else { return nil }
                  var f = CGPDFDataFormat.raw
                  return (CGPDFStreamCopyData(c, &f) as Data?).map { String(decoding: $0, as: UTF8.self).contains("new reading") }
              } == true)
        let goodProblems = problems(good)
        check("1 substituting the text page passes", goodProblems.isEmpty, "\(goodProblems)")
        let restated = problems(with([4: stream("", imageContent), 3: dict(imagePage)]))
        check("1 re-stating original objects unchanged passes", restated.isEmpty, "\(restated)")
        check("1 a page that renders is compared by pixels",
              ReOCRPreservationCheck.document(original)?.page(at: 1).flatMap(ReOCRPreservationCheck.render) != nil)

        // 2. Changes to the kept page fail despite the intact prefix.
        func fails(_ name: String, _ candidate: Data, _ needle: String, replacing: Set<Int> = [1]) {
            let p = problems(candidate, replacing: replacing)
            check(name, !p.isEmpty && p.contains { $0.contains(needle) }, "\(p)")
        }
        fails("2 a changed image content stream fails", with([4: stream("", Data("q 100 0 0 100 0 0 cm /Im1 Do Q".utf8))]),
              "stream bytes changed")
        fails("2 changed image bytes fail", with([5: stream(imageDict, Data([0xFF, 0x00, 0x00, 0xFF]))]), "stream bytes changed")
        fails("2 a recompressed image fails", with([5: stream(imageDict + " /Filter /ASCIIHexDecode", Data("00FFFF00>".utf8))]),
              "page 1")
        fails("2 a key added to the kept page fails",
              with([3: dict(imagePage.replacingOccurrences(of: "/Contents 4 0 R", with: "/Contents 4 0 R /Rotate 90"))]),
              "keys changed")
        fails("2 a changed annotation fails",
              with([11: dict("<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (edited) /P 3 0 R >>")]),
              "Annots")
        fails("2 an attribute the kept page inherits fails",
              with([2: dict("<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 /Rotate 90 >>")]), "inherited")

        fails("2 a catalog change beside the page tree fails",
              with([1: dict("<< /Type /Catalog /Pages 2 0 R /OpenAction [3 0 R /Fit] >>")]), "catalog")
        let repointed = revise(base, substitute.merging([
            1: dict("<< /Type /Catalog /Pages 12 0 R >>"),
            12: dict("<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>"),
        ]) { _, new in new }, size: 13)
        let rp = problems(repointed)
        let outlined = file([
            1: dict("<< /Type /Catalog /Pages 2 0 R /OpenAction [3 0 R /Fit] >>"),
            2: dict("<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>"),
            3: dict(imagePage), 4: stream("", imageContent), 5: stream(imageDict, imageBytes), 6: textPage(7),
            7: textStream("Extracted text. the old reading"),
            8: dict("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
            11: dict("<< /Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (note) /P 3 0 R >>"),
        ])
        let op = ReOCRPreservationCheck.problems(original: outlined.0, candidate: revise(outlined, substitute, size: 12),
                                                 replacing: [1])
        check("2 a catalog action naming a kept page does not reach into the changed page tree", op.isEmpty, "\(op)")
        check("2 a new page-tree node the catalog points to is a page-tree change", rp.isEmpty, "\(rp)")

        // 3. Structure.
        var broken = good
        broken[20] ^= 0x01
        fails("3 a broken prefix fails", broken, "byte for byte")
        fails("3 the original alone is no candidate", original, "byte for byte")
        fails("3 a changed page count fails", with([2: dict("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")]), "page count")
        fails("3 a replaced page not listed fails", good, "page 2", replacing: [])
        fails("3 a page out of range fails", good, "not in the file", replacing: [1, 5])
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["REOCR_PRESERVATION_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}

#endif
