// segbench OCR helper with line boxes: ocr.swift's Apple Vision settings (VisionClient.swift: .accurate, language
// correction on, en-US, minimum confidence 0, no custom words), writing each line's text and box as JSON, so one
// pass gives the text the app reads and the places an owner sheet draws boxes at (W47.item-fields-retruth).
// Usage: segbench-ocr-lines <jobs.tsv>   where each line is "<image path>\t<output .json path>".
// Output: {"lines": [{"text": "...", "box": [x, y, w, h]}]}, normalised 0-1, top-left origin. The lines' texts joined
// by "\n" are exactly ocr.swift's output for the image. An existing output file is skipped, so a run can be resumed.
// Exit status 1 if any image failed.
import Foundation
import Vision
import ImageIO

struct Line: Encodable { let text: String; let box: [Double] }
struct Page: Encodable { let lines: [Line] }

func transcribe(_ url: URL) throws -> Page {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "segbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "image load failed"])
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { obs -> Line? in
        guard let c = obs.topCandidates(1).first else { return nil }
        let s = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let r = obs.boundingBox   // normalised, lower-left origin
        let box = [r.minX, 1 - r.maxY, r.width, r.height].map { ($0 * 10000).rounded() / 10000 }
        return Line(text: s, box: box)
    }
    return Page(lines: lines)
}

guard CommandLine.arguments.count == 2,
      let jobs = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
    FileHandle.standardError.write("usage: segbench-ocr-lines <jobs.tsv>\n".data(using: .utf8)!)
    exit(2)
}
var failed = 0, done = 0, skipped = 0
let encoder = JSONEncoder()
for line in jobs.split(separator: "\n") {
    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let out = URL(fileURLWithPath: parts[1])
    if FileManager.default.fileExists(atPath: out.path) { skipped += 1; continue }
    do {
        let data = try autoreleasepool { try encoder.encode(transcribe(URL(fileURLWithPath: parts[0]))) }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = out.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.moveItem(at: tmp, to: out)
        done += 1
        if done % 25 == 0 { print("ocr-lines: \(done) done") ; fflush(stdout) }
    } catch {
        failed += 1
        FileHandle.standardError.write("ocr-lines failed: \(parts[0]): \(error.localizedDescription)\n".data(using: .utf8)!)
    }
}
print("ocr-lines: done \(done), skipped \(skipped), failed \(failed)")
exit(failed > 0 ? 1 : 0)
