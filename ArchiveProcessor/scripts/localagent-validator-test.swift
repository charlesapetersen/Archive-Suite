#!/usr/bin/env swift
import Foundation

// Standalone, $0, no-GUI, no-network, no-real-CLI test of the LocalAgent VALIDATOR's safety-critical
// pure logic (W13.cli-2):
//   (1) LocalAgentClient.exitErrorCode  — stderr/exit → stable code taxonomy (incl. the new
//       cli_entitlement_missing, and the invariants LocalAgentTestDriver relies on:
//       "fake CLI internal error"→cli_exit_3, "not logged in"→cli_not_logged_in);
//   (2) LocalAgentValidator.classify    — code → user-facing Status (+ isUsable + a non-empty message);
//   (3) END-TO-END through the committed fake CLI (scripts/localagent-fake-cli.sh): each mode's real
//       (exit, stderr, stdout) → outcome → classify → Status.
//
// The `exitErrorCode` / `classify` / Status below are COPIES of the app types (OCR/LocalAgentClient.swift,
// OCR/LocalAgentValidator.swift). If you change one, change both. Run:
//   swift ArchiveProcessor/scripts/localagent-validator-test.swift

// ---------------------------------------------------------------------------------------------------
// COPY of LocalAgentTool (Models/LocalAgentConfig.swift) — just what message(tool:) needs.
enum LocalAgentTool: String, CaseIterable { case claude, gemini, codex
    var displayName: String {
        switch self { case .claude: return "Claude Code"; case .gemini: return "Gemini CLI"; case .codex: return "OpenAI Codex CLI" }
    }
}

// COPY of LocalAgentClient.exitErrorCode (OCR/LocalAgentClient.swift). Keep in sync.
func exitErrorCode(stderr: String, exitCode: Int32) -> String {
    let s = stderr.lowercased()
    if s.contains("not logged in") || s.contains("please log in") || s.contains("authenticate")
        || s.contains("unauthenticated") || s.contains("sign in") { return "cli_not_logged_in" }
    if s.contains("not entitled") || s.contains("no access to") || s.contains("does not have access")
        || s.contains("not authorized to use") || s.contains("code assist")
        || s.contains("subscription required") || s.contains("not enabled for")
        || s.contains("isn't enabled") || s.contains("workspace admin") || s.contains("enterprise admin")
        || s.contains("upgrade your plan") || s.contains("requires a paid plan") { return "cli_entitlement_missing" }
    if s.contains("limit") || s.contains("quota") || s.contains("rate") { return "cli_rate_limited" }
    return "cli_exit_\(exitCode)"
}

// COPY of LocalAgentClient.ProbeOutcome + LocalAgentValidator.Status/classify. Keep in sync.
struct ProbeOutcome { let ok: Bool; let code: String?; let message: String? }
enum Status: Equatable {
    case works, cliNotFound, cliNotLoggedIn, cliEntitlementMissing, rateLimited, offline, providerBusy
    case unknown(String)
    var isUsable: Bool { self == .works || self == .rateLimited }
    func message(tool: LocalAgentTool) -> String {
        let name = tool.displayName
        switch self {
        case .works: return "✓ The \(name) CLI is installed and signed in."
        case .cliNotFound: return "The \(name) CLI wasn't found. Install it and sign in — then, if it's in a non-standard location, set its path below."
        case .cliNotLoggedIn: return "The \(name) CLI is installed but not signed in. Run its login command, then verify again."
        case .cliEntitlementMissing: return "You're signed in, but this account isn't authorized to use the \(name) CLI (it needs a Code Assist/API entitlement, or the CLI enabled on your seat). Ask your admin, or use a personal subscription."
        case .rateLimited: return "✓ The \(name) CLI is signed in. You're at the usage limit right now — that's fine; the app paces requests automatically."
        case .offline: return "Couldn't complete the check for the \(name) CLI. Try again."
        case .providerBusy: return "The \(name) CLI didn't respond in time. Try again — the first run can be slow to start."
        case .unknown(let detail): return "Couldn't verify the \(name) CLI (\(detail)). Try again."
        }
    }
}
func classify(_ probe: ProbeOutcome) -> Status {
    if probe.ok { return .works }
    switch probe.code ?? "" {
    case "cli_not_found", "cli_spawn_failed":  return .cliNotFound
    case "cli_not_logged_in":                  return .cliNotLoggedIn
    case "cli_entitlement_missing":            return .cliEntitlementMissing
    case "cli_rate_limited":                   return .rateLimited
    case "cli_timeout":                        return .providerBusy
    case "cli_bad_response":                   return .unknown("unreadable-response")
    case "":                                   return .unknown("no-response")
    case let code:                             return .unknown(code)
    }
}
// ---------------------------------------------------------------------------------------------------

