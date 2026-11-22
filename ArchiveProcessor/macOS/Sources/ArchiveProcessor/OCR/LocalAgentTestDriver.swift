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
            func classify(_ cli: LocalAgentClient.CLIRun) -> LocalAgentClient.InvokeOutcome {
                LocalAgentClient.classifyClaude(cli, stream: ClaudeStreamOutput.parse(cli.stdout), now: now)
            }
            if case .usageLimited(let reset, let message) = classify(
                run(#"{"type":"result","is_error":true,"result":"You've hit your limit · resets in 2s"}"#)) {
                check("classify: the envelope's limit is a usage limit, reset in 2 s",
                      reset.map { abs($0.timeIntervalSince(now) - 2) < 0.5 } == true)
                check("classify: the limit message says nothing goes to a key", message.contains("nothing is sent to a key"))
            } else { check("classify: the envelope's limit is a usage limit", false) }
            if case .usageLimited(let reset, _) = classify(
                run(#"{"is_error":true,"result":"Claude AI usage limit reached|1800000000"}"#)) {
                check("classify: the epoch reset is read", reset == Date(timeIntervalSince1970: 1_800_000_000))
            } else { check("classify: the epoch form is a usage limit", false) }
            if case .usageLimited(let reset, _) = classify(
                run("", "Error: usage limit reached. Please try again later.")) {
                check("classify: a stderr limit with no reset has none", reset == nil)
            } else { check("classify: a stderr limit is a usage limit", false) }
            check("classify: an error envelope with exit 0 is no text",
                  classify(run(#"{"is_error":true,"result":"An internal error occurred while generating"}"#,
                                                      exit: 0))
                  == .failure(code: "cli_error", message: "The Claude Code CLI reported an error: An internal error occurred while generating"))
            if case .failure(let code, _) = classify(run("", "could not separate the pages", exit: 2)) {
                check("classify: 'separate' is no usage limit for claude", code == "cli_exit_2")
            } else { check("classify: 'separate' is a failure", false) }
            // Review fixes: only the envelope's result says why; the reset forms a batch sleeps to.
            if case .usageLimited = classify(
                run(#"{"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":429,"result":""}"#)) {
                check("classify: a 429 among the envelope's other fields is no limit", false)
            } else { check("classify: a 429 among the envelope's other fields is no limit", true) }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            let at301 = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 15, minute: 1))!
            check("pacing reset: a clock just past is unknown, not tomorrow",
                  LocalAgentClient.pacingReset("You've hit your limit · resets 3pm", now: at301, calendar: cal) == nil)
            check("pacing reset: a clock ahead is that time",
                  LocalAgentClient.pacingReset("You've hit your limit · resets 5pm", now: at301, calendar: cal)
                  == cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 17)))
            check("pacing reset: the weekly date form",
                  LocalAgentClient.pacingReset("You've hit your weekly limit · resets Nov 24, 9am", now: at301, calendar: cal)
                  == cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 9)))
            check("pacing reset: a millisecond epoch",
                  LocalAgentClient.pacingReset("Claude AI usage limit reached|1800000000000", now: at301, calendar: cal)
                  == Date(timeIntervalSince1970: 1_800_000_000))
            check("pacing reset: relative", LocalAgentClient.pacingReset("resets in 2h", now: at301, calendar: cal)
                  == at301.addingTimeInterval(7200))
            check("classify: a good envelope is its result",
                  classify(run(#"{"is_error":false,"result":"text"}"#, exit: 0)) == .success("text"))

            check("classify: an incomplete stream cannot pass model text or incidentally hit a rate limit",
                  classify(run(#"{"type":"assistant","duration_ms":429,"result":"unfinished text"}"#, exit: 0))
                  == .failure(code: "cli_bad_response", message: "The Claude Code CLI returned an unreadable response."))

            if case .usageLimited(let reset, _) = classify(run("""
                {"type":"system","subtype":"init"}
                {"type":"result","is_error":true,"errors":["Claude AI usage limit reached|1800000000"]}
                """, exit: 0)) {
                check("classify: a terminal streamed error carries its limit and reset",
                      reset == Date(timeIntervalSince1970: 1_800_000_000))
            } else { check("classify: a terminal streamed error carries its limit and reset", false) }

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
            box.begin(id, wait: .init(until: Date().addingTimeInterval(3 * 86_400)))
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

            // The real client checks billing through the same executable, then reads its reported dollar cost.
            let usage = ClaudeCLIUsage.shared
            setenv("LOCALAGENT_FAKE_BILLING", "key", 1)
            let paid = await usage.refresh(binary: fakeCLI, force: true)
            check("auth status identifies a stored CLI key", paid == .apiKey)
            check("paid CLI cost pane identifies billed usage before any calls",
                  usage.costHeadline(binary: fakeCLI, tool: .claude).contains("bills its API key"))
            let paidPage = try? await client(mode: "paid").ocr(imageURL: imageURL)
            check("stored-key CLI reads the page", paidPage?.text?.contains("PAID FIXTURE") == true)
            check("stored-key CLI shows the real result's dollar figure",
                  usage.costDetail(binary: fakeCLI, tool: .claude).contains("$0.0425"))
            let limitedPaid = try? await client(mode: "limitjson").ocr(imageURL: imageURL)
            check("stored-key rate limit fails without waiting on a subscription", limitedPaid?.errorCode == "cli_rate_limited")
            setenv("LOCALAGENT_FAKE_BILLING", "unknown", 1)
            let unknown = await usage.refresh(binary: fakeCLI, force: true)
            check("an unavailable sign-in status does not claim a free plan",
                  unknown == .unknown && usage.costDetail(binary: fakeCLI, tool: .claude).contains("may incur charges"))
            unsetenv("LOCALAGENT_FAKE_BILLING")
            let plan = await usage.refresh(binary: fakeCLI, force: true)
            usage.reportAPIUsage(0.01, binary: fakeCLI)
            check("a completed paid request does not replace a newer sign-in", usage.billing(for: fakeCLI) == .subscription)
            check("Claude account sign-in shows subscription coverage", plan == .subscription
                  && usage.costHeadline(binary: fakeCLI, tool: .claude).contains("Included in your subscription"))
            check("malformed status is unknown", ClaudeCLIBilling.parse(status: "unsupported command") == .unknown)

            var cappedConfig = LocalAgentConfig(tool: .claude, binaryPath: fakeCLI)
            cappedConfig.requiresSubscription = true
            setenv("LOCALAGENT_FAKE_BILLING", "key", 1)
            setenv("LOCALAGENT_FAKE_MODE", "paid", 1)
            let capped = try? await LocalAgentClient(config: cappedConfig).ocr(imageURL: imageURL)
            check("a monthly limit rejects a key-backed read before dispatch", capped?.errorCode == "cli_billing_unconfirmed")
            unsetenv("LOCALAGENT_FAKE_BILLING")
            _ = await usage.refresh(binary: fakeCLI, force: true)

            // At 89% a second page can start. At 90% its result is kept and the next page waits.
            let meterDir = root.appendingPathComponent("meter-calls", isDirectory: true)
            try? fm.createDirectory(at: meterDir, withIntermediateDirectories: true)
            setenv("LOCALAGENT_FAKE_COUNT_DIR", meterDir.path, 1)
            setenv("LOCALAGENT_FAKE_MODE", "readmeter", 1)
            let reset = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970) + 3)
            setenv("LOCALAGENT_FAKE_RESET", String(Int(reset.timeIntervalSince1970)), 1)
            func meteredClient() -> LocalAgentClient {
                LocalAgentClient(config: LocalAgentConfig(tool: .claude, binaryPath: fakeCLI), pacing: fast)
            }
            func meterCalls() -> Int { (try? fm.contentsOfDirectory(atPath: meterDir.path).count) ?? 0 }
            let below = try? await meteredClient().ocr(imageURL: imageURL)
            let reached = try? await meteredClient().ocr(imageURL: imageURL)
            check("meter: 89% admits the next page and the page that sees 90% keeps its final result",
                  below?.text == "FAKE-CLI-OCR-TOKEN" && reached?.text == below?.text && meterCalls() == 2
                    && LocalAgentClient.usageWindowPause.until == nil)
            let cancelledRead = Task { try? await meteredClient().ocr(imageURL: imageURL) }
            for _ in 0..<50 where LocalAgentClient.usageWindowPause.until == nil {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            let meterCaption = LocalAgentClient.usageWindowPause.message() ?? ""
            check("meter: the next client shows the 90% pause and sends no call",
                  meterCalls() == 2 && LocalAgentClient.usageWindowPause.until == reset && meterCaption.contains("at 90%")
                    && !meterCaption.contains("limit is reached"))
            cancelledRead.cancel()
            let cancelledResult = await cancelledRead.value
            check("meter: Stop ends the waiting page and clears the caption",
                  cancelledResult?.errorCode == "cli_cancelled" && LocalAgentClient.usageWindowPause.until == nil)
            let afterReset = try? await meteredClient().ocr(imageURL: imageURL)
            check("meter: a new page still waits until the reset, then reads on the same plan",
                  afterReset?.text == "FAKE-CLI-OCR-TOKEN" && Date() >= reset && meterCalls() == 3
                    && LocalAgentClient.usageWindowPause.until == nil)
            unsetenv("LOCALAGENT_FAKE_COUNT_DIR")
            unsetenv("LOCALAGENT_FAKE_RESET")

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

        // ── W41.app-claude-plan-reading: the live check, only when asked (`LOCALAGENT_LIVE_PAGES`, a folder of
        // non-corpus fixture pages; `scripts/test-localagent.sh --live`). The real `claude` on the user's plan at the
        // reading row's model, through the same client and limiter Process Files uses: how long a page takes, one and
        // two at once. Uses the plan's usage window, never money (the key variables are stripped).
        if let dir = ProcessInfo.processInfo.environment["LOCALAGENT_LIVE_PAGES"], !dir.isEmpty {
            let pages = ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
                .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let live = LocalAgentClient(config: LocalAgentConfig(tool: .claude, modelOverride: "claude-sonnet-5-5"))
            check("live: \(pages.count) fixture pages", !pages.isEmpty)
            func read(_ url: URL) async -> (String, Double, OCRResult?) {
                let t0 = Date()
                let r = try? await live.ocr(imageURL: url)
                return (url.lastPathComponent, Date().timeIntervalSince(t0), r)
            }
            func report(_ label: String, _ rows: [(String, Double, OCRResult?)], wall: Double) {
                for (name, s, r) in rows {
                    note("live \(label): \(name) \(String(format: "%.1f", s)) s, \(r?.text?.count ?? 0) chars, "
                         + "kind \(r?.classification.map { "\($0)" } ?? "none"), error \(r?.errorCode ?? "none")")
                }
                let ok = rows.filter { $0.2?.text?.isEmpty == false }.count
                note("live \(label): \(ok)/\(rows.count) read in \(String(format: "%.1f", wall)) s wall, "
                     + String(format: "%.0f pages an hour", wall > 0 ? Double(ok) / wall * 3600 : 0))
                check("live \(label): every page read", ok == rows.count)
            }
            var t0 = Date()
            var one: [(String, Double, OCRResult?)] = []
            for p in pages { one.append(await read(p)) }
            report("one at a time", one, wall: Date().timeIntervalSince(t0))
            t0 = Date()
            let two = await withTaskGroup(of: (String, Double, OCRResult?).self) { group in
                for p in pages { group.addTask { await read(p) } }
                var out: [(String, Double, OCRResult?)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }
            }
            report("two at once (the client's limit)", two, wall: Date().timeIntervalSince(t0))
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
