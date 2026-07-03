import Foundation

/// Per-provider configuration that drives the one reusable guided key-onboarding wizard
/// (`ProviderKeyWizard`). Gemini and Mistral each get a spec; the wizard is otherwise generic, and
/// the app works with any single provider's key. Deep links / steps mirror the live 2026 sign-up
/// flows — re-verify wording + capture screenshots before shipping (see DISTRIBUTION_PLAN.md §5).
struct ProviderKeySpec: Identifiable, Sendable {
    var id: String { account }
    let provider: LLMProvider
    /// Keychain account (matches the existing per-provider storage: `LLMProvider.rawValue`).
    let account: String
    var displayName: String { provider.rawValue }

    let blurb: String                 // plain-language what/why, shown on the intro step
    let signInURL: URL                // deep link to create a key
    let billingURL: URL?              // enable billing / add card (region or plan)
    let privacyURL: URL?              // data-use / training opt-out
    let steps: [String]               // on-screen numbered instructions mirroring the live site
    let costNote: String
    let privacyNote: String
    let cardNote: String?             // extra heads-up (e.g. "have your phone ready", "may need your card")

    /// Loose client-side sanity check before spending a validation call (not authoritative).
    let keyPrecheck: @Sendable (String) -> Bool
    /// Live auth validation (cheap call), mapped to a plain-English status.
    let validate: @Sendable (String) async -> KeyValidator.KeyStatus

    // MARK: - Specs

    static let gemini = ProviderKeySpec(
        provider: .gemini,
        account: LLMProvider.gemini.rawValue,
        blurb: "Archive Processor uses Google Gemini to read your archive photos. You'll make your own free key so you control cost and privacy. Takes about 3 minutes — no credit card needed for typical use.",
        signInURL: URL(string: "https://aistudio.google.com/apikey")!,
        billingURL: URL(string: "https://ai.google.dev/gemini-api/docs/billing")!,
        privacyURL: URL(string: "https://ai.google.dev/gemini-api/terms")!,
        steps: [
            "Sign in with any Google account (a free Gmail works).",
            "Click “Create API key”, then choose “Create API key in new project”.",
            "Copy the key — it starts with “AIza”.",
            "Come back here and paste it below."
        ],
        costNote: "Free for typical use — no credit card required.",
        privacyNote: "On the free plan Google may use your images to improve its AI, and staff may review them. For sensitive records, enable billing (paid plan) — then your data isn’t used for training. In the EU/UK/Switzerland, Google requires the paid plan.",
        cardNote: nil,
        keyPrecheck: { $0.hasPrefix("AIza") && $0.count >= 30 },
        validate: { await KeyValidator.validateGemini(key: $0) }
    )

    static let mistral = ProviderKeySpec(
        provider: .mistral,
        account: LLMProvider.mistral.rawValue,
        blurb: "Archive Processor can also use Mistral to read your archive photos. You'll make your own key. It's free to create; OCR may require adding your own card to Mistral — any charges go to Mistral, never to this app.",
        signInURL: URL(string: "https://console.mistral.ai/api-keys")!,
        billingURL: URL(string: "https://admin.mistral.ai/")!,
        privacyURL: URL(string: "https://help.mistral.ai/en/articles/455207-can-i-opt-out-of-my-input-or-output-data-being-used-for-training")!,
        steps: [
            "Sign up (Google / Microsoft / Apple sign-in is easiest).",
            "Verify your email, then your phone by SMS (Mistral requires this).",
            "Open “API Keys” → “Create new key”, then COPY IT NOW — it’s shown only once.",
            "Come back here and paste it below."
        ],
        costNote: "Free to create. OCR may need a paid plan — you'd add your own card in Mistral (charges go to Mistral, not this app).",
        privacyNote: "For sensitive documents, turn off training in Mistral’s Privacy settings, or use a paid plan (paid is opted out by default). Data is EU-hosted by default.",
        cardNote: "Have your phone ready for an SMS verification code.",
        keyPrecheck: { $0.count >= 20 && !$0.contains(" ") },
        validate: { await KeyValidator.validateMistral(key: $0) }
    )

    /// The providers offered in the guided wizard (Anthropic remains available via manual key entry).
    static let onboardable: [ProviderKeySpec] = [.gemini, .mistral]
}
