import Foundation

/// OCR + text-completion backend that shells out to a locally installed, subscription-authenticated
/// CLI (`claude` / `gemini` / `codex`) instead of a metered API key or gateway. Exposes the same two
/// operations as `OpenAICompatibleClient` (`ocr` → `OCRResult`, `textCompletion` → `String`) so it
/// plugs into the same construction sites (wired in a later checkpoint).
///
/// SAFETY / DESIGN:
/// - Spawns the binary **directly** via `Process` (no shell) → nothing in the prompt or args is ever
///   shell-interpreted. The prompt travels on **stdin**, never argv (dodges arg-length limits and
///   shell/quoting hazards, per the plan). The image travels as a temp JPEG whose **absolute path**
///   is referenced in the prompt (the agent reads it with its Read tool).
/// - The binary is resolved to an **absolute path** from a fixed candidate list (or the operator's
///   explicit override), never from `$PATH` (no PATH injection).
/// - Every call has a hard wall-clock **timeout** (SIGTERM→SIGKILL) and drains stdout/stderr
///   concurrently so a chatty child can't deadlock on a full pipe buffer.
/// - Holds **no API key**. Auth is the CLI's own subscription login.
/// - Only `claude` is Phase-0-validated on a real machine; `gemini`/`codex` invocation details are
///   best-effort placeholders (marked VERIFY) pending their Phase-0 spike (keyed/owner tail).
struct LocalAgentClient: Sendable {
    let config: LocalAgentConfig

    /// Per-call wall-clock ceilings. OCR is agentic (a Read tool-turn then the answer) so it gets a
    /// generous ceiling; text completion is prompt-only and quicker.
    static let ocrTimeout: TimeInterval = 240
    static let textTimeout: TimeInterval = 120
    /// A `probe()` verification round-trip is prompt-only, but still pays CLI cold-start + one turn, so
    /// it gets a middle ceiling — long enough for a slow first launch, short enough to feel responsive.
    static let probeTimeout: TimeInterval = 60
    private static let probePrompt =
        "Reply with only the two words: PROBE OK. Do not use any tools or add any other text."

    /// Appended to the CLI's own system prompt (where supported) so the agent emits ONLY the
    /// classification/rotation/transcription in `OCRPrompt`'s format — no preamble or tool chatter.
    private static let systemContract =
        "You are a headless OCR/classification backend. Reply with ONLY the classification tag line, " +
        "the rotation tag line, and the transcription, exactly in the format the user message specifies. " +
        "Do not add any preamble, explanation, apology, or commentary about tools."

    /// Dedicated concurrency ceiling for Local Agent CLI model calls. The subprocess path does NOT flow
    /// through `NetworkSession`'s HTTP `RequestLimiter`, so without this a wide OCR task group could
    /// spawn a swarm of `claude`/`gemini` children at once against a *personal subscription*. This caps
    /// the number of simultaneous CLI model calls at the top of the supported 1…2 range; the finer
    /// per-run 1-vs-2 choice (`LocalAgentConfig.effectiveConcurrencyCap`) rides the OCR task-group width
    /// (wired in W13.cli-4). Reuses the same cancellation-aware limiter the HTTP path uses — a separate
    /// instance, so the two backends never share slots.
    private static let concurrencyLimiter = RequestLimiter(limit: 2)

    /// When a CLI reports a usage-window limit with a parseable reset time, the moment it frees up — so a
    /// bulk OCR run can pace to the subscription window instead of hammering it, and the UI can say when
    /// it recovers. The CLI-side analog of `NetworkSession.lastRateLimitedAt` (subprocess calls bypass
    /// that HTTP path's `Retry-After` handling). Write-mostly; the OCR loop consumes it in W13.cli-4.
    /// `nil` ⇒ no reset time is currently known.
    nonisolated(unsafe) static var lastUsageWindowResetAt: Date?

    /// How a page waits out the plan's usage limit (W41.app-claude-plan-reading).
    let pacing: UsageWindowPacing

    /// The pages waiting for the plan's usage window, app-wide, for the status line (`UsageWindowPause`).
    static let usageWindowPause = UsageWindowPause()

    init(config: LocalAgentConfig, pacing: UsageWindowPacing = .standard) {
        self.config = config
        self.pacing = pacing
    }

    // MARK: - Public seam (mirrors OpenAICompatibleClient)

