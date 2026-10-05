// segbench OCR helper: Apple Vision text for each image, with the app's default settings
// (VisionClient.swift: .accurate, language correction on, en-US, minimum confidence 0, no custom words).
// Usage: segbench-ocr <jobs.tsv>   where each line is "<image path>\t<output .txt path>".
// An existing output file is skipped, so a run can be resumed. Exit status 1 if any image failed.
import Foundation
import Vision
import ImageIO

func transcribe(_ url: URL) throws -> String {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "segbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "image load failed"])
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { obs -> String? in
        guard let c = obs.topCandidates(1).first else { return nil }
        let s = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    return lines.joined(separator: "\n")
}

guard CommandLine.arguments.count == 2,
      let jobs = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
    FileHandle.standardError.write("usage: segbench-ocr <jobs.tsv>\n".data(using: .utf8)!)
    exit(2)
}
var failed = 0, done = 0, skipped = 0
for line in jobs.split(separator: "\n") {
    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let out = URL(fileURLWithPath: parts[1])
    if FileManager.default.fileExists(atPath: out.path) { skipped += 1; continue }
    do {
        let text = try autoreleasepool { try transcribe(URL(fileURLWithPath: parts[0])) }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = out.appendingPathExtension("tmp")
        try text.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(at: tmp, to: out)
        done += 1
        if done % 25 == 0 { print("ocr: \(done) done") ; fflush(stdout) }
    } catch {
        failed += 1
        FileHandle.standardError.write("ocr failed: \(parts[0]): \(error.localizedDescription)\n".data(using: .utf8)!)
    }
}
print("ocr: done \(done), skipped \(skipped), failed \(failed)")
exit(failed > 0 ? 1 : 0)
