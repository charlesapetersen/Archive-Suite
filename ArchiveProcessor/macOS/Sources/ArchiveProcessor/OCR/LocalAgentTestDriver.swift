import Foundation
import AppKit

/// Headless, key-free ($0) functional test of the Local Agent CLI backend, gated by
/// `LOCALAGENT_TEST=1` (does nothing in normal use). No real model, no network, no cost: it drives the
/// REAL `LocalAgentClient` against the committed fake CLI (`scripts/localagent-fake-cli.sh`, path in
/// `LOCALAGENT_FAKE_CLI`) and verifies the REAL `OCRProcessor.PendingRun` resume-safety of the new
/// `localAgent` carrier. Writes an `ALL PASS` / `SOME FAILED` report to `LOCALAGENT_TEST_OUT` (or a
/// temp file) + NSLog, then exits. Test scaffolding only — never touches the corpus.
///
/// RUN it via `scripts/test-localagent.sh`. (The standalone `scripts/localagent-mechanism-test.swift`
/// proves the subprocess plumbing + Codable semantics with no app launch; this one proves the actual
/// `LocalAgentClient` / `PendingRun` types end-to-end.)
@MainActor
enum LocalAgentTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["LOCALAGENT_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APLocalAgent-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) { results.append("\(condition ? "PASS" : "FAIL"): \(name)") }
        func note(_ s: String) { results.append("NOTE: \(s)") }

        // ── A tiny valid JPEG the client can load (the fake CLI ignores it — it emits canned JSON). ──
        let imageURL = root.appendingPathComponent("input.jpg")
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            for x in 0..<8 { for y in 0..<8 { rep.setColor(.white, atX: x, y: y) } }
            if let data = rep.representation(using: .jpeg, properties: [:]) { try? data.write(to: imageURL) }
        }

        // ── Fake CLI path (test-localagent.sh sets LOCALAGENT_FAKE_CLI). ──────────────────────────
        let fakeCLI = ProcessInfo.processInfo.environment["LOCALAGENT_FAKE_CLI"] ?? ""
        let hasFakeCLI = !fakeCLI.isEmpty && fm.isExecutableFile(atPath: fakeCLI)

        if hasFakeCLI {
            func client(mode: String) -> LocalAgentClient {
                setenv("LOCALAGENT_FAKE_MODE", mode, 1)
                return LocalAgentClient(config: LocalAgentConfig(tool: .claude, binaryPath: fakeCLI))
            }

            // 1. Success OCR → parsed text + classification + rotation, no error.
            do {
                let r = try await client(mode: "ok").ocr(imageURL: imageURL)
                check("ocr(ok): text carries the fake OCR token", r.text?.contains("FAKE-CLI-OCR-TOKEN") == true)
                check("ocr(ok): classification parsed = documentStart", r.classification.map { "\($0)" } == "documentStart")
                check("ocr(ok): rotation parsed = 0", r.rotationDegrees == 0)
                check("ocr(ok): no error", r.errorMessage == nil && r.errorCode == nil)
            } catch { check("ocr(ok) did not throw", false); note("threw \(error)") }

            // 2. Success text completion → trimmed text back.
            do {
                let t = try await client(mode: "ok").textCompletion(prompt: "hello")
                check("textCompletion(ok): returns the fake result", t.contains("FAKE-CLI-OCR-TOKEN"))
            } catch { check("textCompletion(ok) did not throw", false); note("threw \(error)") }

            // 3. Non-zero exit → friendly error, no text, stable code (never raw stderr).
            do {
                let r = try await client(mode: "fail").ocr(imageURL: imageURL)
                check("ocr(fail): text nil + error surfaced", r.text == nil && r.errorMessage != nil)
                check("ocr(fail): errorCode = cli_exit_3", r.errorCode == "cli_exit_3")
                check("ocr(fail): message does not leak raw stderr", r.errorMessage?.contains("internal error") == false)
            } catch { check("ocr(fail) returns a result (does not throw)", false) }

            // 4. Not-logged-in stderr → mapped code + guidance.
            do {
                let r = try await client(mode: "notlogged").ocr(imageURL: imageURL)
                check("ocr(notlogged): errorCode = cli_not_logged_in", r.errorCode == "cli_not_logged_in")
                check("ocr(notlogged): message guides to sign in", r.errorMessage?.lowercased().contains("signed in") == true)
            } catch { check("ocr(notlogged) returns a result", false) }

            // 5. Non-JSON stdout → bad-response error.
            do {
                let r = try await client(mode: "garbage").ocr(imageURL: imageURL)
                check("ocr(garbage): errorCode = cli_bad_response", r.errorCode == "cli_bad_response")
            } catch { check("ocr(garbage) returns a result", false) }

            unsetenv("LOCALAGENT_FAKE_MODE")

            // 6. Missing binary → not-found (no spawn, no crash).
            check("binary resolution: invalid explicit override is authoritative",
                  LocalAgentClient.resolveBinaryPath(tool: .claude, override: "/nonexistent/claude-xyz") == nil)
            check("binary resolution: relative explicit override is rejected",
                  LocalAgentClient.resolveBinaryPath(tool: .claude, override: "scripts/localagent-fake-cli.sh") == nil)
            do {
                let bogus = LocalAgentClient(config: LocalAgentConfig(tool: .claude, binaryPath: "/nonexistent/claude-xyz"))
                let r = try await bogus.ocr(imageURL: imageURL)
                check("ocr(missing binary): errorCode = cli_not_found", r.errorCode == "cli_not_found")
            } catch { check("ocr(missing binary) returns a result", false) }
        } else {
            note("LOCALAGENT_FAKE_CLI unset/not executable → CLI functional checks skipped (run via scripts/test-localagent.sh)")
        }

        // ── REAL PendingRun resume-safety of the localAgent carrier. ─────────────────────────────
        let files = [root.appendingPathComponent("src0.jpg")]
        let outDir = root.appendingPathComponent("out", isDirectory: true)
        func makeRun(localAgent: LocalAgentConfig?) -> OCRProcessor.PendingRun {
            OCRProcessor.PendingRun(
                provider: .gemini, model: LLMProvider.gemini.models[0], thinkingLevel: nil,
                fileURLs: files, outputDirectory: outDir, enableTagging: true, enableSegmentJSON: true,
                enableCollectionSegmentation: false, confirmCollectionIDs: false,
                reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
                sendPreviousImage: false, customPrompt: nil, startedAt: Date(timeIntervalSince1970: 768_000_000),
                gatewayConfig: nil, completedResults: [:], localAgent: localAgent)
        }

        // 7. nil carrier: manifest is byte-compatible with the pre-feature format (key omitted) and
        //    round-trips to nil (an in-flight run started before this feature resumes untouched).
        let nilURL = root.appendingPathComponent("pending_nil.json")
        check("PendingRun(nil localAgent) writes", OCRProcessor._testWritePendingRun(makeRun(localAgent: nil), to: nilURL))
        if let json = try? String(contentsOf: nilURL, encoding: .utf8) {
            check("nil carrier OMITTED from manifest (byte-compatible with old format)", !json.contains("localAgent"))
        } else { check("nil manifest readable as text", false) }
        let nilLoaded = OCRProcessor._testReadPendingRun(from: nilURL)
        check("nil manifest decodes", nilLoaded != nil)
        check("resume: nil manifest → localAgent nil", nilLoaded?.localAgent == nil)
        check("resume: nil manifest preserves prior fields", nilLoaded?.fileURLs == files)

        // 8. populated carrier round-trips (a run that actually used the backend resumes on it).
        let setURL = root.appendingPathComponent("pending_set.json")
        let setCfg = LocalAgentConfig(tool: .claude, binaryPath: "/opt/homebrew/bin/claude", modelOverride: "sonnet", concurrencyCap: 1)
        _ = OCRProcessor._testWritePendingRun(makeRun(localAgent: setCfg), to: setURL)
        let setLoaded = OCRProcessor._testReadPendingRun(from: setURL)
        check("resume: populated localAgent round-trips", setLoaded?.localAgent == setCfg)

        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["LOCALAGENT_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? fm.temporaryDirectory.appendingPathComponent("archiveprocessor-localagent-result.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
