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
/// before and after its read. With `LABELGEMMA_PROCESSFILES_OUT=<dir>` the manifest's photos instead go through
/// Process Files' label stage (`processFiles`), under the style the defaults select.
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
        guard !didRun, let manifest = env["LABELGEMMA_VERIFY"] else { return }
        // A long headless run has no window, so macOS may quit the app under memory pressure: it did after 156 reads.
        ProcessInfo.processInfo.disableAutomaticTermination("label verification run")
        ProcessInfo.processInfo.disableSuddenTermination()
        if let folder = env["LABELGEMMA_PROCESSFILES_OUT"] {
            didRun = true
            Task { @MainActor in await processFiles(manifest: URL(fileURLWithPath: manifest),
                                                    out: URL(fileURLWithPath: folder, isDirectory: true)) }
            return
        }
        guard let out = env["LABELGEMMA_VERIFY_OUT"] else { return }
        didRun = true
        Task { @MainActor in await run(manifest: URL(fileURLWithPath: manifest), out: URL(fileURLWithPath: out)) }
    }

    /// Process Files' label stage (`recordContainerLabels`) on the manifest's photos as a finished run's box and folder
    /// labels, each with the manifest's correction as the run's rotation, under the style the defaults select. Each
    /// output is a scratch stand-in PDF in `out`; the stage writes `out/.archivesuite/containers.json`. The summary note
    /// goes to `out/NOTE.txt`, then `out/DONE`.
    private static func processFiles(manifest: URL, out: URL) async {
        let fm = FileManager.default
        defer { fm.createFile(atPath: out.appendingPathComponent("DONE").path, contents: Data()) }
        guard let data = try? Data(contentsOf: manifest),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let processor = OCRProcessor()
        var jobs: [OCRJob] = []
        for (n, entry) in entries.enumerated() {
            guard let type = ItemType(rawValue: entry.type) else { continue }
            let source = URL(fileURLWithPath: entry.photo)
            let output = out.appendingPathComponent(String(format: "%05d", n + 1) + ".pdf")
            fm.createFile(atPath: output.path, contents: Data("scratch stand-in".utf8))
            var job = OCRJob(sourceURL: source)
            job.status = .succeeded
            job.classification = type == .box ? .boxLabel : .folderLabel
            job.result = OCRResult(text: "", classification: job.classification, errorMessage: nil, errorCode: nil)
                .with(classification: job.classification, rotationDegrees: entry.rotation)
            jobs.append(job)
            processor.outputURLMap[source] = output
        }
        processor.jobs = jobs
        let note = await processor.recordContainerLabels(moves: [:], outputDirectory: out, preOCRedInput: false)
        try? ("style \(ContainerLabelGemma.configuredStyle?.rawValue ?? "default")\n" + (note ?? "")).write(
            to: out.appendingPathComponent("NOTE.txt"), atomically: true, encoding: .utf8)
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
