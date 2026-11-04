// segbench OCR helper for W46.r1-foundation: the macOS 27 on-device Foundation Model
// (SystemLanguageModel.default, image attachment) as a free first reader.
// Usage: segbench-fm-ocr <jobs.tsv> [max-long-side] [default|permissive]
//        segbench-fm-ocr --tokens <image> <out.json>   image tokens against the long side sent (256-4000 px)
//   each line is "<image path>\t<output .txt path>"; a "<output>.json" sidecar records seconds,
//   input and output tokens (session usage), the image size sent, and the failure kind if any.
// max-long-side (default 0 = the image as stored) downsamples before attaching, for the resolution arm.
// Guardrails default to permissiveContentTransformations, Apple's setting for transforming the user's own
// text (OCR is one); `default` measures the stock guardrail, which refuses some archival pages.
// Output is capped at 4,096 tokens: the 96's longest truth is 6,669 characters (about 2,000 tokens), and the
// context is 8,192 tokens in all, so a page that reaches the cap is a repetition loop, recorded as "length".
// An existing output .txt or .json is skipped, so a run can be resumed. Exit 1 if any page failed.
// Greedy sampling, one fresh session per page (no carry-over between pages). On-device only:
// PrivateCloudComputeLanguageModel is never used.
import Foundation
import FoundationModels
import CoreGraphics
import ImageIO

let instructions = """
You are an OCR engine. Transcribe all the text on the page image exactly as written, \
line by line, in reading order. Keep the original spelling, capitalisation and punctuation. \
Do not summarise, translate, correct or explain. Output only the transcription.
"""
let ask = "Transcribe this page."
let cap = 4096

func loadImage(_ url: URL, maxLongSide: Int) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw NSError(domain: "segbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "image load failed"])
    }
    if maxLongSide > 0 {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxLongSide,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        if let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return t }
    }
    guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "segbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "image decode failed"])
    }
    return image
}

func failureKind(_ error: Error) -> String {
    if let e = error as? LanguageModelError {
        switch e {
        case .contextSizeExceeded: return "context"
        case .guardrailViolation: return "guardrail"
        case .refusal: return "refusal"
        case .timeout: return "timeout"
        default: return "model:\(e)"
        }
    }
    return "other:\(error)"
}

func writeAtomic(_ s: String, _ url: URL) throws {
    let tmp = url.appendingPathExtension("tmp")
    try s.write(to: tmp, atomically: true, encoding: .utf8)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: tmp, to: url)
}

func tokenProbe(_ image: String, _ out: String) async throws {
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    var rows: [[String: Any]] = []
    for side in [256, 512, 768, 1024, 1536, 2400, 4000] {
        let img = try loadImage(URL(fileURLWithPath: image), maxLongSide: side)
        let counted = try await model.tokenCount(for: Attachment(img))
        let session = LanguageModelSession(model: model)
        _ = try await session.respond(options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 5)) {
            "Say OK."; Attachment(img)
        }
        rows.append(["side": side, "w": img.width, "h": img.height, "tokenCount": counted,
                     "input": session.usage.input.totalTokenCount])
    }
    let d = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    try writeAtomic(String(data: d, encoding: .utf8)!, URL(fileURLWithPath: out))
}

@main struct Main { static func main() async {
    let args = CommandLine.arguments
    if args.count == 4 && args[1] == "--tokens" {
        do { try await tokenProbe(args[2], args[3]); exit(0) } catch {
            FileHandle.standardError.write("token probe failed: \(error)\n".data(using: .utf8)!); exit(1)
        }
    }
    guard args.count >= 2, let jobs = try? String(contentsOfFile: args[1], encoding: .utf8) else {
        FileHandle.standardError.write("usage: segbench-fm-ocr <jobs.tsv> [max-long-side]\n".data(using: .utf8)!)
        exit(2)
    }
    let maxSide = args.count >= 3 ? Int(args[2]) ?? 0 : 0
    let permissive = args.count < 4 || args[3] != "default"
    let model = permissive ? SystemLanguageModel(guardrails: .permissiveContentTransformations) : SystemLanguageModel.default
    guard case .available = model.availability else {
        FileHandle.standardError.write("on-device model unavailable: \(model.availability)\n".data(using: .utf8)!)
        exit(3)
    }
    let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: cap)
    var failed = 0, done = 0, skipped = 0
    for line in jobs.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let out = URL(fileURLWithPath: parts[1])
        let side = out.appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: side.path) { skipped += 1; continue }
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        var rec: [String: Any] = ["image": parts[0], "max_long_side": maxSide,
                                  "guardrails": permissive ? "permissive" : "default", "cap": cap]
        let t0 = Date()
        var session: LanguageModelSession?
        do {
            let image = try loadImage(URL(fileURLWithPath: parts[0]), maxLongSide: maxSide)
            rec["sent_w"] = image.width; rec["sent_h"] = image.height
            let attachment = Attachment(image)
            rec["image_tokens"] = (try? await model.tokenCount(for: attachment)) ?? -1
            session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session!.respond(options: options) { ask; attachment }
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            try writeAtomic(text, out)
            let outTokens = session!.usage.output.totalTokenCount
            rec["ok"] = outTokens < cap
            if outTokens >= cap { rec["failure"] = "length"; failed += 1 } else { done += 1 }
        } catch {
            rec["ok"] = false
            rec["failure"] = failureKind(error)
            failed += 1
            FileHandle.standardError.write("fm-ocr failed: \(parts[0]): \(rec["failure"]!)\n".data(using: .utf8)!)
        }
        rec["seconds"] = Date().timeIntervalSince(t0)
        if let u = session?.usage { rec["input_tokens"] = u.input.totalTokenCount; rec["output_tokens"] = u.output.totalTokenCount }
        if let d = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) { try? writeAtomic(s, side) }
        if (done + failed) % 10 == 0 { print("fm-ocr: \(done) done, \(failed) failed"); fflush(stdout) }
    }
    print("fm-ocr: done \(done), skipped \(skipped), failed \(failed)")
    exit(failed > 0 ? 1 : 0)
}}
