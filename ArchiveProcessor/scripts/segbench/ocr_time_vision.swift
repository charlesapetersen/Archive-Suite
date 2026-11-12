// W46.ocr-time-like-for-like: Apple Vision timed per page in one process, with ocr.swift's settings
// (VisionClient.swift: .accurate, language correction on, en-US, no custom words). One warm-up page first (the
// recogniser's load, kept apart as the MLX readers' load is), then each page `rounds` times; the time covers the
// JPEG decode and the recognition, as the MLX readers' wall covers their image load and generation.
// Usage: segbench-ocr-time <images.txt> <rounds>   prints one JSON object: {warmup_s, pages: {path: [s, ...]}}
import Foundation
import Vision
import ImageIO

func transcribe(_ url: URL) throws -> Int {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "segbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "image load failed"])
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).count
}

let args = CommandLine.arguments
guard args.count == 3, let rounds = Int(args[2]), rounds > 0,
      let list = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write("usage: segbench-ocr-time <images.txt> <rounds>\n".data(using: .utf8)!)
    exit(2)
}
let paths = list.split(separator: "\n").map(String.init)
var t0 = Date()
_ = try autoreleasepool { try transcribe(URL(fileURLWithPath: paths[0])) }
let warmup = Date().timeIntervalSince(t0)
var pages: [String: [Double]] = [:], lines: [String: Int] = [:]
for _ in 0..<rounds {
    for p in paths {
        t0 = Date()
        let n = try autoreleasepool { try transcribe(URL(fileURLWithPath: p)) }
        pages[p, default: []].append(Date().timeIntervalSince(t0))
        lines[p] = n
    }
}
let out: [String: Any] = ["warmup_s": warmup, "pages": pages, "lines": lines]
print(String(data: try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]), encoding: .utf8)!)
