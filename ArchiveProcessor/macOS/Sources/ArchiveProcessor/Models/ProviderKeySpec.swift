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
        blurb: "Archive Processor can also use Mistral to read your archive photos. You'll make your own key — free to create, and OCR works on the free tier (no credit card needed to start). Very heavy use may later need a paid plan; any charges then go to Mistral, never to this app.",
        signInURL: URL(string: "https://console.mistral.ai/api-keys")!,
        billingURL: URL(string: "https://admin.mistral.ai/")!,
        steps: [
            "Sign up (Google / Microsoft / Apple sign-in is easiest).",
            "Verify your email, then your phone by SMS (Mistral requires this).",
            "Open “API Keys” → “Create new key”, then COPY IT NOW — it’s shown only once.",
            "Come back here and paste it below."
        ],
        costNote: "Free — no card needed to start, and OCR works on the free tier. Heavy/bulk use may hit free-tier limits and eventually need a paid plan (your own card; charges go to Mistral, not this app).",
        privacyNote: "For sensitive documents, turn off training in Mistral’s Privacy settings, or use a paid plan (paid is opted out by default). Data is EU-hosted by default.",
        cardNote: "Have your phone ready for an SMS verification code.",
        keyPrecheck: { $0.count >= 20 && !$0.contains(" ") && !$0.hasPrefix("AIza") },   // reject a mis-pasted Gemini key
        validate: { await KeyValidator.validateMistral(key: $0) }
    )

    // ⚠️ W13.oai-2: deep links + on-screen steps mirror the live 2026 OpenAI sign-up flow — re-verify
    // wording/URLs (and capture screenshots) in the keyed/owner tail before shipping, per the type doc
    // comment above. Unlike Gemini/Mistral, the OpenAI *API* has no free tier: a key needs prepaid
    // credits (or a saved card) before a paid run works — GET /v1/models still validates the key itself.
    static let openai = ProviderKeySpec(
        provider: .openai,
        account: LLMProvider.openai.rawValue,
        blurb: "Archive Processor can also use OpenAI (ChatGPT) to read your archive photos. You'll make your own key so you control cost and privacy. OpenAI's API has no free tier, so you'll add a small amount of prepaid credit — any charges go to OpenAI, never to this app.",
        signInURL: URL(string: "https://platform.openai.com/api-keys")!,
        billingURL: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!,
        steps: [
            "Sign in at platform.openai.com (create an account if you don't have one).",
            "Open “Billing” and add a payment method or a little prepaid credit — the API won't run without it.",
            "Open “API keys” → “Create new secret key”, then COPY IT NOW — it's shown only once (it starts with “sk-”).",
            "Come back here and paste it below."
        ],
        costNote: "Pay-as-you-go — no free tier. Add a small prepaid amount to start; you're billed by OpenAI for what you use, not by this app.",
        privacyNote: "OpenAI does not use data sent through the API to train its models by default. API inputs may be retained briefly (about 30 days) for abuse monitoring, then deleted; zero-retention is available to eligible accounts on request.",
        cardNote: "Have a payment method ready — the OpenAI API needs billing set up (a card or prepaid credit) before it will run.",
        keyPrecheck: { $0.hasPrefix("sk-") && $0.count >= 20 && !$0.contains(" ") },
        validate: { await KeyValidator.validateOpenAI(key: $0) }
    )

    // Live-flow check 2026-09-26: the legacy console.anthropic.com URLs redirect to platform.claude.com;
    // the official docs still use Settings → API keys and Billing. New accounts may receive limited test
    // credits, so explain those separately from the absence of an ongoing free tier. A paid run needs
    // billing enabled; GET /v1/models still validates the key itself.
    static let anthropic = ProviderKeySpec(
        provider: .anthropic,
        account: LLMProvider.anthropic.rawValue,
        blurb: "Archive Processor can also use Anthropic's Claude to read your archive photos. You'll make your own key so you control cost and privacy. New API accounts may receive a small amount of test credits; after those run out, usage is billed by Anthropic, never by this app.",
        signInURL: URL(string: "https://platform.claude.com/settings/keys")!,
        billingURL: URL(string: "https://platform.claude.com/settings/billing")!,
        steps: [
            "Sign in to Claude Console at platform.claude.com (create an account if you don't have one).",
            "Open “Billing” to check for test credits and set up payment for later use (a card, invoicing, or prepaid credits, depending on your account).",
            "Open “API keys” → “Create key”, then copy the secret and store it safely (it starts with “sk-ant-api”).",
            "Come back here and paste it below."
        ],
        costNote: "Pay-as-you-go. New API accounts may receive a small amount of test credits; after those run out, Anthropic bills for usage, not this app.",
        privacyNote: "Anthropic does not use data sent through its API to train its models by default. API inputs/outputs may be retained for a limited period for trust-and-safety monitoring, then deleted; zero-retention is available to eligible accounts on request.",
        cardNote: "Set up billing before paid API use. Standard accounts can use a card; invoicing and prepaid credits depend on the account.",
        keyPrecheck: { $0.hasPrefix("sk-ant-") && $0.count >= 20 && !$0.contains(" ") },
        validate: { await KeyValidator.validateAnthropic(key: $0) }
    )

    // W41.app-openrouter. Not in `onboardable`: its on-screen steps have not been checked against the live site.
    // Reached from the segmentation chooser's "add a key" for the GLM approach, and pasted in Settings.
    static let openrouter = ProviderKeySpec(
        provider: .openrouter,
        account: LLMProvider.openrouter.rawValue,
        blurb: "Archive Processor can use open-weight models (Qwen, GLM) through OpenRouter, each on one fixed provider so the price and quality are the ones measured. You'll make your own key; OpenRouter is prepaid, and charges go to OpenRouter, never to this app.",
        signInURL: URL(string: "https://openrouter.ai/settings/keys")!,
        billingURL: URL(string: "https://openrouter.ai/settings/credits")!,
        steps: [
            "Sign in at openrouter.ai (create an account if you don't have one).",
            "Open “Credits” and add a small amount — requests fail without credit.",
            "Open “Keys” → “Create Key”, then copy it (it starts with “sk-or-”).",
            "Come back here and paste it below."
        ],
        costNote: "Prepaid, pay-as-you-go. The models offered here cost about $1.20–$1.75 per 1,000 pages to read.",
        privacyNote: "OpenRouter passes each page to the one provider named for its model. Check OpenRouter's privacy settings for whether providers that keep or train on data are allowed for your account.",
        cardNote: "Have a payment method ready to buy credits.",
        keyPrecheck: { $0.hasPrefix("sk-or-") && $0.count >= 20 && !$0.contains(" ") },
        validate: { await KeyValidator.validateOpenRouter(key: $0) }
    )

    /// The providers offered in the guided wizard (each also still supports manual key entry).
    static let onboardable: [ProviderKeySpec] = [.anthropic, .gemini, .mistral, .openai]
}
