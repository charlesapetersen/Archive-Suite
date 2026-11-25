#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import CryptoKit
import ArchiveCore

/// W49.proc-gemma-request-verify — reads scratch label photos through the label path Process Files and Live Capture
/// share (`ContainerLabelCapture.readLabel`, no gateway, so Gemma on a server on this Mac with the Vision fallback),
/// under the current or the revised external request, and writes one JSON line per read as it finishes. The harness
/// (`scripts/segbench/ct_gemma_request_verify.py`) runs the server, writes the manifest and scores the lines.
///
/// `LABELGEMMA_VERIFY=<manifest.json>`: `[{"key", "photo", "rotation", "type": "Box"|"Folder", "style":
/// "current"|"revised", "imageOut"?}]`. `LABELGEMMA_VERIFY_OUT=<results.jsonl>`: keys already there are skipped, so a
/// rerun resumes. `<out>.done` is written at the end. Photos must be scratch copies; each file's SHA-256 is recorded
/// before and after its read.
@MainActor
enum LabelGemmaVerifyTestDriver {
    private static var didRun = false

    struct Entry: Decodable {
        let key: String
        let photo: String
        let rotation: Int
        let type: String
        let style: String
        let imageOut: String?
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard !didRun, let manifest = env["LABELGEMMA_VERIFY"], let out = env["LABELGEMMA_VERIFY_OUT"] else { return }
        didRun = true
        Task { @MainActor in await run(manifest: URL(fileURLWithPath: manifest), out: URL(fileURLWithPath: out)) }
    }

    nonisolated private static func sha(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func run(manifest: URL, out: URL) async {
        defer {
            ContainerLabelGemma.styleOverride = nil
            FileManager.default.createFile(atPath: out.path + ".done", contents: Data())
        }
        guard let data = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            FileManager.default.createFile(atPath: out.path, contents: Data("{\"error\": \"manifest\"}\n".utf8))
            return
        }
        var done = Set<String>()
        if let text = try? String(contentsOf: out, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   let key = obj["key"] as? String { done.insert(key) }
            }
        } else {
            FileManager.default.createFile(atPath: out.path, contents: Data())
        }
        guard let handle = try? FileHandle(forWritingTo: out) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        for entry in entries where !done.contains(entry.key) {
            guard let type = ItemType(rawValue: entry.type),
                  let style = ContainerLabelGemma.RequestStyle(rawValue: entry.style) else { continue }
            let photo = URL(fileURLWithPath: entry.photo)
            let before = sha(photo)
            let image = ContainerLabelGemma.image(photo: photo, rotation: entry.rotation, style: style)
            if let path = entry.imageOut, let image { try? image.write(to: URL(fileURLWithPath: path)) }
            ContainerLabelGemma.styleOverride = style
            // Each read looks for the server afresh, so one failure is not carried into the next label.
            await ContainerLabelGemma.forget()
            let start = Date()
            let r = await ContainerLabelCapture.readLabel(type: type, text: "", photo: photo, rotation: entry.rotation,
                                                          gateway: nil)
            let end = Date()
            var fields: [String: [String: String]] = [:]
            for (field, value) in r.fields.values {
                fields[field.benchName] = ["value": value.value, "reader": value.reader ?? ""]
            }
            let passThrough = image != nil && image == (try? Data(contentsOf: photo))
            let record: [String: Any] = [
                "key": entry.key, "style": entry.style, "start": start.timeIntervalSince1970,
                "end": end.timeIntervalSince1970, "seconds": end.timeIntervalSince(start), "fields": fields,
                "fallback": r.fallback?.rawValue ?? NSNull(), "modelAnswered": r.modelAnswered,
                "visionAnswered": r.visionAnswered, "gatewayCalled": r.gatewayCalled,
                "imageBytes": image?.count ?? 0, "passThrough": passThrough,
                "sourceIntact": before != nil && before == sha(photo),
            ]
            guard let line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { continue }
            handle.write(line + Data("\n".utf8))
            try? handle.synchronize()
        }
    }
}

#endif
