import Foundation

/// Per-CLI configuration that drives the guided Local Agent onboarding wizard (`LocalAgentWizard`) —
/// the **no-API-key** analog of `ProviderKeySpec`. Each subscription-authenticated CLI (Claude Code,
/// Gemini CLI) gets a spec: what it is, how to install + sign in, the common entitlement gotcha, and a
/// **Detect + Verify** that drives `LocalAgentValidator`. Holds **no key** — auth lives entirely in the
/// CLI's own subscription login.
///
/// Install links + on-screen steps mirror the live 2026 setup flows — re-verify wording/URLs (and
/// capture screenshots) in the keyed/owner tail before shipping, exactly like `ProviderKeySpec`.
/// Codex is intentionally NOT in the guided wizard (it stays available via the Settings tool picker),
/// mirroring how Anthropic is reachable via manual key entry but omitted from the key wizard.
struct LocalAgentSpec: Identifiable, Sendable {
    var id: String { tool.rawValue }
    let tool: LocalAgentTool
    var displayName: String { tool.displayName }

    let blurb: String                 // plain-language what/why, shown on the intro step
    let installURL: URL               // deep link to install the CLI
    let docsURL: URL?                 // deeper docs (auth / entitlement)
    let steps: [String]               // on-screen numbered setup steps mirroring the live flow
    let entitlementNote: String       // the common "signed in but not authorized" gotcha
    let tosNote: String               // one-line personal-use note

    /// Detect + verify install/sign-in for a config (path/model come from the wizard fields). Reuses the
    /// exact same validator the Settings "Detect & Verify" button uses.
    let detectAndVerify: @Sendable (LocalAgentConfig) async -> LocalAgentValidator.Status

    // MARK: - Specs

    static let claude = LocalAgentSpec(
        tool: .claude,
        blurb: "Use your existing Claude subscription (Pro/Max, or a Team/Enterprise seat with Claude Code enabled) to read your archive photos — no API key and no per-token cost. Requires the Claude Code CLI installed and signed in.",
        installURL: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!,
        docsURL: URL(string: "https://docs.claude.com/en/docs/claude-code/overview")!,
        steps: [
            "Install the Claude Code CLI (open the install page below).",
            "In a terminal, run “claude” once and complete the subscription sign-in (it uses your plan, not an API key).",
            "If it’s installed somewhere non-standard, set its path in the field below.",
            "Come back here and press Detect & Verify."
        ],
        entitlementNote: "A personal Pro/Max subscription works directly. A Team/Enterprise seat must have Claude Code enabled by the workspace admin.",
        tosNote: "Personal use of your own subscription on your own archive is intended use.",
        detectAndVerify: { await LocalAgentValidator.detectAndVerify(config: $0) }
    )

    static let gemini = LocalAgentSpec(
        tool: .gemini,
        blurb: "Use your Google Gemini entitlement to read your archive photos — no API key. Requires the Gemini CLI installed and signed in. The CLI needs a Gemini Code Assist or API entitlement — not the chat-app tier.",
        installURL: URL(string: "https://github.com/google-gemini/gemini-cli")!,
        docsURL: URL(string: "https://developers.google.com/gemini-code-assist/docs/gemini-cli")!,
        steps: [
            "Install the Gemini CLI (open the install page below).",
            "In a terminal, run “gemini” and sign in with “Login with Google”.",
            "Confirm your account has a Gemini Code Assist / API entitlement (the chat app alone won’t authorize the CLI).",
            "Come back here and press Detect & Verify."
        ],
        entitlementNote: "Gemini chat-app tiers (Enterprise Standard/Pro) do NOT authorize the CLI — it needs a Gemini Code Assist license or a Gemini API entitlement. Detect & Verify says so plainly if your account isn’t authorized.",
        tosNote: "Personal use of your own subscription on your own archive is intended use.",
        detectAndVerify: { await LocalAgentValidator.detectAndVerify(config: $0) }
    )

    /// The CLIs offered in the guided wizard (Codex remains available via the Settings tool picker).
    static let onboardable: [LocalAgentSpec] = [.claude, .gemini]
}