    func ocr(imageURL: URL, previousText: String? = nil, previousImageURL: URL? = nil,
             customPrompt: String? = nil, imageScale: Double = 1.0) async throws -> OCRResult {
        // Resolve the binary first (cheap) before doing any image work.
        guard let binary = Self.resolveBinaryPath(tool: config.tool, override: config.binaryPath) else {
            return Self.failure(code: "cli_not_found",
                                message: "The \(config.tool.displayName) CLI was not found. Install it and sign in, " +
                                         "or set its path in Settings.")
        }
        guard let jpeg = ImageEncoding.loadImageAsJPEG(url: imageURL, scale: imageScale) else {
            throw OCRError.imageLoadFailed
        }

        // Stage temp JPEG(s) in an isolated scratch dir; always cleaned up.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("localagent-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            throw OCRError.imageLoadFailed
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let pageURL = scratch.appendingPathComponent("page.jpg")
        do { try jpeg.write(to: pageURL, options: .atomic) } catch { throw OCRError.imageLoadFailed }

        var prevPath: String? = nil
        if let prevURL = previousImageURL, let prevData = ImageEncoding.loadImageAsJPEG(url: prevURL, scale: imageScale) {
            let prevOut = scratch.appendingPathComponent("prev.jpg")
            if (try? prevData.write(to: prevOut, options: .atomic)) != nil { prevPath = prevOut.path }
        }

        let basePrompt = OCRPrompt.build(previousText: previousText,
                                         previousImageIncluded: prevPath != nil,
                                         customPrompt: customPrompt)
        let prompt = Self.augmentWithImagePaths(basePrompt, pagePath: pageURL.path, previousPath: prevPath)

        let run = await Self.invokePaced(binary: binary, tool: config.tool, modelOverride: config.modelOverride,
                                         prompt: prompt, timeout: Self.ocrTimeout, pacing: pacing)

        switch run {
        case .failure(let code, let message):
            return Self.failure(code: code, message: message)
        case .usageLimited(_, let message):
            return Self.failure(code: "cli_rate_limited", message: message)
        case .success(let text):
            let (classification, rotationDegrees, ocrText) = OCRPrompt.parseResponse(text)
            return OCRResult(text: ocrText, classification: classification,
                             rotationDegrees: rotationDegrees, errorMessage: nil, errorCode: nil,
                             enclosure: OCRPrompt.parseEnclosureFlag(text))
        }
    }

    func textCompletion(prompt: String, maxTokens: Int = 512) async throws -> String {
        // maxTokens is part of the shared seam but has no uniform CLI equivalent, so it is advisory
        // only (the CLIs cap their own output); kept for signature parity with the other clients.
        _ = maxTokens
        guard let binary = Self.resolveBinaryPath(tool: config.tool, override: config.binaryPath) else {
            throw OCRError.networkError("The \(config.tool.displayName) CLI was not found. Install it and sign in.")
        }
        let run = await Self.invokePaced(binary: binary, tool: config.tool, modelOverride: config.modelOverride,
                                         prompt: prompt, timeout: Self.textTimeout, pacing: pacing)
        switch run {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { throw OCRError.networkError("The \(config.tool.displayName) CLI returned no text.") }
            return trimmed
        case .failure(_, let message), .usageLimited(_, let message):
            throw OCRError.networkError(message)
        }
    }

    // MARK: - Validation probe (used by LocalAgentValidator)

    /// Structured result of a minimal round-trip that confirms the CLI is installed AND signed in,
    /// WITHOUT spending a real OCR call. Carries only a friendly message + a stable code (never raw
    /// stderr) so `LocalAgentValidator` can map it to a user-facing status.
    struct ProbeOutcome: Sendable {
        /// True ⇒ the CLI produced a normal response (installed, runnable, and authenticated).
        let ok: Bool
        /// Stable failure code (see `exitErrorCode`); nil on success.
        let code: String?
        /// Friendly one-line message (never raw stderr); nil on success.
        let message: String?
    }

    /// One tiny prompt-only round-trip through the SAME spawn path OCR uses, to verify the CLI is
    /// reachable and signed in. Cheaper than an OCR call (no image, trivial prompt) and never throws.
    /// The binary is resolved exactly like `ocr`/`textCompletion` (an explicit override, otherwise
    /// standard paths; never `$PATH`); an unresolved binary reports `cli_not_found` instead of probing.
    func probe() async -> ProbeOutcome {
        guard let binary = Self.resolveBinaryPath(tool: config.tool, override: config.binaryPath) else {
            return ProbeOutcome(ok: false, code: "cli_not_found",
                                message: "The \(config.tool.displayName) CLI was not found.")
        }
        let run = await Self.invoke(binary: binary, tool: config.tool, modelOverride: config.modelOverride,
                                    prompt: Self.probePrompt, timeout: Self.probeTimeout)
        switch run {
        case .success:
            return ProbeOutcome(ok: true, code: nil, message: nil)
        case .failure(let code, let message):
            return ProbeOutcome(ok: false, code: code, message: message)
        case .usageLimited(_, let message):
            return ProbeOutcome(ok: false, code: "cli_rate_limited", message: message)
        }
    }

