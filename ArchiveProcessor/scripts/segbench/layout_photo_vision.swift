// W46.layout-photo: Apple Vision's document request (RecognizeDocumentsRequest, macOS 26) as a layout detector.
//
//   swiftc -O layout_photo_vision.swift -o layout-photo-vision
//   layout-photo-vision <list.tsv> <out.jsonl>        # list: one "id<TAB>image path" a line
//
// One JSON line a page: {"id", "w", "h", "seconds", "regions": [{"label", "order", "score", "box"}]}, box as
// [x0, y0, x1, y1] fractions of the page with the origin top left (Vision's is bottom left). Regions are the
// document's title, paragraphs, tables and lists; order is Vision's own: paragraphs in the order the request
// gives them, a table or list placed where its first paragraph falls (or after them all when none does). The
// request also reads the text; only the boxes are kept, so the reader on the crops is the arm's reader, not Vision.
// Reads images only; writes only <out.jsonl>.
import Foundation
import Vision

struct Region: Encodable { let label: String; var order: Int; let score: Double; let box: [Double] }
struct Page: Encodable { let id: String; let w: Int; let h: Int; let seconds: Double; let regions: [Region] }

func box(_ r: NormalizedRegion) -> [Double] {
    let b = r.boundingBox
    let x0 = Double(b.origin.x), y1 = 1 - Double(b.origin.y)
    return [x0, y1 - Double(b.height), x0 + Double(b.width), y1].map { min(1, max(0, ($0 * 10000).rounded() / 10000)) }
}

func inside(_ a: [Double], _ b: [Double]) -> Bool {
    let cx = (a[0] + a[2]) / 2, cy = (a[1] + a[3]) / 2
    return cx >= b[0] && cx <= b[2] && cy >= b[1] && cy <= b[3]
}

func regions(_ d: DocumentObservation.Container) -> [Region] {
    var text: [Region] = []
    if let t = d.title { text.append(Region(label: "title", order: 0, score: 1, box: box(t.boundingRegion))) }
    for p in d.paragraphs { text.append(Region(label: "paragraph", order: 0, score: 1, box: box(p.boundingRegion))) }
    // Each block keys on the position of the first text region its box holds; ties keep tables and lists after it.
    var keyed = text.enumerated().map { (Double($0.offset), $0.element) }
    let blocks = d.tables.map { ("table", box($0.boundingRegion)) } + d.lists.map { ("list", box($0.boundingRegion)) }
    for (label, b) in blocks {
        let first = text.firstIndex { inside($0.box, b) } ?? text.count
        keyed.append((Double(first) - 0.5, Region(label: label, order: 0, score: 1, box: b)))
    }
    return keyed.sorted { $0.0 < $1.0 }.enumerated().map { var r = $0.element.1; r.order = $0.offset + 1; return r }
}

guard CommandLine.arguments.count == 3,
      let list = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
      FileManager.default.createFile(atPath: CommandLine.arguments[2], contents: nil),
      let out = FileHandle(forWritingAtPath: CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("usage: layout-photo-vision <list.tsv> <out.jsonl>\n".utf8)); exit(2)
}
let enc = JSONEncoder()
enc.outputFormatting = [.sortedKeys]
var failed = 0
for line in list.split(separator: "\n") {
    let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard f.count == 2, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: f[1]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write(Data("unreadable: \(line)\n".utf8)); failed += 1; continue
    }
    let t0 = Date()
    let done = DispatchSemaphore(value: 0)
    var found: [Region]?
    Task {
        defer { done.signal() }
        guard let obs = try? await RecognizeDocumentsRequest().perform(on: image) else { return }
        found = obs.flatMap { regions($0.document) }
    }
    done.wait()
    guard let found else { FileHandle.standardError.write(Data("request failed: \(f[0])\n".utf8)); failed += 1; continue }
    let page = Page(id: f[0], w: image.width, h: image.height, seconds: Date().timeIntervalSince(t0), regions: found)
    out.write(try! enc.encode(page)); out.write(Data("\n".utf8))
}
exit(failed == 0 ? 0 : 1)
