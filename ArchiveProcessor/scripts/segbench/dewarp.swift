// W46.enh-dewarp helper: the Apple half of the dewarp test.
//
//   segbench-dewarp quad <jobs.tsv>     "<image>\t<out.json>": DetectDocumentSegmentation's page quad
//   segbench-dewarp lines <jobs.tsv>    "<image>\t<out.json>": Vision text, line quads and word boxes
//   segbench-dewarp encode <jobs.tsv>   "<image>\t<out.jpg>\t<max px>\t<quality>": the app's OCR encoder
//
// Every coordinate is normalised to the image, origin top-left, y down, in the image's stored pixel order (no
// EXIF transform, as segbench-ocr and the panel's frozen images). `lines` uses segbench-ocr's settings (the app's
// VisionClient: .accurate, language correction on, en-US), so its lines joined by newlines are segbench-ocr's text.
// `encode` copies ImageEncoding.loadImageAsJPEG (thumbnail decode to the cap, never upscale, the small-JPEG fast
// path), with the quality as a parameter so the bench's settings can go through the same code. An existing output is
// skipped, so a run resumes. Exit status 1 if any image failed.
import Foundation
import Vision
import ImageIO
import CoreGraphics

func loadCG(_ url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "segbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "image load failed"])
    }
    return image
}

// Vision's normalised points have their origin bottom-left.
func pt(_ p: CGPoint) -> [Double] { [Double(p.x), 1 - Double(p.y)] }

func quad(_ url: URL) throws -> [String: Any] {
    let image = try loadCG(url)
    let request = VNDetectDocumentSegmentationRequest()
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    var out: [String: Any] = ["width": image.width, "height": image.height]
    if let obs = request.results?.first {
        out["found"] = true
        out["confidence"] = Double(obs.confidence)
        out["corners"] = [pt(obs.topLeft), pt(obs.topRight), pt(obs.bottomRight), pt(obs.bottomLeft)]
        out["count"] = request.results?.count ?? 0
    } else {
        out["found"] = false
    }
    return out
}

func lines(_ url: URL) throws -> [String: Any] {
    let image = try loadCG(url)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    var rows: [[String: Any]] = []
    for obs in request.results ?? [] {
        guard let c = obs.topCandidates(1).first else { continue }
        let s = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { continue }
        var words: [[String: Any]] = []
        c.string.enumerateSubstrings(in: c.string.startIndex..<c.string.endIndex, options: .byWords) { w, range, _, _ in
            guard let w, let box = try? c.boundingBox(for: range) else { return }
            words.append(["text": w, "quad": [pt(box.topLeft), pt(box.topRight), pt(box.bottomRight), pt(box.bottomLeft)]])
        }
        rows.append(["text": s, "confidence": Double(c.confidence),
                     "quad": [pt(obs.topLeft), pt(obs.topRight), pt(obs.bottomRight), pt(obs.bottomLeft)],
                     "words": words])
    }
    return ["width": image.width, "height": image.height, "lines": rows]
}

func encode(_ url: URL, maxDimension: Int, quality: Double) -> Data? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let sourceType = CGImageSourceGetType(source) as? String
    let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
    let pixelW = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let pixelH = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let maxDim = max(pixelW, pixelH)
    let target = maxDim > 0 ? min(maxDim, maxDimension) : maxDimension
    let colorModel = props?[kCGImagePropertyColorModel] as? String
    let isRGBorGray = colorModel == (kCGImagePropertyColorModelRGB as String)
        || colorModel == (kCGImagePropertyColorModelGray as String)
    if sourceType == "public.jpeg" && orientation == 1 && maxDim > 0 && target >= maxDim && isRGBorGray {
        return try? Data(contentsOf: url)
    }
    let thumbOptions: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: target,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    let cg: CGImage
    if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
        cg = thumb
    } else if let full = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        cg = full
    } else {
        return nil
    }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

func write(_ data: Data, to out: URL) throws {
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = out.appendingPathExtension("tmp")
    try data.write(to: tmp)
    try FileManager.default.moveItem(at: tmp, to: out)
}

let args = CommandLine.arguments
guard args.count == 3, ["quad", "lines", "encode"].contains(args[1]),
      let jobs = try? String(contentsOfFile: args[2], encoding: .utf8) else {
    FileHandle.standardError.write("usage: segbench-dewarp quad|lines|encode <jobs.tsv>\n".data(using: .utf8)!)
    exit(2)
}
var failed = 0, done = 0, skipped = 0
for line in jobs.split(separator: "\n") {
    let parts = line.split(separator: "\t").map(String.init)
    guard parts.count >= 2 else { continue }
    let src = URL(fileURLWithPath: parts[0]), out = URL(fileURLWithPath: parts[1])
    if FileManager.default.fileExists(atPath: out.path) { skipped += 1; continue }
    do {
        try autoreleasepool {
            switch args[1] {
            case "encode":
                guard parts.count == 4, let cap = Int(parts[2]), let q = Double(parts[3]),
                      let data = encode(src, maxDimension: cap, quality: q) else {
                    throw NSError(domain: "segbench", code: 2, userInfo: [NSLocalizedDescriptionKey: "encode failed"])
                }
                try write(data, to: out)
            default:
                let obj = args[1] == "quad" ? try quad(src) : try lines(src)
                try write(try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), to: out)
            }
        }
        done += 1
        if done % 25 == 0 { print("\(args[1]): \(done) done"); fflush(stdout) }
    } catch {
        failed += 1
        FileHandle.standardError.write("\(args[1]) failed: \(parts[0]): \(error.localizedDescription)\n".data(using: .utf8)!)
    }
}
print("\(args[1]): done \(done), skipped \(skipped), failed \(failed)")
exit(failed > 0 ? 1 : 0)
