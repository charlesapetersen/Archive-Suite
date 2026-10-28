// W46.layout-order helper, two modes:
//
//   layout-order colsort  < pages.json   the Vision OCR app's own column sort on given boxes
//   layout-order lines <image> <out.json> [<image> <out.json> ...]   Apple Vision's text lines
//
// `colsort` reads `[{"aspect": height/width, "boxes": [[x, y, w, h], ...]}, ...]` (0-1 page fractions,
// top-left origin, the order the boxes are given in is the one kept inside a column) and writes each page's
// box indices in `SearchableWriter.columnOrdered`'s order. It is compiled against the lab repository's
// sources, so it runs the app's code rather than a copy of it (layout_order.py `build_helper` does it):
//
//   swiftc -O -o <bin> layout_order.swift ~/Claude/vision-ocr/Sources/*.swift (less App.swift)
//
// `lines` runs Vision at the app's settings (VisionClient.swift: .accurate, language correction on, en-US)
// and writes `{"width":, "height":, "lines": [{"box": [x0, y0, x1, y1], "text":}, ...]}`, boxes as 0-1 page
// fractions with a top-left origin, lines in the order Vision returned them. An existing output is skipped.
import AppKit
import Foundation
import Vision

struct ColsortPage: Decodable { let aspect: Double; let boxes: [[Double]] }

func colsort() throws {
    let pages = try JSONDecoder().decode([ColsortPage].self, from: FileHandle.standardInput.readDataToEndOfFile())
    var out: [[Int]] = []
    for p in pages {
        // The index rides in `text`, which `columnOrdered` only carries along.
        let obs = p.boxes.enumerated().map { i, b in
            SearchableWriter.Observation(boundingBox: .init(x: b[0], y: b[1], width: b[2], height: b[3]),
                                         text: String(i), confidence: 1)
        }
        out.append(SearchableWriter.columnOrdered(obs, aspect: p.aspect).map { Int($0.text)! })
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(out))
}

func visionLines(_ image: URL, _ out: URL) throws {
    if FileManager.default.fileExists(atPath: out.path) { return }
    guard let src = CGImageSourceCreateWithURL(image as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "layout-order", code: 1, userInfo: [NSLocalizedDescriptionKey: "unreadable \(image.path)"])
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    let lines: [[String: Any]] = (request.results ?? []).compactMap { o in
        guard let text = o.topCandidates(1).first?.string else { return nil }
        let b = o.boundingBox
        return ["box": [b.minX, 1 - b.maxY, b.maxX, 1 - b.minY], "text": text]
    }
    let doc: [String: Any] = ["width": cg.width, "height": cg.height, "lines": lines]
    try JSONSerialization.data(withJSONObject: doc).write(to: out)
}

let args = CommandLine.arguments
do {
    switch args.count > 1 ? args[1] : "" {
    case "colsort":
        try colsort()
    case "lines" where args.count >= 4 && args.count % 2 == 0:
        var failed = false
        for k in stride(from: 2, to: args.count, by: 2) {
            do { try visionLines(URL(fileURLWithPath: args[k]), URL(fileURLWithPath: args[k + 1])) }
            catch { failed = true; FileHandle.standardError.write("\(args[k]): \(error)\n".data(using: .utf8)!) }
        }
        exit(failed ? 1 : 0)
    default:
        FileHandle.standardError.write("usage: layout-order colsort < pages.json | lines <image> <out.json> ...\n"
            .data(using: .utf8)!)
        exit(2)
    }
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
    exit(1)
}
