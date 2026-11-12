// prosebench — W40.reader-prose-model. Reads PDFs read-only (scratch copies only), writes JSON lines to the
// directory it is given. Commands:
//   extract LIST OUT.jsonl     page 1 of each PDF in LIST (one path per line): its text and PDFKit's line boxes,
//                              taken as the Reader takes a whole-page selection (PDFPaneView.layoutLines)
//   render LIST DIR            page 1 of each PDF in LIST as DIR/<n>.png, 1600 px on the long side (truth drafts)
//   rules PAGES.jsonl OUT      the Reader's rules: layoutRows, then structure; one label per row
//   fm RULES.jsonl OUT [N [IMGDIR]]  the on-device model labels the same rows (with IMGDIR, seeing the page too);
//                              the app assembles; the word guard checks
// Labels: C continues the unit before, P a new paragraph, H a heading, I1..I4 a list item at that level.
import Foundation
import PDFKit
import AppKit
import FoundationModels

let args = CommandLine.arguments
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }
guard args.count >= 4 else { fail("usage: prosebench extract|render|rules|fm IN OUT [N]") }

struct Row: Codable { var t: String; var x: Double; var y: Double; var w: Double; var h: Double }
struct PageRec: Codable { var id: String; var raw: String; var lines: [Row] }
struct RulesRec: Codable { var id: String; var raw: String; var rows: [Row]; var geometry: Bool; var labels: [String]
                           var guardOK: Bool; var text: String? }
struct FMRec: Codable { var id: String; var labels: [String]?; var guardOK: Bool; var text: String?; var error: String?
                        var wall: Double; var promptChars: Int; var footprintMB: Double }

