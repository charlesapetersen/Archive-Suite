// W46.mixed-route — how mark transcripts enter the text layer, checked the way the Reader and Spotlight read it.
//
//     swiftc -O mixed_route_layer.swift -o <bin>/mixed-route-layer
//     mixed-route-layer write <spec.json> <out dir>    -> none.pdf, run.pdf, annot.pdf, textpage.pdf
//     mixed-route-layer check <spec.json> <out dir>    -> JSON on stdout: per form, per mark, found / placed / selected
//
// spec.json: {"image", "lines": [{"box", "text"}], "marks": [{"id", "box", "text", "cls"}]}, boxes [x0, y0, x1, y1]
// as page fractions with a top-left origin. Every PDF is the page image with the body text (Vision's lines) as an
// invisible run per line, as the Processor's layer is; `none` has no marks (the control: a mark's text found there
// is the print agreeing with it), and the three forms differ only in where the marks go:
//   run       each mark one more invisible run at its own box, its text prefixed with a label ("[handwritten] ",
//             "[stamp] "), so the mark is placed and the label says what it is;
//   annot     each mark a FreeText annotation over its box, contents the text, no visible ink (clear colour);
//   textpage  a second page after the image page, in visible type: "Marks on page 1", then a labelled line a mark.
// check: for each mark, PDFKit `findString` (case-insensitive, the Reader's DocumentFind call) on its text;
// `found` = some hit anywhere; `placed` = a hit on page 1 whose bounds meet the mark's box; `selected` = the
// string PDFKit selects over the mark's box contains the text (a drag over the mark); `extracted` = the text is in
// the document's own string (`PDFDocument.string`, the text a PDF importer reads). Whitespace collapsed, case
// folded. Reads the image; writes only into <out dir>.

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }

struct Mark { let id: String, box: [Double], text: String, cls: String }

func loadSpec(_ path: String) -> (String, [([Double], String)], [Mark]) {
    guard let d = FileManager.default.contents(atPath: path),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let image = j["image"] as? String else { fail("bad spec \(path)") }
    let lines = (j["lines"] as? [[String: Any]] ?? []).compactMap { l -> ([Double], String)? in
        guard let b = l["box"] as? [Double], let t = l["text"] as? String else { return nil }
        return (b, t)
    }
    let marks = (j["marks"] as? [[String: Any]] ?? []).compactMap { m -> Mark? in
        guard let id = m["id"] as? String, let b = m["box"] as? [Double], let t = m["text"] as? String else { return nil }
        return Mark(id: id, box: b, text: t, cls: m["cls"] as? String ?? "")
    }
    return (image, lines, marks)
}

/// A fractional top-left box as a rect in PDF points (bottom-left origin) on a page of the given bounds.
func rect(_ b: [Double], _ page: CGRect) -> CGRect {
    CGRect(x: b[0] * page.width, y: (1 - b[3]) * page.height, width: (b[2] - b[0]) * page.width,
           height: (b[3] - b[1]) * page.height)
}

func flat(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

func label(_ cls: String) -> String { cls == "stamp" ? "[stamp] " : cls == "other" ? "[mark] " : "[handwritten] " }

/// One invisible run at a box, place_functional.swift's `oracle --fit`: 0.8 of the box's height (at most 48 pt),
/// shrunk to the box's width when wider and never stretched, since a stretched run reads back from PDFKit as
/// spaced letters that Find misses (W46.place-hands).
func invisibleRun(_ ctx: CGContext, _ text: String, _ r: CGRect) {
    func make(_ size: CGFloat) -> (CTLine, Double) {
        let font = CTFontCreateWithName("Helvetica" as CFString, max(1, size), nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return (line, CTLineGetTypographicBounds(line, nil, nil, nil))
    }
    let size = min(r.height * 0.8, 48)
    var (line, width) = make(size)
    if width > r.width && width > 0 { (line, width) = make(size * r.width / width) }
    ctx.saveGState()
    ctx.setTextDrawingMode(.invisible)
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.2)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func imagePage(_ ctx: CGContext, _ img: CGImage, _ media: CGRect, _ lines: [([Double], String)], _ marks: [Mark]?) {
    ctx.beginPDFPage(nil)
    ctx.draw(img, in: media)
    for (b, t) in lines { invisibleRun(ctx, t, rect(b, media)) }
    for m in marks ?? [] { invisibleRun(ctx, label(m.cls) + flat(m.text), rect(m.box, media)) }
    ctx.endPDFPage()
}

func write(_ specPath: String, _ outDir: String) {
    let (image, lines, marks) = loadSpec(specPath)
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: image) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(image)") }
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    var media = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    func pdf(_ name: String, _ body: (CGContext) -> Void) {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else { fail("cannot write \(name)") }
        body(ctx)
        ctx.closePDF()
    }
    pdf("none.pdf") { imagePage($0, img, media, lines, nil) }
    pdf("run.pdf") { imagePage($0, img, media, lines, marks) }
    pdf("textpage.pdf") { ctx in
        imagePage(ctx, img, media, lines, nil)
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        var y = media.height - 120
        for t in ["Marks on page 1"] + marks.map({ label($0.cls) + flat($0.text) }) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: t, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: 80, y: y)
            CTLineDraw(line, ctx)
            y -= 54
        }
        ctx.endPDFPage()
    }
    // annot: the plain page, then PDFKit adds the annotations and saves.
    let plain = URL(fileURLWithPath: outDir).appendingPathComponent("annot.pdf")
    pdf("annot.pdf") { imagePage($0, img, media, lines, nil) }
    guard let doc = PDFDocument(url: plain), let page = doc.page(at: 0) else { fail("cannot reopen annot.pdf") }
    let bounds = page.bounds(for: .mediaBox)
    for m in marks {
        let a = PDFAnnotation(bounds: rect(m.box, bounds), forType: .freeText, withProperties: nil)
        a.contents = label(m.cls) + flat(m.text)
        a.color = .clear
        a.fontColor = .clear
        a.font = NSFont(name: "Helvetica", size: 12)
        page.addAnnotation(a)
    }
    guard doc.write(to: plain) else { fail("cannot save annot.pdf") }
}

func check(_ specPath: String, _ outDir: String) {
    let (_, _, marks) = loadSpec(specPath)
    var out: [String: Any] = [:]
    for form in ["none", "run", "annot", "textpage"] {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(form).pdf")
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { fail("cannot read \(form).pdf") }
        let bounds = page.bounds(for: .mediaBox)
        let docText = flat(doc.string ?? "").lowercased()
        var rows: [[String: Any]] = []
        for m in marks {
            let q = flat(m.text)
            let r = rect(m.box, bounds)
            let hits = q.isEmpty ? [] : doc.findString(q, withOptions: [.caseInsensitive])
            let placed = hits.contains { s in s.pages.contains(page) && s.bounds(for: page).intersects(r) }
            let sel = flat(page.selection(for: r)?.string ?? "").lowercased()
            rows.append(["id": m.id, "found": !hits.isEmpty, "placed": placed,
                         "selected": !q.isEmpty && sel.contains(q.lowercased()),
                         "extracted": !q.isEmpty && docText.contains(q.lowercased()),
                         "hit_pages": hits.compactMap { $0.pages.first.map { doc.index(for: $0) } }])
        }
        out[form] = rows
    }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: mixed-route-layer write|check <spec.json> <out dir>") }
switch args[1] {
case "write": write(args[2], args[3])
case "check": check(args[2], args[3])
default: fail("unknown command \(args[1])")
}