var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool) { if ok { pass += 1; print("PASS: \(name)") } else { fail += 1; print("FAIL: \(name)") } }

// ===== (1) exitErrorCode taxonomy (pure) =====
check("code: 'Not logged in' → cli_not_logged_in", exitErrorCode(stderr: "Error: Not logged in. Please run login.", exitCode: 1) == "cli_not_logged_in")
check("code: 'please log in' → cli_not_logged_in", exitErrorCode(stderr: "Please log in first", exitCode: 1) == "cli_not_logged_in")
check("code: 'does not have access' → cli_entitlement_missing", exitErrorCode(stderr: "Your account does not have access to this CLI.", exitCode: 1) == "cli_entitlement_missing")
check("code: 'workspace admin' → cli_entitlement_missing", exitErrorCode(stderr: "Ask your workspace admin to enable it.", exitCode: 1) == "cli_entitlement_missing")
check("code: 'Code Assist' → cli_entitlement_missing", exitErrorCode(stderr: "A Gemini Code Assist license is required.", exitCode: 1) == "cli_entitlement_missing")
check("code: 'usage limit reached' → cli_rate_limited", exitErrorCode(stderr: "usage limit reached, try later", exitCode: 1) == "cli_rate_limited")
check("code: 'quota' → cli_rate_limited", exitErrorCode(stderr: "quota exceeded", exitCode: 1) == "cli_rate_limited")
// INVARIANTS the in-app LocalAgentTestDriver asserts — must not regress with the entitlement addition:
check("code: 'fake CLI internal error' → cli_exit_3 (fail mode preserved)", exitErrorCode(stderr: "fake CLI internal error", exitCode: 3) == "cli_exit_3")
check("code: empty stderr → cli_exit_N (generic)", exitErrorCode(stderr: "", exitCode: 42) == "cli_exit_42")
// Precedence: a message with BOTH a login and an entitlement hint classifies as login (checked first).
check("code: login beats entitlement when both present", exitErrorCode(stderr: "not logged in; also no access to X", exitCode: 1) == "cli_not_logged_in")

