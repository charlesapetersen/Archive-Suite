// W46.fix-place-truth — the functional placement score, on a rendered PDF (F-placement §6.2, first level).
//
//     swiftc -O place_functional.swift -o /tmp/place_functional
//     place_functional score  <truth.json> <page.pdf> [--page N]          -> JSON: find and placed-hit rates
//     place_functional words  <truth.json> <page.pdf> <hyp.json> [--page N] [--baseline-frac F]
//                                                                         -> the PDF's own word and line boxes, in
//                                                                            place_score.py's hypothesis form
//     place_functional oracle <truth.json> <out.pdf> [--dx X] [--dy Y] [--words hyp.json]
//                                                                         -> the page image with invisible text at
//                                                                            the truth boxes (shifted by X, Y of
//                                                                            the page), for the self-test; with
//                                                                            --words, at a hypothesis's word boxes
//                                                                            instead (W46.place-hands); --fit
//                                                                            sizes each word's font to its box
//                                                                            rather than stretching it
//
//     place_functional layer  <lines.json> <out.pdf>                     -> W46.place-geom's own writer: one run per
//                                                                            line along its baseline, sloped or level
//     place_functional drag   <drags.json> <page.pdf> <out.json> [--page N]
//                                                                         -> the line pass rate (F-placement §6.2,
//                                                                            "Selection is a line")
//
// Score: for every scoreable truth word (a box, not missing or illegible) with four or more letters once its
// leading and trailing punctuation is stripped, ask PDFKit `findString` (case-insensitive) for it. `find` = some
// hit on the page; `placed` = some hit whose selection bounds intersect the word's truth box. What the user feels:
// Find works, and the highlight lands on the word. The truth box is normalised with a top-left origin over the
// whole image, and the PDF page is taken to show that image over its crop box, as the Processor's writer does.
//
// `words` reads the text layer back as the hypothesis for the word and baseline scorers: characters grouped at
// whitespace into words, at newlines into lines; a word's box is its PDFKit selection's bounds (the highlight the
// user sees, full line height, where `characterBounds` is glyph-tight), a line's the union of its words'; a line's
// baseline is drawn at --baseline-frac of its box from the top (default 0.78, as place_truth.py drafts truth).

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

struct Box { var x, y, w, h: Double }

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }

func loadJSON(_ path: String) -> [String: Any] {
    guard let d = FileManager.default.contents(atPath: path),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { fail("cannot read \(path)") }
    return o
}

func box(_ a: Any?) -> Box? {
    guard let v = a as? [Double], v.count == 4 else { return nil }
    return Box(x: v[0], y: v[1], w: v[2], h: v[3])
}

