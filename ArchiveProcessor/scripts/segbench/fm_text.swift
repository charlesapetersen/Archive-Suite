// segbench text helper for W46.r1-foundation: the macOS 27 on-device Foundation Model, text in, text out.
// Usage: segbench-fm-text <jobs.tsv> [--guided]   each line is "<prompt .txt path>\t<reply .txt path>"
// --guided: guided generation into the segmentation window's shape (Window below, the k3-t schema's fields and
// enums), the reply written as its JSON; without it the reply is free text, as the prompt asks.
// A "<reply>.json" sidecar records seconds, input and output tokens (session usage) and the failure kind if any.
// An existing sidecar is skipped, so a run can be resumed. Exit 1 if any prompt failed.
// Greedy sampling, one fresh session per prompt, permissiveContentTransformations guardrails (the prompt carries
// archival OCR text), output capped at 2,048 tokens. On-device only: PrivateCloudComputeLanguageModel is never used.
import Foundation
import FoundationModels

let cap = 2048

@Generable struct PageKind {
    var page: Int
    @Guide(.anyOf(["box", "folder", "document"])) var kind: String
}
@Generable struct Boundary {
    var between: [Int]
    @Guide(.anyOf(["new", "continue"])) var decision: String
    var cue: String
    var confidence: Double
}
@Generable struct Window {
    var pages: [PageKind]
    var boundaries: [Boundary]
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

@main struct Main { static func main() async {
    let args = CommandLine.arguments
    let guided = args.count == 3 && args[2] == "--guided"
    guard args.count == 2 || guided, let jobs = try? String(contentsOfFile: args[1], encoding: .utf8) else {
        FileHandle.standardError.write("usage: segbench-fm-text <jobs.tsv> [--guided]\n".data(using: .utf8)!)
        exit(2)
    }
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
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
        var rec: [String: Any] = ["prompt": parts[0], "cap": cap, "guided": guided]
        let t0 = Date()
        var session: LanguageModelSession?
        do {
            let prompt = try String(contentsOfFile: parts[0], encoding: .utf8)
            session = LanguageModelSession(model: model)
            if guided {
                let response = try await session!.respond(to: prompt, generating: Window.self, options: options)
                try writeAtomic(response.rawContent.jsonString, out)
            } else {
                let response = try await session!.respond(to: prompt, options: options)
                try writeAtomic(response.content, out)
            }
            let outTokens = session!.usage.output.totalTokenCount
            rec["ok"] = outTokens < cap
            if outTokens >= cap { rec["failure"] = "length"; failed += 1 } else { done += 1 }
        } catch {
            rec["ok"] = false
            rec["failure"] = failureKind(error)
            failed += 1
            FileHandle.standardError.write("fm-text failed: \(parts[0]): \(rec["failure"]!)\n".data(using: .utf8)!)
        }
        rec["seconds"] = Date().timeIntervalSince(t0)
        if let u = session?.usage { rec["input_tokens"] = u.input.totalTokenCount; rec["output_tokens"] = u.output.totalTokenCount }
        if let d = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) { try? writeAtomic(s, side) }
        if (done + failed) % 10 == 0 { print("fm-text: \(done) done, \(failed) failed"); fflush(stdout) }
    }
    print("fm-text: done \(done), skipped \(skipped), failed \(failed)")
    exit(failed > 0 ? 1 : 0)
}}
