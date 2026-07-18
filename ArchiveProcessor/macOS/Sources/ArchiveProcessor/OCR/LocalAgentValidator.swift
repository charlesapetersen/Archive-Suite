import Foundation

/// Confirms a locally installed, subscription-authenticated CLI (`claude` / `gemini` / `codex`) is
/// **installed and signed in** before the Local Agent OCR backend relies on it — the CLI analog of
/// `KeyValidator`. It runs a cheap two-step check (detect the binary, then a 1-token round-trip) and
/// maps every outcome to a plain-English status the Settings "Detect & Verify" button (and the
/// onboarding wizard, later) can show.
///
/// It never surfaces raw stderr: the CLI's exit is classified inside `LocalAgentClient` (ONE taxonomy
/// shared with the OCR error path — `exitErrorCode`), and this type only maps that stable code to a
/// user-facing `Status`. That code→status map (`classify`) is pure and unit-tested against the full
/// taxonomy by `scripts/localagent-validator-test.swift` ($0, headless, no real CLI).
enum LocalAgentValidator {

    /// Outcome of detect-and-verify, mapped to user-facing guidance. Adds the CLI-specific
    /// `cliNotFound` / `cliNotLoggedIn` / `cliEntitlementMissing` states and reuses the transient
    /// `rateLimited` / `offline` / `providerBusy` semantics of `KeyValidator.KeyStatus`.
    enum Status: Equatable {
        case works                  // ✓ installed and signed in (a trivial prompt returned a response)
        case cliNotFound            // explicit path invalid, or binary absent from standard locations
        case cliNotLoggedIn         // installed, but no active subscription login
        case cliEntitlementMissing  // signed in, but the account/seat isn't authorized to use this CLI
        case rateLimited            // signed in, but at the usage window right now (transient; app paces)
        case offline                // the check couldn't complete for a non-CLI reason (transient)
        case providerBusy           // the CLI didn't respond in time (transient)
        case unknown(String)        // unexpected; detail is logged, not blamed on the user

        /// Good enough to let the user proceed: authenticated (a usage-window limit is transient + paced).
        var isUsable: Bool { self == .works || self == .rateLimited }

        /// One plain-English sentence for the user (never raw stderr).
        func message(tool: LocalAgentTool) -> String {
            let name = tool.displayName
            switch self {
            case .works:
                return "✓ The \(name) CLI is installed and signed in."
            case .cliNotFound:
                return "The \(name) CLI wasn't found. Install it and sign in — then, if it's in a non-standard location, set its path below."
            case .cliNotLoggedIn:
                return "The \(name) CLI is installed but not signed in. Run its login command, then verify again."
            case .cliEntitlementMissing:
                return "You're signed in, but this account isn't authorized to use the \(name) CLI (it needs a Code Assist/API entitlement, or the CLI enabled on your seat). Ask your admin, or use a personal subscription."
            case .rateLimited:
                return "✓ The \(name) CLI is signed in. You're at the usage limit right now — that's fine; the app paces requests automatically."
            case .offline:
                return "Couldn't complete the check for the \(name) CLI. Try again."
            case .providerBusy:
                return "The \(name) CLI didn't respond in time. Try again — the first run can be slow to start."
            case .unknown(let detail):
                return "Couldn't verify the \(name) CLI (\(detail)). Try again."
            }
        }
    }

    /// `--version` liveness-probe ceiling — near-instant, no auth, no token spend.
    static let versionTimeout: TimeInterval = 20

    /// Detect the CLI, then confirm it is signed in. Never throws; every failure maps to a `Status`.
    /// Both steps run off the main thread (via `LocalAgentClient`'s async subprocess plumbing), so
    /// this is safe to `await` from a `@MainActor` view without blocking the UI.
    static func detectAndVerify(config: LocalAgentConfig) async -> Status {
        // 1) Detect: resolve to an absolute binary (explicit override, otherwise standard paths; never $PATH).
        guard let binary = LocalAgentClient.resolveBinaryPath(tool: config.tool, override: config.binaryPath) else {
            return .cliNotFound
        }
        // 2) Liveness: `--version` is cheap and unauthenticated. A spawn failure here means the path
        //    isn't a runnable CLI. (A non-zero exit or empty output is tolerated — CLIs differ; the
        //    signed-in round-trip below is authoritative.)
        let version = await LocalAgentClient.runAsync(binaryPath: binary, args: ["--version"],
                                                      stdinText: "", timeout: versionTimeout)
        if version.spawnFailed { return .cliNotFound }
        // 3) Signed-in: a 1-token round-trip through the same spawn path OCR uses.
        let probe = await LocalAgentClient(config: config).probe()
        return classify(probe)
    }

    /// Map a `LocalAgentClient.ProbeOutcome` to a user-facing `Status`. Pure (no I/O) — this is the
    /// safety-critical mapping the standalone test exhausts. Codes come from `LocalAgentClient`.
    static func classify(_ probe: LocalAgentClient.ProbeOutcome) -> Status {
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
}