// ===== (2) classify: code → Status (pure), + isUsable + non-empty message =====
check("classify: ok → works",                       classify(ProbeOutcome(ok: true, code: nil, message: nil)) == .works)
check("classify: cli_not_found → cliNotFound",       classify(ProbeOutcome(ok: false, code: "cli_not_found", message: nil)) == .cliNotFound)
check("classify: cli_spawn_failed → cliNotFound",    classify(ProbeOutcome(ok: false, code: "cli_spawn_failed", message: nil)) == .cliNotFound)
check("classify: cli_not_logged_in → cliNotLoggedIn",classify(ProbeOutcome(ok: false, code: "cli_not_logged_in", message: nil)) == .cliNotLoggedIn)
check("classify: cli_entitlement_missing → cliEntitlementMissing", classify(ProbeOutcome(ok: false, code: "cli_entitlement_missing", message: nil)) == .cliEntitlementMissing)
check("classify: cli_rate_limited → rateLimited",    classify(ProbeOutcome(ok: false, code: "cli_rate_limited", message: nil)) == .rateLimited)
check("classify: cli_timeout → providerBusy",        classify(ProbeOutcome(ok: false, code: "cli_timeout", message: nil)) == .providerBusy)
check("classify: cli_bad_response → unknown",        { if case .unknown = classify(ProbeOutcome(ok: false, code: "cli_bad_response", message: nil)) { return true } else { return false } }())
check("classify: cli_exit_7 → unknown(code)",        classify(ProbeOutcome(ok: false, code: "cli_exit_7", message: nil)) == .unknown("cli_exit_7"))
check("classify: nil code → unknown(no-response)",   classify(ProbeOutcome(ok: false, code: nil, message: nil)) == .unknown("no-response"))
// isUsable contract
check("isUsable: works + rateLimited usable; others not",
      Status.works.isUsable && Status.rateLimited.isUsable
      && !Status.cliNotFound.isUsable && !Status.cliNotLoggedIn.isUsable
      && !Status.cliEntitlementMissing.isUsable && !Status.providerBusy.isUsable)
// Every status yields a non-empty, tool-named message.
let allStatuses: [Status] = [.works, .cliNotFound, .cliNotLoggedIn, .cliEntitlementMissing, .rateLimited, .offline, .providerBusy, .unknown("x")]
check("message: every status non-empty & names the tool", allStatuses.allSatisfy {
    let m = $0.message(tool: .gemini); return !m.isEmpty && m.contains("Gemini CLI")
})

// ===== (3) END-TO-END through the real fake CLI =====
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fakeCLI = scriptDir.appendingPathComponent("localagent-fake-cli.sh").path
guard FileManager.default.isExecutableFile(atPath: fakeCLI) else {
    print("FAIL: fake CLI not executable at \(fakeCLI) — run: chmod +x scripts/localagent-fake-cli.sh")
    exit(1)
}

// Minimal synchronous run of the fake CLI (fast — no timeout machinery needed here; the plumbing +
// timeout are proven in localagent-mechanism-test.swift). Returns (exit, stdout, stderr).
func runFake(mode: String) -> (Int32, String, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: fakeCLI)
    var env = ProcessInfo.processInfo.environment
    env["LOCALAGENT_FAKE_MODE"] = mode
    proc.environment = env
    let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
    proc.standardOutput = outPipe; proc.standardError = errPipe; proc.standardInput = inPipe
    try? proc.run()
    inPipe.fileHandleForWriting.write(Data("probe".utf8)); try? inPipe.fileHandleForWriting.close()
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return (proc.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
}

// Mirrors LocalAgentClient.invoke's outcome decision (exit0 + JSON .result non-empty ⇒ ok).
func outcome(exit code: Int32, stdout: String, stderr: String) -> ProbeOutcome {
    if code != 0 { return ProbeOutcome(ok: false, code: exitErrorCode(stderr: stderr, exitCode: code), message: nil) }
    if let j = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
       let r = j["result"] as? String, !r.isEmpty { return ProbeOutcome(ok: true, code: nil, message: nil) }
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? ProbeOutcome(ok: false, code: "cli_bad_response", message: nil)
                           : ProbeOutcome(ok: true, code: nil, message: nil)
}

for (mode, expected) in [("ok", Status.works), ("notlogged", .cliNotLoggedIn),
                         ("entitlement", .cliEntitlementMissing), ("ratelimited", .rateLimited),
                         ("fail", .unknown("cli_exit_3"))] {
    let (code, out, err) = runFake(mode: mode)
    let got = classify(outcome(exit: code, stdout: out, stderr: err))
    check("e2e: fake mode '\(mode)' → \(expected)", got == expected)
}

print("\n\(fail == 0 ? "ALL PASS" : "SOME FAILED") (\(pass) pass, \(fail) fail)")
exit(fail == 0 ? 0 : 1)
