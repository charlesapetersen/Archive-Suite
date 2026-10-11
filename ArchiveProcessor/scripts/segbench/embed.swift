// segbench embedding helper (W36.seg-features, checkpoint 2): on-device embeddings from the OS frameworks
// the Processor app could call directly — no model download, nothing leaves the Mac.
//   image <path>  → Vision's VNGenerateImageFeaturePrintRequest vector (revision as the OS default)
//   text <path>   → NaturalLanguage's English sentence embedding of three spans of the file's text:
//                   the whole page (first WHOLE_CHARS characters), its first HEAD_CHARS and its last HEAD_CHARS
// Usage: segbench-embed < jobs   where each stdin line is "image\t<path>" or "text\t<path>".
// Writes one JSON object per input line to stdout, in order: {"kind":…, "path":…, "vec":[…]} for an image,
// {"kind":"text", "path":…, "whole":[…]|null, "head":[…]|null, "tail":[…]|null} for text (null when the span is
// empty or the embedding has no vector for it), or {"kind":…, "path":…, "error":"…"}.
import Foundation
import Vision
import ImageIO
import NaturalLanguage

let WHOLE_CHARS = 2000
let HEAD_CHARS = 400

func imagePrint(_ path: String) throws -> [Float] {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "segbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "image load failed"])
    }
    let request = VNGenerateImageFeaturePrintRequest()
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    guard let obs = request.results?.first as? VNFeaturePrintObservation else {
        throw NSError(domain: "segbench", code: 2, userInfo: [NSLocalizedDescriptionKey: "no feature print"])
    }
    var out = [Float](repeating: 0, count: obs.elementCount)
    obs.data.withUnsafeBytes { raw in
        switch obs.elementType {
        case .float:
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<obs.elementCount { out[i] = p[i] }
        case .double:
            let p = raw.bindMemory(to: Double.self)
            for i in 0..<obs.elementCount { out[i] = Float(p[i]) }
        default:
            break
        }
    }
    return out
}

func squash(_ s: Substring) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func textVectors(_ path: String, _ emb: NLEmbedding) throws -> [String: [Double]?] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let spans: [String: String] = [
        "whole": squash(text.prefix(WHOLE_CHARS)),
        "head": squash(text.prefix(HEAD_CHARS)),
        "tail": squash(text.suffix(HEAD_CHARS)),
    ]
    var out: [String: [Double]?] = [:]
    for (k, s) in spans {
        out[k] = s.isEmpty ? nil : emb.vector(for: s)
    }
    return out
}

func emit(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

let embedding = NLEmbedding.sentenceEmbedding(for: .english)
while let line = readLine() {
    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let (kind, path) = (parts[0], parts[1])
    do {
        switch kind {
        case "image":
            emit(["kind": kind, "path": path, "vec": try imagePrint(path)])
        case "text":
            guard let emb = embedding else { throw NSError(domain: "segbench", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "no English sentence embedding on this OS"]) }
            var obj: [String: Any] = ["kind": kind, "path": path]
            for (k, v) in try textVectors(path, emb) { obj[k] = v.map { $0 as Any } ?? NSNull() }
            emit(obj)
        default:
            throw NSError(domain: "segbench", code: 4, userInfo: [NSLocalizedDescriptionKey: "unknown kind \(kind)"])
        }
    } catch {
        emit(["kind": kind, "path": path, "error": error.localizedDescription])
    }
}
