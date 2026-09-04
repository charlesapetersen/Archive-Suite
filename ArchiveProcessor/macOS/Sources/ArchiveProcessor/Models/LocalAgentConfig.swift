import Foundation

/// Which locally installed, subscription-authenticated CLI the Local Agent backend drives. This
/// backend runs OCR/tagging by shelling out to a first-party CLI that authenticates against the
/// user's *subscription* (no API key, no gateway) — see `LocalAgentClient` and
/// `execution-plans/local-agent-cli-provider.md`.
///
/// PERSISTENCE INVARIANT (SHARED HOTSPOT): a value of this enum is stored — via `LocalAgentConfig` —
/// inside the run-config snapshot that crash-resume decodes (`OCRProcessor.PendingRun`). It is
/// therefore **append-only**: add cases, never rename or remove one, exactly like `LLMProvider`
/// (`ProviderModels.swift`). Removing/renaming a case would break decoding of an in-flight run's
/// manifest that was written by an older build.
enum LocalAgentTool: String, Codable, Sendable, CaseIterable {
    case claude   // Claude Code CLI — Pro/Max/Team/Enterprise subscription
    case gemini   // Gemini CLI — Gemini Code Assist / API entitlement
    case codex    // OpenAI Codex CLI — "Sign in with ChatGPT" (Plus/Pro/Team/Enterprise/Edu)

    /// Bare executable name searched on the standard install paths when no explicit override is set.
    var binaryName: String {
        switch self {
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .codex:  return "codex"
        }
    }

    /// Human-facing name for the Settings picker / onboarding wizard.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .gemini: return "Gemini CLI"
        case .codex:  return "OpenAI Codex CLI"
        }
    }
}

/// Snapshot of the Local Agent backend selection, threaded through the run config **alongside**
/// `GatewayConfig?` (Design decision 2 of the local-agent plan). It is additive + optional at the
/// carrier level (`localAgent: LocalAgentConfig?`, default `nil`) so a run snapshot written before
/// this feature decodes byte-for-byte unchanged (the field is simply absent → `nil`) and crash-resume
/// of an in-flight capture — the highest-consequence surface in this app — stays untouched.
///
/// Holds **no API key**: auth lives entirely in the CLI's own subscription login. Mirrors
/// `GatewayConfig`'s plain synthesized `Codable` — back-compat is provided by the *optional at the
/// `PendingRun` level*, not by a custom decoder here. SHARED HOTSPOT: append fields only, and append
/// them as optional / defaulted so older manifests keep decoding.
struct LocalAgentConfig: Codable, Equatable, Sendable {
    /// Which CLI to drive.
    var tool: LocalAgentTool
    /// Absolute path to the resolved CLI binary. Empty ⇒ `LocalAgentClient` resolves it from the
    /// standard install locations at call time (never from `$PATH`, to avoid PATH injection).
    var binaryPath: String
    /// Optional model passed to the CLI (`--model`); nil ⇒ let the CLI use its own default.
    var modelOverride: String?
    /// Requested max concurrent subprocess calls. Subprocess calls bypass the `NetworkSession` HTTP
    /// in-flight limiter, so this path paces itself with a deliberately LOW cap so it never hammers a
    /// personal subscription. Use `effectiveConcurrencyCap` (clamped 1…2) at call sites.
    var concurrencyCap: Int

    init(tool: LocalAgentTool, binaryPath: String = "", modelOverride: String? = nil, concurrencyCap: Int = 1) {
        self.tool = tool
        self.binaryPath = binaryPath
        self.modelOverride = modelOverride
        self.concurrencyCap = concurrencyCap
    }

    /// Concurrency clamped to the safe subscription-paced range (1…2), even if a bad value was stored.
    var effectiveConcurrencyCap: Int { min(2, max(1, concurrencyCap)) }

    /// Durable-provenance labels for a result produced through this CLI. The selected direct-provider
    /// model is only a UI fallback on this backend; it must never be credited in an output PDF or run log.
    var provenanceDisplayName: String { "Local CLI Agent (\(tool.binaryName))" }
    var provenanceModelName: String {
        // This reaches the free-form PDF header. Keep it to one physical line so a Settings value cannot
        // impersonate a later header field or classification marker in the durable text page.
        let model = (modelOverride ?? "")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? "CLI default" : model
    }

    /// Build the Local Agent config from the shared app settings, or nil when the Local Agent backend is
    /// not the selected OCR backend. The single source of truth for `SessionProcessingConfig.fromDefaults`
    /// (Live Capture) and `OCRView.currentLocalAgentConfig` (Process Files), mirroring
    /// `GatewayConfig.fromDefaults`. `useLocalAgent` is the operator's explicit 3-way backend choice
    /// (mutually exclusive with `useGateway`, enforced in Settings), so an enabled toggle ALWAYS yields a
    /// config: the tool defaults to `.claude`, and a blank binary path means "resolve at call time from the
    /// standard install locations" (never `$PATH`). If the CLI is missing / not signed in at call time,
    /// `LocalAgentClient` returns a friendly failure — so an over-eager `nil`/empty guard here (as gateway
    /// uses for its required URL/model) would wrongly silently fall back to a metered path the user didn't pick.
    static func fromDefaults(_ d: UserDefaults = .standard) -> LocalAgentConfig? {
        guard d.bool(forKey: DefaultsKeys.useLocalAgent) else { return nil }
        let tool = LocalAgentTool(rawValue: d.string(forKey: DefaultsKeys.localAgentTool) ?? "") ?? .claude
        let binaryPath = d.string(forKey: DefaultsKeys.localAgentBinaryPath) ?? ""
        let model = d.string(forKey: DefaultsKeys.localAgentModel) ?? ""
        return LocalAgentConfig(tool: tool, binaryPath: binaryPath,
                                modelOverride: model.isEmpty ? nil : model)
    }
}