    // MARK: - Binary resolution (absolute path only, never $PATH)

    /// Resolve the CLI to an absolute executable path. A non-empty operator override is authoritative:
    /// returning nil for an invalid override prevents a typo or stale setting from silently launching a
    /// different installation. Standard locations are searched only when no override was supplied.
    static func resolveBinaryPath(tool: LocalAgentTool, override: String) -> String? {
        let fm = FileManager.default
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard NSString(string: trimmed).isAbsolutePath else { return nil }
            return fm.isExecutableFile(atPath: trimmed) ? trimmed : nil
        }
        let home = NSHomeDirectory()
        let name = tool.binaryName
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - Invocation

    /// Outcome of one CLI OCR/text call: either the model's raw text, or a friendly (never-raw-stderr)
    /// error message + a stable code the validator / pipeline can branch on.
    enum InvokeOutcome: Sendable, Equatable {
        case success(String)
        case failure(code: String, message: String)
        /// `claude` said the plan's usage limit is reached, with the reset it printed when it printed one.
        case usageLimited(reset: Date?, message: String)
    }

    /// `invoke`, but a `claude` call that meets the plan's usage limit waits for the window to reset and tries the plan
    /// again, as long as it takes (W41.app-claude-plan-reading): a long batch pauses and resumes by itself, and the
    /// page is never sent anywhere else, so nothing is billed to a key behind the user's back. Cancelling the run
    /// (Stop) ends the wait at once. `gemini`/`codex` are unverified adapters and keep failing the page, as before.
    static func invokePaced(binary: String, tool: LocalAgentTool, modelOverride: String?, prompt: String,
                            timeout: TimeInterval, pacing: UsageWindowPacing) async -> InvokeOutcome {
        while true {
            let run = await invoke(binary: binary, tool: tool, modelOverride: modelOverride, prompt: prompt,
                                   timeout: timeout)
            guard tool == .claude, case .usageLimited(let reset, _) = run else { return run }
            let until = pacing.resumeAt(reset: reset, now: Date())
            let id = UUID()
            usageWindowPause.begin(id, until: until)
            let waited = await pacing.wait(until: until)
            usageWindowPause.end(id)
            guard waited else {
                return .failure(code: "cli_cancelled", message: "The \(tool.displayName) CLI request was cancelled.")
            }
        }
    }

    private static func invoke(binary: String, tool: LocalAgentTool, modelOverride: String?,
                               prompt: String, timeout: TimeInterval) async -> InvokeOutcome {
        // Dedicated low ceiling — the subprocess path bypasses NetworkSession's HTTP limiter, so pace it
        // here so a wide OCR task group never spawns a swarm of CLI children against a personal
        // subscription. `spawnAndClassify` never throws, so a plain acquire → body → release is balanced
        // (`acquire()` throws on cancellation, so a queued cancelled call never spawns a child process;
        // `spawnAndClassify` itself never throws, keeping every granted slot balanced).
        do {
            try await concurrencyLimiter.acquire()
        } catch {
            return .failure(code: "cli_cancelled", message: "The \(tool.displayName) CLI request was cancelled.")
        }
        // Cancellation can race with the limiter granting this waiter. Return the granted slot before
        // declining to spawn, matching NetworkSession's post-acquire cancellation check.
        if Task.isCancelled {
            await concurrencyLimiter.release()
            return .failure(code: "cli_cancelled", message: "The \(tool.displayName) CLI request was cancelled.")
        }
        let outcome = await spawnAndClassify(binary: binary, tool: tool, modelOverride: modelOverride,
                                             prompt: prompt, timeout: timeout)
        await concurrencyLimiter.release()
        return outcome
    }

    /// The actual spawn + classify, run while holding a `concurrencyLimiter` slot.
    private static func spawnAndClassify(binary: String, tool: LocalAgentTool, modelOverride: String?,
                                         prompt: String, timeout: TimeInterval) async -> InvokeOutcome {
        let args = cliArguments(tool: tool, modelOverride: modelOverride)
        let cli = await runAsync(binaryPath: binary, args: args, stdinText: prompt, timeout: timeout,
                                 unsetEnvironment: credentialVariables(for: tool))

        if cli.cancelled {
            return .failure(code: "cli_cancelled", message: "The \(tool.displayName) CLI request was cancelled.")
        }
        if cli.exitCode == -2 || cli.timedOut {
            return .failure(code: "cli_timeout", message: "The \(tool.displayName) CLI timed out. Try again, or reduce concurrency.")
        }
        if cli.spawnFailed {
            return .failure(code: "cli_spawn_failed", message: "Could not launch the \(tool.displayName) CLI.")
        }
        if tool == .claude { return classifyClaude(cli, now: Date()) }
        if cli.exitCode != 0 {
            let code = exitErrorCode(stderr: cli.stderr, exitCode: cli.exitCode)
            // Record a parseable usage-window reset so a bulk run can pace to it (W13.cli-4) and the
            // message can say when the subscription frees up.
            if code == "cli_rate_limited" {
                lastUsageWindowResetAt = parseUsageWindowReset(fromStderr: cli.stderr, now: Date())
            }
            return .failure(code: code,
                            message: friendlyExitMessage(tool: tool, stderr: cli.stderr, exitCode: cli.exitCode))
        }
        guard let text = extractText(tool: tool, stdout: cli.stdout), !text.isEmpty else {
            return .failure(code: "cli_bad_response",
                            message: "The \(tool.displayName) CLI returned an unreadable response.")
        }
        return .success(text)
    }

