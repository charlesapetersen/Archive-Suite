// W46.place-print — Apple Vision's own word and line geometry, from both of its text APIs (F-placement test 2).
//
//     swiftc -O -parse-as-library place_print_vision.swift -o /tmp/place_print_vision
//     place_print_vision <jobs.json> <out-dir>
//
// jobs.json: [{"page": id, "image": path}]. For each page writes <out-dir>/accurate/<id>.json,
// <out-dir>/bywords/<id>.json and <out-dir>/documents/<id>.json in place_score.py's hypothesis form ({"words":
// [{"text", "box"}], "lines": [{"text", "box", "baseline"}]}, normalised, top-left origin):
//
//   accurate   VNRecognizeTextRequest revision 3 at .accurate, language correction on, language detected: the lab's
//              settings (Recogniser.makeRequest). One line per observation; a word per whitespace-separated token of
//              its top candidate, boxed by `boundingBox(for:)` (the lab writer's words, punctuation kept).
//   bywords    the same request and lines, a word per `.byWords` substring of the top candidate (punctuation off,
//              hyphen and slash compounds split): the segmentation the typed truth's words were drafted from
//              (vision_words.swift), so its box scores are not charged for a tokenising convention.
//   documents  macOS 26 RecognizeDocumentsRequest, revision 1, the same recognition options. Lines are
//              `document.text.lines`, words `document.text.words` (none for CJK or Thai, per Apple).
//
// A line's baseline is the segment between the points 0.78 of the way down its quad's left and right edges, the
// convention place_truth.py drafts truth with and place_functional.swift reads a PDF back with.

import CoreGraphics
import Foundation
import Vision

struct Job: Decodable { let page: String; let image: String }

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }

/// Normalised lower-left rect -> [x, y, w, h], top-left origin.
func topLeft(_ r: CGRect) -> [Double] { [r.minX, 1 - r.maxY, r.width, r.height] }

/// Quad corners (lower-left origin) -> a baseline 0.78 of the way down each side, top-left origin.
func baseline(tl: CGPoint, tr: CGPoint, bl: CGPoint, br: CGPoint) -> [[Double]] {
    let f = 0.78
    func at(_ top: CGPoint, _ bottom: CGPoint) -> [Double] {
        [top.x + (bottom.x - top.x) * f, 1 - (top.y + (bottom.y - top.y) * f)]
    }
    return [at(tl, bl), at(tr, br)]
}

func write(_ obj: [String: Any], _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: obj).write(to: url)
}

func accurate(_ url: URL) throws -> ([String: Any], [String: Any]) {
    let req = VNRecognizeTextRequest()
    req.revision = VNRecognizeTextRequestRevision3
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(url: url).perform([req])
    var words: [[String: Any]] = [], lines: [[String: Any]] = [], byWords: [[String: Any]] = []
    for obs in req.results ?? [] {
        guard let cand = obs.topCandidates(1).first else { continue }
        let s = cand.string
        s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byWords) { sub, range, _, _ in
            guard let sub, let b = try? cand.boundingBox(for: range)?.boundingBox else { return }
            byWords.append(["text": sub, "box": topLeft(b)])
        }
        lines.append(["text": s, "box": topLeft(obs.boundingBox),
                      "baseline": baseline(tl: obs.topLeft, tr: obs.topRight, bl: obs.bottomLeft, br: obs.bottomRight)])
        var i = s.startIndex
        while i < s.endIndex {
            guard let start = s[i...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = s[start...].firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
            if let b = try? cand.boundingBox(for: start..<end)?.boundingBox {
                words.append(["text": String(s[start..<end]), "box": topLeft(b)])
            }
            i = end
        }
    }
    return (["words": words, "lines": lines], ["words": byWords, "lines": lines])
}

func documents(_ url: URL) async throws -> [String: Any] {
    var req = RecognizeDocumentsRequest(.revision1)
    req.textRecognitionOptions.useLanguageCorrection = true
    req.textRecognitionOptions.automaticallyDetectLanguage = true
    let obs = try await req.perform(on: url)
    var words: [[String: Any]] = [], lines: [[String: Any]] = []
    func pt(_ p: NormalizedPoint) -> CGPoint { CGPoint(x: p.x, y: p.y) }
    for d in obs {
        for l in d.document.text.lines {
            lines.append(["text": l.transcript, "box": topLeft(l.boundingBox.cgRect),
                          "baseline": baseline(tl: pt(l.topLeft), tr: pt(l.topRight), bl: pt(l.bottomLeft),
                                               br: pt(l.bottomRight))])
        }
        for w in d.document.text.words ?? [] {
            words.append(["text": w.transcript, "box": topLeft(w.boundingBox.cgRect)])
        }
    }
    return ["words": words, "lines": lines]
}

@main
struct Main {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 3, let d = FileManager.default.contents(atPath: args[1]),
              let jobs = try? JSONDecoder().decode([Job].self, from: d) else { fail("usage: place_print_vision <jobs.json> <out-dir>") }
        let out = URL(fileURLWithPath: args[2])
        for arm in ["accurate", "bywords", "documents"] {
            try? FileManager.default.createDirectory(at: out.appendingPathComponent(arm), withIntermediateDirectories: true)
        }
        var n = 0
        for j in jobs {
            let url = URL(fileURLWithPath: j.image), name = j.page.replacingOccurrences(of: "/", with: "__") + ".json"
            do {
                let (acc, byw) = try accurate(url)
                try write(acc, out.appendingPathComponent("accurate").appendingPathComponent(name))
                try write(byw, out.appendingPathComponent("bywords").appendingPathComponent(name))
                try write(try await documents(url), out.appendingPathComponent("documents").appendingPathComponent(name))
                n += 1
            } catch { FileHandle.standardError.write("\(j.page): \(error)\n".data(using: .utf8)!) }
        }
        print("{\"pages\": \(n), \"of\": \(jobs.count)}")
    }
}