func readLines(_ path: String) -> [String] {
    (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
}
func writeJSONL<T: Encodable>(_ recs: [T], _ path: String) {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let body = recs.map { String(data: try! enc.encode($0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
    try! body.write(toFile: path, atomically: true, encoding: .utf8)
}
func readJSONL<T: Decodable>(_ path: String, _ t: T.Type) -> [T] {
    readLines(path).map { try! JSONDecoder().decode(T.self, from: $0.data(using: .utf8)!) }
}
func words(_ s: String) -> [Substring] {
    s.replacingOccurrences(of: "\u{FFFC}", with: " ").split(whereSeparator: \.isWhitespace)
}
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func extract(_ list: String, _ out: String) {
    var recs: [PageRec] = []
    for path in readLines(list) {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: 0),
              let sel = page.selection(for: page.bounds(for: .mediaBox)), let raw = sel.string, !raw.isEmpty
        else { continue }
        let lines = sel.selectionsByLine().compactMap { l -> Row? in
            guard let p = l.pages.first, p === page, let t = l.string else { return nil }
            let b = l.bounds(for: p)
            return Row(t: t, x: b.minX, y: b.minY, w: b.width, h: b.height)
        }
        recs.append(PageRec(id: path, raw: raw, lines: lines))
    }
    writeJSONL(recs, out)
    print("extracted \(recs.count) pages")
}

func render(_ list: String, _ dir: String) {
    for (n, path) in readLines(list).enumerated() {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: 0) else { continue }
        let b = page.bounds(for: .mediaBox)
        let scale = 1600 / max(b.width, b.height)
        let img = page.thumbnail(of: NSSize(width: b.width * scale, height: b.height * scale), for: .mediaBox)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        try! png.write(to: URL(fileURLWithPath: "\(dir)/\(n).png"))
    }
}

func cgLines(_ rows: [Row]) -> [CopyTextLine] {
    rows.map { CopyTextLine(text: $0.t, box: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h), page: 0) }
}
func label(_ k: CopyTextCleaner.Kind) -> String {
    switch k {
    case .paragraph: return "P"
    case .heading: return "H"
    case .item(let level, _): return "I\(min(level, 3) + 1)"
    }
}

func rules(_ pages: String, _ out: String) {
    var recs: [RulesRec] = []
    for p in readJSONL(pages, PageRec.self) {
        let rows = CopyTextCleaner.layoutRows(cgLines(p.lines))
        let geometry = !rows.isEmpty && words(rows.map(\.text).joined(separator: "\n")) == words(p.raw)
        let units = CopyTextCleaner.structure(rows, columns: true)
        var labels: [String] = []
        for u in units { labels.append(label(u.kind)); labels += Array(repeating: "C", count: u.lines.count - 1) }
        let text = CopyTextCleaner.assemble(units, raw: p.raw, options: .init())
        recs.append(RulesRec(id: p.id, raw: p.raw,
                             rows: rows.map { Row(t: $0.text, x: $0.box.minX, y: $0.box.minY, w: $0.box.width, h: $0.box.height) },
                             geometry: geometry && labels.count == rows.count, labels: labels, guardOK: text != nil, text: text))
    }
    writeJSONL(recs, out)
    print("rules: \(recs.count) pages, \(recs.filter(\.geometry).count) on the geometry path")
}

/// The units the labels describe; the app, not the model, puts the text together.
func units(_ rows: [Row], _ labels: [String]) -> [CopyTextCleaner.Unit] {
    var us: [CopyTextCleaner.Unit] = []
    for (r, l) in zip(rows, labels) {
        let t = r.t.trimmingCharacters(in: .whitespaces)
        switch l {
        case "C" where !us.isEmpty: us[us.count - 1].lines.append(t)
        case "H": us.append(.init(kind: .heading, lines: [t]))
        case let s where s.hasPrefix("I"):
            let level = (Int(s.dropFirst()) ?? 1) - 1
            us.append(.init(kind: .item(level: level, markerLength: CopyTextCleaner.listMarker(t)?.length ?? 0), lines: [t]))
        default: us.append(.init(kind: .paragraph, lines: [t]))
        }
    }
    return us
}

func median(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[(xs.count - 1) / 2] }
func pct(_ xs: [Double], _ p: Double) -> Double {
    xs.isEmpty ? 0 : xs.sorted()[Int((Double(xs.count - 1) * p).rounded())]
}

/// The rows as the model reads them: number, indent from the margin in line heights, the gap above in usual
/// line spacings, width as a share of the text width, then the text.
func describe(_ rows: [Row]) -> String {
    let em = max(median(rows.map(\.h)), 0.001)
    let left = pct(rows.map(\.x), 0.25), right = pct(rows.map { $0.x + $0.w }, 0.8)
    let mids = rows.map { $0.y + $0.h / 2 }
    let spacing = max(median(zip(mids, mids.dropFirst()).map { $0 - $1 }.filter { $0 > 0 }), em)
    return rows.enumerated().map { i, r in
        let indent = (r.x - left) / em
        let gap = i == 0 ? 0 : (mids[i - 1] - mids[i]) / spacing
        let width = r.w / max(right - left, em)
        return String(format: "%d | indent %.1f | gap %.1f | width %.2f | ", i + 1, indent, gap, width)
            + r.t.trimmingCharacters(in: .whitespaces)
    }.joined(separator: "\n")
}

let instructions = """
You label the lines of a typed document page so that an app can rebuild its paragraphs, headings and lists. \
You never rewrite or repeat the text. For each numbered line give exactly one label, in order:
C = the line continues the paragraph or list item of the line before;
P = the line starts a new paragraph;
H = the line is a heading or title standing on its own line;
I1 = the line starts a list item; I2 = it starts a sub-item of an I1 item; I3 and I4 = deeper sub-items.
Each line shows its indent from the left margin in line heights, the vertical gap above it in usual line \
spacings (1.0 is the normal spacing; a larger gap often separates paragraphs), and its width as a share of the \
text width (a short line often ends a paragraph). A list item usually begins with a marker such as 1. (a) or a \
bullet. A line that starts with a lower-case word, or follows a line ending in a hyphen, usually continues.
"""

/// With `images`, the page's picture (`<images>/<n>.png`, n its place in RULES, as `render` writes) goes with
/// the rows: the macOS 27 model takes image attachments.
/// PROSE_SHOT=1: the instructions also carry one worked example (invented text).
let example = """

Example. Lines:
1 | indent 0.0 | gap 0.0 | width 0.40 | MINUTES OF THE BOARD
2 | indent 0.0 | gap 2.2 | width 1.00 | The board met on the fourth of May with all members present and
3 | indent 0.0 | gap 1.0 | width 0.97 | agreed, after a long discussion of the accounts, the following:
4 | indent 2.1 | gap 1.0 | width 0.90 | 1. That the fund be divided between the two schools named in
5 | indent 3.6 | gap 1.0 | width 0.60 | the letter of March.
6 | indent 4.2 | gap 1.0 | width 0.85 | (a) The first share to be paid at once.
7 | indent 2.1 | gap 1.0 | width 0.92 | 2. That the secretary write to both schools.
8 | indent 0.0 | gap 2.0 | width 0.99 | The meeting closed at noon. The next will be held in the library
9 | indent 0.0 | gap 1.0 | width 0.30 | in June.
Labels: H, P, C, I1, C, I2, I1, P, C
"""

func fm(_ rulesPath: String, _ out: String, _ limit: Int?, images: String?) async {
    // PROSE_PERMISSIVE=1: the guardrails Apple offers for transforming the user's own text.
    let model = ProcessInfo.processInfo.environment["PROSE_PERMISSIVE"] == "1"
        ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
    guard case .available = model.availability else { fail("model: \(model.availability)") }
    let labelSchema = DynamicGenerationSchema(name: "Label", anyOf: ["C", "P", "H", "I1", "I2", "I3", "I4"])
    var recs: [FMRec] = []
    let pages = readJSONL(rulesPath, RulesRec.self).enumerated().filter { $0.element.geometry }
    for (k, p) in pages.prefix(limit ?? pages.count) {
        let n = p.rows.count
        let prompt = (images == nil ? "" : "The page's photo is attached; use it to see the layout. ")
            + "The page has \(n) lines. Give \(n) labels.\n\n" + describe(p.rows)
        let t0 = Date()
        var rec = FMRec(id: p.id, labels: nil, guardOK: false, text: nil, error: nil, wall: 0,
                        promptChars: prompt.count, footprintMB: 0)
        do {
            let root = DynamicGenerationSchema(name: "PageLabels", properties: [
                .init(name: "labels", schema: DynamicGenerationSchema(arrayOf: labelSchema, minimumElements: n,
                                                                      maximumElements: n))])
            let schema = try GenerationSchema(root: root, dependencies: [])
            let shot = ProcessInfo.processInfo.environment["PROSE_SHOT"] == "1"
            let session = LanguageModelSession(model: model, instructions: instructions + (shot ? example : ""))
            let options = GenerationOptions(samplingMode: .greedy)
            let r: LanguageModelSession.Response<GeneratedContent>
            if let images {
                let image = Attachment(imageURL: URL(fileURLWithPath: "\(images)/\(k).png"))
                r = try await session.respond(schema: schema, options: options) { prompt; image }
            } else {
                r = try await session.respond(to: prompt, schema: schema, options: options)
            }
            let labels = try r.content.value([String].self, forProperty: "labels")
            rec.labels = labels
            if labels.count == n {
                rec.text = CopyTextCleaner.assemble(units(p.rows, labels), raw: p.raw, options: .init())
                rec.guardOK = rec.text != nil
            } else {
                rec.error = "count \(labels.count) of \(n)"
            }
        } catch {
            rec.error = String(describing: error).prefix(300).description
        }
        rec.wall = Date().timeIntervalSince(t0)
        rec.footprintMB = footprintMB()
        recs.append(rec)
        print(String(format: "[%d/%d] %.1fs %@", recs.count, min(limit ?? pages.count, pages.count), rec.wall,
                     rec.error ?? (rec.guardOK ? "ok" : "guard refused")))
        writeJSONL(recs, out)
    }
}

switch args[1] {
case "extract": extract(args[2], args[3])
case "render": render(args[2], args[3])
case "rules": rules(args[2], args[3])
case "fm": await fm(args[2], args[3], args.count > 4 ? Int(args[4]) : nil, images: args.count > 5 ? args[5] : nil)
default: fail("unknown command \(args[1])")
}