    /// A finished `claude -p --output-format json` call. The CLI reports a usage limit in its JSON envelope on stdout
    /// (`is_error`, and the reason in `result`), not only on stderr, and can do so with exit 0, so the envelope decides:
    /// success only when it is not an error and has a result; otherwise its `result`, or all the output when there is
    /// no envelope, says why (as the segmentation windows read it, `LocalAgentWindowTransport.classify`). A usage
    /// limit is matched narrowly (`LocalAgentWindowTransport.isUsageLimit`), since the page then waits for it.
    static func classifyClaude(_ cli: CLIRun, now: Date) -> InvokeOutcome {
        let envelope = (try? JSONSerialization.jsonObject(with: Data(cli.stdout.utf8))) as? [String: Any]
        let isError = envelope?["is_error"] as? Bool == true
        if cli.exitCode == 0, !isError, let text = envelope?["result"] as? String, !text.isEmpty {
            return .success(text)
        }
        // When the envelope parsed, only its `result` (or stderr) says why: its other fields (a duration of 429 ms) must
        // not read as a limit.
        let reason = envelope != nil
            ? ((envelope?["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? cli.stderr)
            : (cli.stderr + "\n" + cli.stdout)
        let tool = LocalAgentTool.claude
        if exitErrorCode(stderr: reason, exitCode: cli.exitCode) == "cli_not_logged_in" {
            return .failure(code: "cli_not_logged_in", message: friendlyExitMessage(tool: tool, stderr: reason, exitCode: 1))
        }
        if LocalAgentWindowTransport.isUsageLimit(reason) {
            let reset = pacingReset(reason, now: now)
            lastUsageWindowResetAt = reset
            let when = reset.map { " It resets \(usageWindowHint(for: $0, now: now))." } ?? ""
            return .usageLimited(reset: reset, message: "Your Claude plan's usage limit is reached.\(when) Reading "
                                 + "waits for it and goes on with the plan; nothing is sent to a key.")
        }
        if cli.exitCode != 0 {
            var code = exitErrorCode(stderr: reason, exitCode: cli.exitCode)
            // The broad "limit/quota/rate" match is for the unverified adapters; for `claude` only the narrow one above
            // is a usage limit, so a message that merely says "generate" or "separate" is an ordinary failure.
            if code == "cli_rate_limited" { code = "cli_exit_\(cli.exitCode)" }
            let message = code == "cli_exit_\(cli.exitCode)" ? "The Claude Code CLI failed (exit \(cli.exitCode))."
                : friendlyExitMessage(tool: tool, stderr: reason, exitCode: cli.exitCode)
            return .failure(code: code, message: message)
        }
        if isError {
            return .failure(code: "cli_error", message: "The Claude Code CLI reported an error: \(String(reason.prefix(200)))")
        }
        return .failure(code: "cli_bad_response", message: "The Claude Code CLI returned an unreadable response.")
    }

    /// Inherited from a shell that launched the app, these make `claude -p` bill an API key instead of the
    /// subscription this backend exists to use, while the cost pane says the plan covers it. Stripped from every
    /// `claude` child: OCR, text completion, the probe and the segmentation windows (`LocalAgentWindowTransport`).
    static let claudeAPICredentialVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    /// The variables removed from `tool`'s environment. `gemini`/`codex` are unverified adapters, left as they were.
    static func credentialVariables(for tool: LocalAgentTool) -> [String] {
        tool == .claude ? claudeAPICredentialVariables : []
    }

    /// Fixed headless args per tool. Prompt rides on stdin, so it is NOT here.
    /// `claude` is validated (Phase 0); `gemini`/`codex` are VERIFY placeholders (Phase 0 pending).
    private static func cliArguments(tool: LocalAgentTool, modelOverride: String?) -> [String] {
        switch tool {
        case .claude:
            var a = ["-p", "--output-format", "json", "--allowedTools", "Read",
                     "--no-session-persistence", "--append-system-prompt", systemContract]
            if let m = modelOverride, !m.isEmpty { a += ["--model", m] }
            return a
        case .gemini:
            // VERIFY (Phase 0 pending): flags + JSON envelope for `gemini` are unconfirmed on a real machine.
            var a = ["--output-format", "json"]
            if let m = modelOverride, !m.isEmpty { a += ["-m", m] }
            return a
        case .codex:
            // VERIFY (Phase 0 pending): `codex exec` flags + JSON envelope are unconfirmed on a real machine.
            var a = ["exec", "--json"]
            if let m = modelOverride, !m.isEmpty { a += ["--model", m] }
            return a
        }
    }

    /// Pull the model's text out of the CLI's JSON envelope. `claude -p --output-format json` puts it
    /// in `.result`; malformed/non-JSON Claude output must fail instead of being mistaken for OCR text.
    /// The unverified Gemini/Codex adapters retain a plain-text compatibility fallback until their real
    /// CLI envelope contracts are validated.
    private static func extractText(tool: LocalAgentTool, stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8) else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch tool {
            case .claude:
                return json["result"] as? String
            case .gemini, .codex:
                // VERIFY: accept the common envelope shapes seen across CLIs.
                return (json["result"] as? String)
                    ?? (json["response"] as? String)
                    ?? (json["text"] as? String)
                    ?? (json["output"] as? String)
            }
        }
        if tool == .claude { return nil }
        // Gemini/Codex CLI contracts are still marked VERIFY. Preserve their compatibility with versions
        // that emit plain text despite the requested JSON flag, but never apply that fallback to Claude.
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Error mapping (friendly; never surfaces raw stderr)

    private static func exitErrorCode(stderr: String, exitCode: Int32) -> String {
        let s = stderr.lowercased()
        if s.contains("not logged in") || s.contains("please log in") || s.contains("authenticate")
            || s.contains("unauthenticated") || s.contains("sign in") { return "cli_not_logged_in" }
        // Signed in, but this account/seat isn't AUTHORIZED to use the CLI (e.g. a Gemini chat-app tier
        // with no Code Assist/API entitlement, or a Claude Team/Enterprise seat without Claude Code
        // enabled). Distinct from not-logged-in: the fix is an entitlement/admin change, not a login.
        // Checked after login (a not-signed-in state is more common + more actionable) and before the
        // rate check. `gemini`/`codex` phrasing is VERIFY (Phase 0 pending); `claude` needs no such gate.
        if s.contains("not entitled") || s.contains("no access to") || s.contains("does not have access")
            || s.contains("not authorized to use") || s.contains("code assist")
            || s.contains("subscription required") || s.contains("not enabled for")
            || s.contains("isn't enabled") || s.contains("workspace admin") || s.contains("enterprise admin")
            || s.contains("upgrade your plan") || s.contains("requires a paid plan") { return "cli_entitlement_missing" }
        if s.contains("limit") || s.contains("quota") || s.contains("rate") { return "cli_rate_limited" }
        return "cli_exit_\(exitCode)"
    }

    private static func friendlyExitMessage(tool: LocalAgentTool, stderr: String, exitCode: Int32) -> String {
        switch exitErrorCode(stderr: stderr, exitCode: exitCode) {
        case "cli_not_logged_in":
            return "Not signed in to the \(tool.displayName) CLI. Run its login command, then retry."
        case "cli_entitlement_missing":
            return "Your account isn't authorized to use the \(tool.displayName) CLI. It needs the right " +
                   "entitlement (a Gemini Code Assist/API license, or Claude Code enabled on your seat) — " +
                   "ask your admin, or use a personal subscription."
        case "cli_rate_limited":
            let now = Date()
            if let reset = parseUsageWindowReset(fromStderr: stderr, now: now) {
                return "\(tool.displayName) usage limit reached — resets \(usageWindowHint(for: reset, now: now)). The app paces to your subscription window and retries."
            }
            return "\(tool.displayName) usage limit reached. The app paces to your subscription window and retries."
        default:
            return "The \(tool.displayName) CLI failed (exit \(exitCode))."
        }
    }

    private static func failure(code: String, message: String) -> OCRResult {
        OCRResult(text: nil, classification: nil, errorMessage: message, errorCode: code)
    }

    // MARK: - Usage-window pacing (pure; unit-tested by scripts/localagent-pacing-test.swift)

    /// Extract when a subscription usage window resets from a CLI's rate-limit message, so a bulk OCR
    /// run can pace to that window (W13.cli-4) instead of hammering it, and the message can say when the
    /// subscription frees up. Subprocess calls bypass `NetworkSession`'s HTTP `Retry-After` handling, so
    /// this is the CLI-side analog. Pure + deterministic given `now`/`calendar` (the standalone pacing
    /// test asserts exact instants). Recognizes the common phrasings, else returns nil (the caller still
    /// knows it is rate-limited from the `cli_rate_limited` code):
    ///   • relative — "try again in 45 minutes", "retry after 30s", "resets in 2h 13m", "in about 3 hours"
    ///   • bare Retry-After seconds — "retry after 120"
    ///   • absolute local clock time (Claude Code's form) — "resets 3pm", "resets at 10:59pm",
    ///     "resets at 15:00" → the NEXT occurrence of that clock time at/after `now`.
    ///
    /// A relative "wait" duration is only parsed after an explicit wait-trigger ("resets in", "try again
    /// in", …) so a WINDOW size like "5-hour limit reached, resets 3pm" is read as the absolute 3pm, not
    /// "5 hours from now". `.current` in production uses the user's locale/timezone (matching how the CLI
    /// prints the reset); the test injects a fixed UTC calendar.
    static func parseUsageWindowReset(fromStderr stderr: String, now: Date,
                                      calendar: Calendar = .current) -> Date? {
        let s = stderr.lowercased()
        // Claude Code's older form: "Claude AI usage limit reached|1763600000", the reset in Unix seconds (milliseconds
        // when it has 13 digits).
        if let r = s.range(of: #"limit reached\|\d{9,13}(?!\d)"#, options: .regularExpression),
           let n = Double(s[r].split(separator: "|").last ?? "") {
            return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
        }
        // A date and a clock time, as a weekly window prints it: "resets Nov 24, 9am", "resets nov 24 at 9:30am".
        if let d = datedReset(in: s, now: now, calendar: calendar) { return d }
        if let secs = relativeResetSeconds(in: s), secs > 0 {
            return now.addingTimeInterval(secs)
        }
        if let (hour, minute) = absoluteResetClock(in: s) {
            return nextOccurrence(hour: hour, minute: minute, at: now, calendar: calendar)
        }
        return nil
    }

    /// The reset a page waiting on the plan sleeps to (W41.app-claude-plan-reading). A bare clock time is read as its
    /// next occurrence, so one printed just after the window reset ("resets 3pm" at 3:01) would read as tomorrow and
    /// stall a batch for a day: a bare clock time more than 22 hours ahead is taken as unknown instead, so the page
    /// tries the plan again after `UsageWindowPacing.unknownWait`. A five-hour window's clock is never that far ahead; a
    /// weekly one prints its date (`datedReset`).
    static func pacingReset(_ message: String, now: Date, calendar: Calendar = .current) -> Date? {
        guard let reset = parseUsageWindowReset(fromStderr: message, now: now, calendar: calendar) else { return nil }
        let s = message.lowercased()
        let bareClock = relativeResetSeconds(in: s) == nil && s.range(of: #"limit reached\|\d"#, options: .regularExpression) == nil
            && datedReset(in: s, now: now, calendar: calendar) == nil
        return bareClock && reset.timeIntervalSince(now) > 22 * 3600 ? nil : reset
    }

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "resets nov 24, 9am" / "resets on nov 24 at 9:30 pm" → that instant in `calendar`, in this year, or next year when
    /// it is more than a day past.
    private static func datedReset(in s: String, now: Date, calendar: Calendar) -> Date? {
        guard let re = try? NSRegularExpression(pattern:
            #"(?:reset(?:s|ting)?|again|available|back)\s*(?:on\s*)?(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(?:at\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#)
        else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let month = monthNames.firstIndex(of: ns.substring(with: m.range(at: 1))).map({ $0 + 1 }),
              let day = Int(ns.substring(with: m.range(at: 2))),
              var hour = Int(ns.substring(with: m.range(at: 3))) else { return nil }
        let minute = m.range(at: 4).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 4))) ?? 0) : 0
        let ampm = m.range(at: 5).location != NSNotFound ? ns.substring(with: m.range(at: 5)) : ""
        if ampm == "pm" && hour < 12 { hour += 12 }
        if ampm == "am" && hour == 12 { hour = 0 }
        guard (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var comps = DateComponents(year: calendar.component(.year, from: now), month: month, day: day, hour: hour,
                                   minute: minute, second: 0)
        guard var d = calendar.date(from: comps) else { return nil }
        if d < now.addingTimeInterval(-86_400) {
            comps.year = (comps.year ?? 0) + 1
            d = calendar.date(from: comps) ?? d
        }
        return d
    }

    /// A short human phrase for when a usage window frees up ("around 3:15 PM"), for the friendly
    /// rate-limit message. Pure; `now` reserved for future same-day/next-day wording. English-only, like
    /// the app's other status text (`en_US_POSIX` ⇒ deterministic "h:mm a").
    static func usageWindowHint(for reset: Date, now: Date, calendar: Calendar = .current) -> String {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "h:mm a"
        return "around \(fmt.string(from: reset))"
    }

    /// Wait-triggers that legitimately precede a relative reset duration (so a window *size* isn't read
    /// as a wait). Order-independent; the earliest match anchors the scan.
    private static let relativeResetTriggers = [
        "resets in", "reset in", "resetting in", "try again in", "retry in", "retry after",
        "available again in", "available in", "again in", "back in", "wait about", "in about",
    ]

    /// Sum of duration tokens that appear AFTER the earliest wait-trigger, in seconds (nil if none).
    private static func relativeResetSeconds(in s: String) -> Double? {
        var anchor: String.Index?
        for t in relativeResetTriggers {
            if let r = s.range(of: t), anchor == nil || r.upperBound < anchor! { anchor = r.upperBound }
        }
        guard let start = anchor else { return nil }
        let tail = String(s[start...])
        let ns = tail as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Compound / single units: "2h 13m", "45 minutes", "30s", "1 day".
        var total = 0.0
        var matched = false
        if let re = try? NSRegularExpression(pattern: #"(\d+)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s|days?|d)\b"#) {
            for match in re.matches(in: tail, range: full) {
                guard let n = Double(ns.substring(with: match.range(at: 1))) else { continue }
                switch ns.substring(with: match.range(at: 2)).first {
                case "h": total += n * 3600; matched = true
                case "m": total += n * 60;   matched = true
                case "s": total += n;        matched = true
                case "d": total += n * 86400; matched = true
                default:  break
                }
            }
        }
        if matched { return total }

        // Bare number right after the trigger ⇒ HTTP-style Retry-After delta seconds ("retry after 120").
        if let re = try? NSRegularExpression(pattern: #"^\s*(\d+)\b"#),
           let m = re.firstMatch(in: tail, range: full),
           let n = Double(ns.substring(with: m.range(at: 1))) {
            return n
        }
        return nil
    }

    /// Parse an absolute reset clock time ("resets 3pm" / "reset at 10:59pm" / "resets at 15:00").
    private static func absoluteResetClock(in s: String) -> (hour: Int, minute: Int)? {
        guard let re = try? NSRegularExpression(
            pattern: #"(?:reset(?:s|ting)?|again|available|back)\s*(?:at\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#)
        else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              var hour = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        let minute = m.range(at: 2).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 2))) ?? 0) : 0
        let ampm = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : ""
        if ampm == "pm" && hour < 12 { hour += 12 }
        if ampm == "am" && hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// The next wall-clock occurrence of `hour:minute` at or after `now` (today if still ahead, else
    /// tomorrow) — a usage window that "resets 3pm" means the upcoming 3pm.
    private static func nextOccurrence(hour: Int, minute: Int, at now: Date, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour; comps.minute = minute; comps.second = 0
        guard let candidate = calendar.date(from: comps) else { return nil }
        if candidate > now { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate)
    }

    // MARK: - Subprocess plumbing (pure Foundation; no shell)

    /// Result of one raw subprocess run.
    struct CLIRun: Sendable {
        let exitCode: Int32     // process exit status, or -2 if it never exited (killed after timeout)
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let spawnFailed: Bool
        /// The calling task was cancelled: the child was stopped (or never started), so the output means nothing.
        var cancelled = false
    }

    /// Lets a cancelled task stop the child it started (W36.seg-opt-subscription). Without it a cancelled run's
    /// `claude -p` calls ran on to their timeout, spending the user's plan on answers nobody would read.
    final class ProcessCanceller: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        /// Called once the child is running. A cancel that came first stops it at once.
        func attach(_ p: Process) {
            lock.lock()
            process = p
            let stopNow = cancelled
            lock.unlock()
            if stopNow { Self.stop(p) }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let p = process
            lock.unlock()
            if let p { Self.stop(p) }
        }

        /// SIGTERM, then SIGKILL after 3 s if the child is still there, as the timeout does.
        static func stop(_ p: Process) {
            guard p.isRunning else { return }
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// Thread-safe accumulator so the concurrent pipe-drain closures are Swift-6 Sendable-clean.
    private final class PipeSink: @unchecked Sendable {
        private let lock = NSLock()
        private var buf = Data()
        func set(_ d: Data) { lock.lock(); buf = d; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return buf }
    }

    /// Async wrapper — the blocking `Process` work runs off the cooperative pool. Cancelling the calling task
    /// stops the child (SIGTERM, then SIGKILL) and returns a run marked `cancelled`.
    static func runAsync(binaryPath: String, args: [String], stdinText: String,
                         timeout: TimeInterval, currentDirectory: URL? = nil,
                         unsetEnvironment: [String] = []) async -> CLIRun {
        let canceller = ProcessCanceller()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: runProcess(binaryPath: binaryPath, args: args,
                                                      stdinText: stdinText, timeout: timeout,
                                                      currentDirectory: currentDirectory, canceller: canceller,
                                                      unsetEnvironment: unsetEnvironment))
                }
            }
        } onCancel: {
            canceller.cancel()
        }
    }

    /// Spawn `binaryPath` with `args`, feed `stdinText` on stdin then close it, drain stdout+stderr
    /// concurrently (no pipe-buffer deadlock), and enforce a hard timeout (SIGTERM → SIGKILL).
    ///
    /// Kept behaviourally identical to `scripts/localagent-mechanism-test.swift`, the standalone $0
    /// test that exercises this exact spawn/drain/timeout logic against the committed fake CLI. The cancel hook,
    /// the no-SIGPIPE stdin and the exit signalled by `terminationHandler` (W36.seg-opt-subscription) are not in
    /// that copy; `SegmentationPlanTestDriver` tests them against the same fake CLI.
    static func runProcess(binaryPath: String, args: [String], stdinText: String,
                           timeout: TimeInterval, currentDirectory: URL? = nil,
                           canceller: ProcessCanceller? = nil, unsetEnvironment: [String] = []) -> CLIRun {
        if canceller?.isCancelled == true {
            return CLIRun(exitCode: -1, stdout: "", stderr: "", timedOut: false, spawnFailed: false, cancelled: true)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        // The segmentation windows (W36.seg-opt-engine) run `claude -p` in a temp dir holding the window's
        // pages, because prompt w1 says the files are in the current directory. Nil ⇒ inherited, as before.
        if let currentDirectory { proc.currentDirectoryURL = currentDirectory }
        // Inherit the environment but strip the Claude Code nested-session guard so a dev/test run
        // from inside a Claude Code session can still spawn `claude` (prod is unaffected — unset).
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        for key in unsetEnvironment { env.removeValue(forKey: key) }
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Exit is signalled by the termination handler, set before the launch. `waitUntilExit()` on a GCD thread
        // was measured missing an exit (1 call in 60, three at once: the child had exited with its full output and
        // the wait ran on to the timeout), which cost a window its answer and a cancel its promptness.
        let exitSem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exitSem.signal() }
        do {
            try proc.run()
        } catch {
            return CLIRun(exitCode: -1, stdout: "", stderr: "", timedOut: false, spawnFailed: true)
        }
        canceller?.attach(proc)

        // Concurrent drains: read each pipe to EOF on its own queue so a full buffer never blocks the child.
        let outSink = PipeSink(), errSink = PipeSink()
        let group = DispatchGroup()
        for (handle, sink) in [(outPipe.fileHandleForReading, outSink), (errPipe.fileHandleForReading, errSink)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                sink.set(handle.readDataToEndOfFile())
                group.leave()
            }
        }

        // Feed the prompt on stdin, then close so the CLI sees EOF and starts working.
        let inHandle = inPipe.fileHandleForWriting
        // A child stopped by a cancel (or one that dies before reading) closes the pipe: the write must fail with
        // EPIPE, which `try?` drops, rather than raise SIGPIPE, which would end the app.
        _ = fcntl(inHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        if let data = stdinText.data(using: .utf8) { try? inHandle.write(contentsOf: data) }
        try? inHandle.close()

        // Wait for exit with a hard wall-clock timeout.
        var timedOut = false
        if exitSem.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            proc.terminate()                                  // SIGTERM
            if exitSem.wait(timeout: .now() + 3) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)          // escalate
                _ = exitSem.wait(timeout: .now() + 3)
            }
        }
        // Reads return once the child's write ends close (on exit / kill).
        _ = group.wait(timeout: .now() + 5)

        // terminationStatus is only valid once the process has actually exited.
        let exitCode: Int32 = proc.isRunning ? -2 : proc.terminationStatus
        return CLIRun(exitCode: exitCode,
                      stdout: String(decoding: outSink.value, as: UTF8.self),
                      stderr: String(decoding: errSink.value, as: UTF8.self),
                      timedOut: timedOut,
                      spawnFailed: false,
                      cancelled: canceller?.isCancelled == true)
    }

    // MARK: - Prompt helper

    /// Append the absolute image path(s) to the OCR prompt so the CLI agent knows which file(s) to read.
    static func augmentWithImagePaths(_ prompt: String, pagePath: String, previousPath: String?) -> String {
        var out = prompt
        if let prev = previousPath {
            out += "\n\nTWO images are provided as files. The PREVIOUS page is at this absolute path:\n\(prev)"
            out += "\nThe page you must classify and transcribe is at this absolute path:\n\(pagePath)"
            out += "\nRead both files, then perform the tasks above on the second (current) page."
        } else {
            out += "\n\nThe page image to classify and transcribe is saved at this absolute path — " +
                   "read it, then perform the tasks above:\n\(pagePath)"
        }
        return out
    }
}