func option(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let unscored: Set<String> = ["missing", "illegible", "line-only"]

/// Normalised top-left box -> PDF page rect (bottom-left origin) over the page's crop box.
func pageRect(_ b: Box, _ bounds: CGRect) -> CGRect {
    CGRect(x: bounds.minX + b.x * bounds.width, y: bounds.minY + (1 - b.y - b.h) * bounds.height,
           width: b.w * bounds.width, height: b.h * bounds.height)
}

func searchTerm(_ text: String) -> String? {
    let t = text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    return t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 4 ? t : nil
}

func score(_ truth: [String: Any], _ doc: PDFDocument, _ pageIndex: Int) -> [String: Any] {
    guard let page = doc.page(at: pageIndex) else { fail("no page \(pageIndex)") }
    let bounds = page.bounds(for: .cropBox)
    var n = 0, found = 0, placed = 0
    var cache: [String: [CGRect]] = [:]
    for w in truth["words"] as? [[String: Any]] ?? [] {
        guard let b = box(w["box"]), !unscored.contains(w["status"] as? String ?? ""),
              let term = searchTerm(w["text"] as? String ?? "") else { continue }
        n += 1
        let key = term.lowercased()
        let hits = cache[key] ?? doc.findString(term, withOptions: .caseInsensitive)
            .filter { $0.pages.contains(page) }.map { $0.bounds(for: page) }
        cache[key] = hits
        if !hits.isEmpty { found += 1 }
        let r = pageRect(b, bounds)
        if hits.contains(where: { $0.intersects(r) }) { placed += 1 }
    }
    return ["page": truth["page"] ?? "", "words": n, "found": found, "placed": placed,
            "find_rate": n > 0 ? Double(found) / Double(n) : 0, "placed_rate": n > 0 ? Double(placed) / Double(n) : 0]
}

func norm(_ r: CGRect, _ bounds: CGRect) -> [Double] {
    [Double((r.minX - bounds.minX) / bounds.width), Double((bounds.maxY - r.maxY) / bounds.height),
     Double(r.width / bounds.width), Double(r.height / bounds.height)]
}

func words(_ doc: PDFDocument, _ pageIndex: Int, baselineFrac: Double) -> [String: Any] {
    guard let page = doc.page(at: pageIndex) else { fail("no page \(pageIndex)") }
    let bounds = page.bounds(for: .cropBox)
    let s = (page.string ?? "") as NSString
    var outWords: [[String: Any]] = [], outLines: [[String: Any]] = []
    var word = "", start = 0, line = "", lrect = CGRect.null
    func endWord() {
        if !word.isEmpty {
            let wrect = page.selection(for: NSRange(location: start, length: (word as NSString).length))?
                .bounds(for: page) ?? .null
            if !wrect.isNull && wrect.width > 0 {
                outWords.append(["text": word, "box": norm(wrect, bounds)])
                lrect = lrect.union(wrect)
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        word = ""
    }
    func endLine() {
        endWord()
        if !line.isEmpty && !lrect.isNull {
            let b = norm(lrect, bounds)
            let y = b[1] + baselineFrac * b[3]
            outLines.append(["text": line, "box": b, "baseline": [[b[0], y], [b[0] + b[2], y]]])
        }
        line = ""; lrect = .null
    }
    for i in 0..<s.length {
        let c = s.substring(with: NSRange(location: i, length: 1))
        if c == "\n" || c == "\r" { endLine(); continue }
        if c.trimmingCharacters(in: .whitespaces).isEmpty { endWord(); continue }
        if word.isEmpty { start = i }
        word += c
    }
    endLine()
    return ["words": outWords, "lines": outLines]
}

func oracle(_ truth: [String: Any], _ out: String, dx: Double, dy: Double, hypWords: [[String: Any]]? = nil, fit: Bool = false) {
    guard let path = truth["image"] as? String,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read the page image") }
    var media = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    guard let ctx = CGContext(URL(fileURLWithPath: out) as CFURL, mediaBox: &media, nil) else { fail("cannot write \(out)") }
    ctx.beginPDFPage(nil)
    ctx.draw(img, in: media)
    ctx.setTextDrawingMode(.invisible)
    for w in hypWords ?? truth["words"] as? [[String: Any]] ?? [] {
        guard var b = box(w["box"]), let text = w["text"] as? String, b.w > 0, b.h > 0 else { continue }
        b.x += dx; b.y += dy
        let r = pageRect(b, media)
        // 0.8 of the box: filling it makes neighbouring lines' text touch, and PDFKit then welds them.
        func run(_ size: CGFloat) -> (CTLine, Double) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            return (line, CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        var (line, width) = run(r.height * 0.8)
        // --fit: no horizontal stretch. A word stretched far past its natural width (a tall handwritten box, a
        // proportional share) reads back from PDFKit as spaced letters, so Find misses it; shrink the font to the
        // box's width instead, and leave a narrow word at its natural width from the box's left edge.
        if fit && width > r.width && width > 0 { (line, width) = run(r.height * 0.8 * r.width / width) }
        ctx.saveGState()
        ctx.textMatrix = fit ? .identity : CGAffineTransform(scaleX: width > 0 ? r.width / width : 1, y: 1)
        ctx.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
    ctx.endPDFPage()
    ctx.closePDF()
}

// `layer` (W46.place-geom). lines.json: {"width", "height" (points), "lines": [{"text", "baseline": [[x0, y0],
// [x1, y1]], "height"}]}, normalised with a top-left origin (height as a share of the page height). Each line is one
// invisible run whose baseline runs from (x0, y0) to (x1, y1): OCRmyPDF's design of one sloped straight baseline per
// line, its font sized so the run spans the baseline and its glyphs squashed to 0.8 of the line's height; the
// baseline lifted a fifth of the height above the line's bottom edge, which is what the points are.
func layer(_ spec: [String: Any], _ out: String) {
    guard let W = spec["width"] as? Double, let H = spec["height"] as? Double else { fail("layer needs width, height") }
    var media = CGRect(x: 0, y: 0, width: W, height: H)
    guard let ctx = CGContext(URL(fileURLWithPath: out) as CFURL, mediaBox: &media, nil) else { fail("cannot write \(out)") }
    ctx.beginPDFPage(nil)
    ctx.setTextDrawingMode(.invisible)
    for l in spec["lines"] as? [[String: Any]] ?? [] {
        guard let text = l["text"] as? String, let b = l["baseline"] as? [[Double]], b.count == 2,
              let h = l["height"] as? Double, h > 0 else { continue }
        let p0 = CGPoint(x: b[0][0] * W, y: (1 - b[0][1]) * H), p1 = CGPoint(x: b[1][0] * W, y: (1 - b[1][1]) * H)
        let length = hypot(p1.x - p0.x, p1.y - p0.y), hp = h * H
        guard length > 0 else { continue }
        let angle = atan2(p1.y - p0.y, p1.x - p0.x)
        func run(_ size: CGFloat) -> (CTLine, Double) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            return (line, CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        // Width by font size, height by the text matrix's vertical scale, as the lab's SearchableWriter does:
        // PDFKit places characters by their advances and ignores a horizontal stretch in the text matrix (measured:
        // a run stretched to 295 pt read back 137 pt long), so a stretched run ends short of its line.
        let (_, natural) = run(hp * 0.8)
        let size = natural > 0 ? hp * 0.8 * length / natural : hp * 0.8
        let (line, _) = run(size)
        let vertical = min(3, max(0.25, hp * 0.8 / size))
        // Lifted along the line's normal, so a sloped run sits where a level one would.
        let lift = hp * 0.2
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(rotationAngle: angle).scaledBy(x: 1, y: vertical)
        ctx.textPosition = CGPoint(x: p0.x - sin(angle) * lift, y: p0.y + cos(angle) * lift)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
    ctx.endPDFPage()
    ctx.closePDF()
}

// `drag` (W46.place-geom; F-placement §6.2, owner 2026-10-29). drags.json: {"lines": [{"id", "expected", "start":
// [x, y], "end": [x, y]}]}, normalised top-left. Each line is a PDFKit drag, `selection(from:to:)`, from the start
// point (inside the left end of its first truth word) to the end point (inside the right end of its last). It
// passes when the selection holds no line break and its text, whitespace collapsed, is `expected`: the line's words
// in their order, nothing missing and nothing from another line.
func drag(_ spec: [String: Any], _ doc: PDFDocument, _ pageIndex: Int) -> [String: Any] {
    guard let page = doc.page(at: pageIndex) else { fail("no page \(pageIndex)") }
    let bounds = page.bounds(for: .cropBox)
    func point(_ a: Any?) -> CGPoint? {
        guard let v = a as? [Double], v.count == 2 else { return nil }
        return CGPoint(x: bounds.minX + v[0] * bounds.width, y: bounds.minY + (1 - v[1]) * bounds.height)
    }
    var rows: [[String: Any]] = [], passed = 0
    for l in spec["lines"] as? [[String: Any]] ?? [] {
        guard let a = point(l["start"]), let b = point(l["end"]), let expected = l["expected"] as? String else { continue }
        let got = page.selection(from: a, to: b)?.string ?? ""
        let broken = got.contains("\n") || got.contains("\r")
        let flat = got.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let pass = !broken && flat == expected
        if pass { passed += 1 }
        rows.append(["id": l["id"] ?? NSNull(), "got": flat, "broken": broken, "pass": pass])
    }
    return ["lines": rows, "passed": passed, "n": rows.count]
}

let args = CommandLine.arguments
guard args.count >= 4 else { fail("usage: see the header of place_functional.swift") }
let truth = loadJSON(args[2])
let pageIndex = Int(option(args, "--page") ?? "0") ?? 0
func open(_ p: String) -> PDFDocument {
    guard let d = PDFDocument(url: URL(fileURLWithPath: p)) else { fail("cannot open \(p)") }
    return d
}
let result: [String: Any]
switch args[1] {
case "score":
    result = score(truth, open(args[3]), pageIndex)
case "words":
    guard args.count >= 5 else { fail("words needs <hyp.json>") }
    let hyp = words(open(args[3]), pageIndex, baselineFrac: Double(option(args, "--baseline-frac") ?? "0.78") ?? 0.78)
    try! JSONSerialization.data(withJSONObject: hyp).write(to: URL(fileURLWithPath: args[4]))
    result = ["words": (hyp["words"] as! [Any]).count, "lines": (hyp["lines"] as! [Any]).count]
case "layer":
    layer(truth, args[3])
    result = ["wrote": args[3]]
case "drag":
    guard args.count >= 5 else { fail("drag needs <out.json>") }
    let r = drag(truth, open(args[3]), pageIndex)
    try! JSONSerialization.data(withJSONObject: r).write(to: URL(fileURLWithPath: args[4]))
    result = ["passed": r["passed"]!, "n": r["n"]!]
case "oracle":
    let hypWords = option(args, "--words").map { loadJSON($0)["words"] as? [[String: Any]] ?? [] }
    oracle(truth, args[3], dx: Double(option(args, "--dx") ?? "0") ?? 0, dy: Double(option(args, "--dy") ?? "0") ?? 0,
           hypWords: hypWords, fit: args.contains("--fit"))
    result = ["wrote": args[3]]
default:
    fail("unknown mode \(args[1])")
}
print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
