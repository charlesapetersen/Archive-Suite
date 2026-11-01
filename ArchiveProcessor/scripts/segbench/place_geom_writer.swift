// W46.place-geom — the Vision OCR lab's own text-layer writer, driven from a JSON of lines (F-placement §2: "Our
// Vision OCR writer draws one run per Vision line in Helvetica and fits the width by font size").
//
// Compiled against the lab's sources rather than a replica of them, as the lab's Tools/README.md requires:
//
//     mkdir -p /tmp/pgw && cp place_geom_writer.swift /tmp/pgw/main.swift
//     swiftc -O -o /tmp/place_geom_writer -target "$(uname -m)-apple-macos13.0" \
//       $(ls ~/Claude/vision-ocr/Sources/*.swift | grep -v App.swift) /tmp/pgw/main.swift
//
//     place_geom_writer <jobs.json>
//
// jobs.json: [{"out": PDF path, "width": points, "height": points, "lines": [{"text", "box": [x, y, w, h]}]}], boxes
// normalised with a top-left origin, as `SearchableWriter.BoundingBox` takes them. Each job writes a one-page PDF that
// carries the invisible layer only (`drawImages: false`): selection and Find read the text, not the picture. A blank
// page of the job's size stands in as `visible`, which compose needs for the page count and geometry.
// `joinHyphenated: false`, so every arm's layer holds the same words (the join is the same on every arm, and
// leaving it out keeps a truth line's expected words what Vision read). Prints the lines compose could not place.

import CoreGraphics
import Foundation

struct Job: Decodable {
    struct Line: Decodable { let text: String; let box: [Double] }
    let out: String
    let width: Double
    let height: Double
    let lines: [Line]
}

let args = CommandLine.arguments
guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]),
      let jobs = try? JSONDecoder().decode([Job].self, from: data) else {
    FileHandle.standardError.write("usage: place_geom_writer <jobs.json>\n".data(using: .utf8)!)
    exit(2)
}

let blankDir = FileManager.default.temporaryDirectory.appendingPathComponent("place-geom-blank-\(getpid())")
try? FileManager.default.createDirectory(at: blankDir, withIntermediateDirectories: true)
var unplaced: [[String: Any]] = []
for job in jobs {
    let blank = blankDir.appendingPathComponent("\(Int(job.width))x\(Int(job.height)).pdf")
    if !FileManager.default.fileExists(atPath: blank.path) {
        var media = CGRect(x: 0, y: 0, width: job.width, height: job.height)
        guard let ctx = CGContext(blank as CFURL, mediaBox: &media, nil) else { exit(3) }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
    }
    let obs = job.lines.compactMap { l -> SearchableWriter.Observation? in
        guard l.box.count == 4, l.box[2] > 0, l.box[3] > 0 else { return nil }
        return SearchableWriter.Observation(
            boundingBox: .init(x: l.box[0], y: l.box[1], width: l.box[2], height: l.box[3]),
            text: l.text, confidence: 1)
    }
    let skipped = try SearchableWriter.compose(visible: blank, observations: [1: obs],
                                               to: URL(fileURLWithPath: job.out), drawImages: false,
                                               joinHyphenated: false)
    for s in skipped { unplaced.append(["out": job.out, "text": s.text, "reason": s.reason]) }
}
try? FileManager.default.removeItem(at: blankDir)
let summary: [String: Any] = ["jobs": jobs.count, "unplaced": unplaced]
print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoding: .utf8)!)
