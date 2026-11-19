#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import AppKit
import SwiftUI

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

            // 5c. W41.app-claude-plan-reading: the plan's usage limit as `claude -p --output-format json` reports it (an
            // is_error envelope on stdout, nothing on stderr), its reset read, and an error envelope never taken as text.
            let now = Date()
            func run(_ out: String, _ err: String = "", exit: Int32 = 1) -> LocalAgentClient.CLIRun {
                .init(exitCode: exit, stdout: out, stderr: err, timedOut: false, spawnFailed: false)
            }
            if case .usageLimited(let reset, let message) = LocalAgentClient.classifyClaude(
                run(#"{"type":"result","is_error":true,"result":"You've hit your limit · resets in 2s"}"#), now: now) {
                check("classify: the envelope's limit is a usage limit, reset in 2 s",
                      reset.map { abs($0.timeIntervalSince(now) - 2) < 0.5 } == true)
                check("classify: the limit message says nothing goes to a key", message.contains("nothing is sent to a key"))
            } else { check("classify: the envelope's limit is a usage limit", false) }
            if case .usageLimited(let reset, _) = LocalAgentClient.classifyClaude(
                run(#"{"is_error":true,"result":"Claude AI usage limit reached|1800000000"}"#), now: now) {
                check("classify: the epoch reset is read", reset == Date(timeIntervalSince1970: 1_800_000_000))
            } else { check("classify: the epoch form is a usage limit", false) }
            if case .usageLimited(let reset, _) = LocalAgentClient.classifyClaude(
                run("", "Error: usage limit reached. Please try again later."), now: now) {
                check("classify: a stderr limit with no reset has none", reset == nil)
            } else { check("classify: a stderr limit is a usage limit", false) }
            check("classify: an error envelope with exit 0 is no text",
                  LocalAgentClient.classifyClaude(run(#"{"is_error":true,"result":"An internal error occurred while generating"}"#,
                                                      exit: 0), now: now)
                  == .failure(code: "cli_error", message: "The Claude Code CLI reported an error: An internal error occurred while generating"))
            if case .failure(let code, _) = LocalAgentClient.classifyClaude(run("", "could not separate the pages", exit: 2), now: now) {
                check("classify: 'separate' is no usage limit for claude", code == "cli_exit_2")
            } else { check("classify: 'separate' is a failure", false) }
            check("classify: a good envelope is its result",
                  LocalAgentClient.classifyClaude(run(#"{"is_error":false,"result":"text"}"#, exit: 0), now: now) == .success("text"))

            // 5d. A page that meets the limit waits for the reset and is read on the plan again; the pause is shown while
            // it waits and gone after.
            let fast = UsageWindowPacing(grace: 0, unknownWait: 0.5, minimumWait: 0.2, tick: 0.05)
            let countDir = root.appendingPathComponent("count", isDirectory: true)
            try? fm.createDirectory(at: countDir, withIntermediateDirectories: true)
            setenv("LOCALAGENT_FAKE_COUNT_DIR", countDir.path, 1)
            setenv("LOCALAGENT_FAKE_MODE", "limitthenok", 1)
            let paced = LocalAgentClient(config: LocalAgentConfig(tool: .claude, binaryPath: fakeCLI), pacing: fast)
            let sawPause = Task { () -> Bool in
                for _ in 0..<200 {
                    if LocalAgentClient.usageWindowPause.until != nil { return true }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                return false
            }
            let started = Date()
            let resumed = try? await paced.ocr(imageURL: imageURL)
            let calls = (try? String(contentsOf: countDir.appendingPathComponent("calls"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            check("pacing: the page is read after two limits", resumed?.text?.contains("read after the window reset") == true)
            check("pacing: three calls, all on the plan", calls == "3")
            check("pacing: it waited for the resets (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)",
                  Date().timeIntervalSince(started) >= 0.4)
            check("pacing: the pause was shown while it waited", await sawPause.value)
            check("pacing: no pause after", LocalAgentClient.usageWindowPause.until == nil)
            unsetenv("LOCALAGENT_FAKE_COUNT_DIR")

            // 5e. Stop while waiting ends the wait at once, with a cancelled page (which the batch does not record).
            setenv("LOCALAGENT_FAKE_MODE", "limitjson", 1)
            let slow = LocalAgentClient(config: LocalAgentConfig(tool: .claude, binaryPath: fakeCLI),
                                        pacing: UsageWindowPacing(grace: 60, unknownWait: 60, minimumWait: 60, tick: 0.05))
            let waiting = Task { try? await slow.ocr(imageURL: imageURL) }
            var paused = false
            for _ in 0..<200 where !paused {
                try? await Task.sleep(nanoseconds: 20_000_000)
                paused = LocalAgentClient.usageWindowPause.until != nil
            }
            check("stop: the page was waiting", paused)
            let stopAt = Date()
            waiting.cancel()
            let stopped = await waiting.value
            check("stop: the wait ends at once", Date().timeIntervalSince(stopAt) < 2)
            check("stop: the page is cancelled, no text", stopped?.errorCode == "cli_cancelled" && stopped?.text == nil)
            check("stop: no pause after", LocalAgentClient.usageWindowPause.until == nil)

            // 5f. The unverified adapters do not wait: a limit fails the page as before.
            setenv("LOCALAGENT_FAKE_MODE", "ratelimited", 1)
            let gem = try? await LocalAgentClient(config: LocalAgentConfig(tool: .gemini, binaryPath: fakeCLI), pacing: slow.pacing)
                .ocr(imageURL: imageURL)
            check("gemini: a limit fails the page, no wait", gem?.errorCode == "cli_rate_limited")

            // 5g. The status line's words, and the caption draws.
            let box = UsageWindowPause()
            check("pause: nothing to say when no page waits", box.message() == nil)
            let id = UUID()
            box.begin(id, until: Date().addingTimeInterval(3 * 86_400))
            let words = box.message() ?? ""
            check("pause: says paused, the day, and no key", words.hasPrefix("Paused:") && words.contains(" on ")
                  && words.contains("nothing is sent to a key"))
            let caption = ImageRenderer(content: PlanPauseCaption(pause: box).frame(width: 400))
            caption.scale = 1
            check("pause: the caption draws", (caption.nsImage?.size.height ?? 0) > 5)
            box.end(id)

            // 5b. An API key in the app's own environment never reaches `claude` (W40.fix-processor-localagent-api-key):
            // OCR, text completion and the probe all spawn through the same path.
            setenv("ANTHROPIC_API_KEY", "sk-test-not-a-key", 1)
            setenv("ANTHROPIC_AUTH_TOKEN", "test-not-a-token", 1)
            do {
                let t = try await client(mode: "envkeys").textCompletion(prompt: "hello")
                check("textCompletion: no inherited API credential reaches claude", t == "ENV_KEYS=NONE")
                if t != "ENV_KEYS=NONE" { note("claude saw \(t)") }
            } catch { check("textCompletion(envkeys) did not throw", false); note("threw \(error)") }
            do {
                let r = try await client(mode: "envkeys").ocr(imageURL: imageURL)
                check("ocr: no inherited API credential reaches claude", r.text?.contains("ENV_KEYS=NONE") == true)
            } catch { check("ocr(envkeys) did not throw", false); note("threw \(error)") }
            let codexKeys = try? await LocalAgentClient(config: LocalAgentConfig(tool: .codex, binaryPath: fakeCLI))
                .textCompletion(prompt: "hello")
            check("the fake CLI sees the variables when nothing strips them", codexKeys?.hasPrefix("ENV_KEYS=ANTHROPIC_API_KEY") == true)
            unsetenv("ANTHROPIC_API_KEY")
            unsetenv("ANTHROPIC_AUTH_TOKEN")

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

#endif
