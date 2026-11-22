import Foundation

// INVARIANT — the provider/model/mode enums below are String-backed, Codable, and PERSISTED (in
// UserDefaults and in encoded snapshots like PendingRun / PendingBatch / SessionProcessingConfig).
// Never rename a case or change an explicit rawValue string: that orphans users' saved settings.
// Appending new cases is safe; reordering is harmless (the persisted key is the string, not the position).
// This is a cross-lane shared hotspot — see CLAUDE.md → "Concurrent / multi-agent development."

// MARK: - Providers

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic = "Anthropic"
    case gemini = "Gemini"
    case mistral = "Mistral"
    case openai = "OpenAI"   // append-only (persisted rawValue) — never reorder/rename existing cases
    case appleVision = "Apple Vision" // on-device transcription backend; append-only like the API providers
    case openrouter = "OpenRouter"    // W41.app-openrouter: open-weight models, each on one pinned provider

    var id: String { rawValue }

    var models: [LLMModel] {
        let builtIn: [LLMModel]
        switch self {
        case .anthropic: builtIn = LLMModel.anthropicModels
        case .gemini: builtIn = LLMModel.geminiModels
        case .mistral: builtIn = LLMModel.mistralModels
        case .openai: builtIn = LLMModel.openaiModels
        case .appleVision: builtIn = LLMModel.appleVisionModels
        // W41.app-openrouter-unmeasured: the pinned routes, then every other image model OpenRouter lists and every id
        // the user typed, unpinned and marked not measured (`OpenRouterListing`).
        case .openrouter:
            let listed = LLMModel.openrouterModels + OpenRouterListing.unmeasuredModels()
            let ids = Set(listed.map(\.id))
            return listed + OpenRouterListing.typedModels().filter { !ids.contains($0.id) }
                .map { OpenRouterListing.typed($0) }
        }
        let custom = CustomModelStore.shared.models(for: self)
        return builtIn + custom
    }

    var supportsBatch: Bool {
        switch self {
        case .anthropic, .gemini, .mistral: return true
        case .openai, .appleVision, .openrouter:
            return false   // Apple Vision is local; OpenAI Batch API is Phase 4; OpenRouter has no batch endpoint.
        }
    }
}

// MARK: - Thinking Level

enum ThinkingLevel: String, CaseIterable, Identifiable, Codable {
    case low = "Low"
    case high = "High"
    var id: String { rawValue }

    /// OpenAI `reasoning_effort` value for this level (o-series / GPT-5 reasoning models). The app's
    /// two-level Low/High control maps to OpenAI's low/high; the selected model's default is used when
    /// no level is chosen (nil). Sent ONLY on reasoning-capable models — the
    /// `OpenAICompatibleClient.openAI(model:apiKey:thinkingLevel:)` factory gates this on
    /// `model.supportsThinking`, since non-reasoning OpenAI models reject `reasoning_effort`.
    var openAIReasoningEffort: String {
        switch self {
        case .low: return "low"
        case .high: return "high"
        }
    }
}

// MARK: - Document Classification

enum DocumentClassification: String, Codable {
    case boxLabel = "box_label"
    case folderLabel = "folder_label"
    case documentStart = "document_start"
    case documentContinuation = "document_continuation"

    var displayName: String {
        switch self {
        case .boxLabel: return "Box"
        case .folderLabel: return "Folder"
        case .documentStart: return "Document Start"
        case .documentContinuation: return "Continuation"
        }
    }
}

// MARK: - Tagging Mode

/// How tags are assigned to document segments. Who segments is the separate `SegmentationApproach`
/// (W36.seg-opt-review; the two join in `SegmentationPlan`). The old `autoDateManualSeg` is `autoDate` with the
/// approach `manual`; no migration is written because no run or setting has been kept (owner, 2026-08-01).
enum TaggingMode: String, CaseIterable, Identifiable, Codable {
    case none              // No tagging
    case copySource        // Copy macOS Finder tags from source images to output PDFs
    case automatic         // LLM generates all tags (date + subjects) — the original behavior
    case autoDate          // LLM fills each date; the user enters subject tags
    case human             // The user enters date + subject tags entirely

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "No tagging"
        case .copySource: return "Copy source file tags"
        case .automatic: return "Automatic (LLM)"
        case .autoDate: return "Auto date, manual subjects"
        case .human: return "Manual (human)"
        }
    }

    var detail: String {
        switch self {
        case .none: return "Skip tagging entirely."
        case .copySource: return "Read macOS Finder tags from each source image and apply them to the output PDF. No LLM tagging."
        case .automatic: return "The model generates date and subject tags for every document."
        case .autoDate: return "The model fills in each document's date; you enter its subject tags."
        case .human: return "You enter the date and subject tags for every document."
        }
    }

    /// Whether this mode performs LLM/segment-based tagging (drives segmentation review, box/folder confirm, and Phase 2).
    var enablesTagging: Bool { self != .none }

    /// Whether outputs from this mode get a trailing "Unread" tag. Applies to modes that generate
    /// real tags (date/subject/Quality); excludes "No tagging" and "Copy source tags".
    var stampsUnread: Bool { self != .none && self != .copySource }

    /// Whether the user manually tags each segment (any mode with a manual tagging UI).
    var isManual: Bool { self == .autoDate || self == .human }

    /// Whether the LLM makes per-segment tagging/date calls (drives the tagging cost/time estimate).
    /// Excludes `.human` (user enters everything), `.copySource`, and `.none` (no LLM tagging calls).
    var llmTags: Bool { self == .automatic || self == .autoDate }
}

// MARK: - Rotation Mode

/// How the app detects the rotation needed to make each scanned image upright. The default is the agreement rule
/// Phase 4 chose (W46.rotation-default, `execution-plans/processing-review/13-stage-rules/01-reading-copy.md`); the
/// figures are W46.rotation-heldout's, on 119 owner pages no detector was tuned on (`segbench-results/rotation-routes.md`).
enum RotationMode: String, CaseIterable, Identifiable, Codable {
    case off               // No rotation correction
    case localVision       // Free, local macOS Vision alone
    case agreement         // Vision checked by PP-LCNet; a disagreement goes to Gemini 3.7 Flash when available
    case llmSingle         // One LLM "which-of-4-is-upright" comparative call
    case llmMajority       // Three comparative calls, majority vote; a tie takes the first ordering's answer

    /// What a fresh install runs, and what an unset or unknown stored value reads as.
    static let standard: RotationMode = .agreement

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .localVision: return "Local Vision only"
        case .agreement: return "Local, checked (recommended)"
        case .llmSingle: return "LLM comparative"
        case .llmMajority: return "LLM comparative ×3"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Do not correct rotation."
        case .localVision: return "On-device macOS Vision alone. Free and fast; wrong on 3 of 119 held-out pages, one of them a folder whose tab label reads upright as stored. Ambiguous text keeps the OCR model’s rotation guess."
        case .agreement: return "Vision’s answer is checked by a second on-device model (PP-LCNet). When they agree, the app uses their answer. If they disagree or Vision finds no text, a remote API gateway or OpenRouter asks Gemini 3.7 Flash once (about 1 page in 10). With another backend, the page is left as it is and counted as unsure. If the call fails, the app keeps Vision’s turn and counts the page as unsure. On this Mac alone: wrong on 2 of 119 held-out pages (a near-blank cover and a folder whose tab label reads upright as stored), 14 left. With the gateway: wrong on 3 of 119, two near-blank covers and that folder. For charters, and Arabic, Hebrew or Chinese pages, choose LLM comparative: the local models leave most of those."
        case .llmSingle: return "Shows the model all four rotations and asks which is upright — one extra cheap API call per image. The route for charters and non-Latin scripts."
        case .llmMajority: return "Repeats the comparison three times and takes the majority vote; three extra cheap API calls per image."
        }
    }

    /// Number of shuffled orderings to vote over (LLM modes only; the agreement rule's call is one ordering, made
    /// only on the pages the local models do not settle).
    var orderings: Int {
        switch self {
        case .llmMajority: return 3
        case .llmSingle: return 1
        default: return 0
        }
    }

    /// The share of pages the agreement rule sends to Gemini 3.7 Flash: the held-out owner pages' 45 of 476 turns
    /// (W46.rotation-heldout). The estimators price and time that share of one call.
    static let agreementEscalationShare = 45.0 / 476.0
}

// MARK: - Models

struct LLMModel: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let provider: LLMProvider
    let supportsThinking: Bool
    let returnsMd: Bool
    let inputCostPer1M: Double
    let outputCostPer1M: Double
    let batchDiscount: Double
    /// W41.app-openrouter-unmeasured: true for an OpenRouter model whose listing gives no price (a typed id), so its
    /// costs are unknown rather than zero: no estimate and no `max_price`. Fixed when the model is offered, so the run
    /// keeps what its estimate said. Appended (persisted snapshots decode without it).
    var unpriced: Bool? = nil

    static let appleVisionModels: [LLMModel] = [
        LLMModel(
            id: "macos-vision",
            displayName: "macOS Vision",
            provider: .appleVision,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0,
            outputCostPer1M: 0,
            batchDiscount: 1
        ),
        // W47.wh-readers-lost-clients: the macOS 27 on-device model (`OnDeviceModelClient`), the route table's
        // lower-scoring row `apple-fm-27` (42.4 NES strict on the 96 against Vision's 83.1). Second, so Vision stays
        // the default and every Vision reference (`appleVisionModels[0]`) stays Vision; chosen only on the reading card.
        LLMModel(
            id: OnDeviceModelClient.modelID,
            displayName: "macOS 27 on-device model",
            provider: .appleVision,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0,
            outputCostPer1M: 0,
            batchDiscount: 1
        ),
    ]

    // W41.app-openrouter-claude: Claude Sonnet 5.5 is the one Claude model the bench read the owner's 96 with (the
    // route table's reading row `claude-sonnet5.5`: 96.48 NES, every page answered, handwriting 92.5; through
    // `claude -p` on the owner's plan, so its figure is that route's, carried here with no parity check, owner
    // 2026-11-18). Claude Opus 5.5 drafted part of that truth, so Sonnet 5.5 is a relative of a drafter: say so
    // wherever the figure is shown. It is first, so the Anthropic key's default is the measured model. Anthropic's list
    // price, checked 2026-11-18 (platform.claude.com/docs/en/about-claude/pricing): $2 in, $10 out, half in a batch.
    // The 4.6 entries were never measured; they stay under their ids (persisted selections).
    // Not here, and not routes: Opus 5.5 split one development box (Deaver) at 97.9% with the cues prompt, tied with
    // Sonnet 5.5, Gemini 3.8 Flash and Codex (`cues-models-Deaver.md`), and it drafted the 96's truth, so it cannot be
    // scored on them; Haiku 4.5 read NewsBench's 15 newspaper pages in the Vision OCR lab's table, 0.894 with PaddleX
    // layout and 0.232 whole page, below the other layout models (`farmshare/news/newsbench-score.txt`). TABME's 0.782
    // in `seg_tabme.py` is the paper's figure, not ours. Both reach the app only unmeasured, through OpenRouter's
    // listing (`OpenRouterListing`).
    static let anthropicModels: [LLMModel] = [
        LLMModel(
            id: "claude-sonnet-5-5",
            displayName: "Claude Sonnet 5.5",
            provider: .anthropic,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 2.0,
            outputCostPer1M: 10.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            provider: .anthropic,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 3.0,
            outputCostPer1M: 15.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "claude-opus-4-6",
            displayName: "Claude Opus 4.6",
            provider: .anthropic,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 15.0,
            outputCostPer1M: 75.0,
            batchDiscount: 0.5
        ),
    ]

    // The FIRST entry is the default OCR model (`ModelSelectionStore.model(for:)` falls back to `models[0]`).
    // W41.app-ocr-default (2026-10-15), re-checked against the Phase 4 rule table by W43.app-guide-refresh
    // (`segbench-results/settings-routes.json`, reading rows; NES on the pages a route answered of the owner's 96):
    // 3.8 Flash 96.47 at $3.22 per 1,000 pages, the cheap-API pick (it ties 3.1 Pro's 96.85, at $21.92, under the
    // 0.49 floor), and best of the app's routes on handwriting (95.81) — but it is one of the truth's two drafters,
    // so its lead may be partly flattery; say so wherever the figure is shown. 3.5 Flash-Lite 95.17 at $1.57, the
    // budget choice; 3.1 Flash-Lite 94.59 at $1.17. The 2.5 family and 3 Flash Preview were not read by the bench.
    // Prices checked 2026-10-15 on ai.google.dev/gemini-api/docs/pricing. 3.8 Flash's are INTRODUCTORY to
    // 31 Dec 2026 ($1.50/$7.50 from 1 Jan 2027) — update this entry then.
    // Every Gemini route refuses some reprinted printed text; `OCRRefusalFallback` reads those pages.
    static let geminiModels: [LLMModel] = [
        LLMModel(
            id: "gemini-3.8-flash",
            displayName: "Gemini 3.8 Flash",
            provider: .gemini,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 0.75,
            outputCostPer1M: 3.75,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3.5-flash-lite",
            displayName: "Gemini 3.5 Flash Lite",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0.30,
            outputCostPer1M: 2.50,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3.1-flash-lite",
            displayName: "Gemini 3.1 Flash Lite",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0.25,
            outputCostPer1M: 1.50,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3.5-flash",
            displayName: "Gemini 3.5 Flash",
            provider: .gemini,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 1.50,
            outputCostPer1M: 9.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3.1-pro",
            displayName: "Gemini 3.1 Pro",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 2.0,
            outputCostPer1M: 12.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3-flash-preview",
            displayName: "Gemini 3 Flash Preview",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0.50,
            outputCostPer1M: 3.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            provider: .gemini,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 0.075,
            outputCostPer1M: 0.30,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-2.5-flash-lite",
            displayName: "Gemini 2.5 Flash Lite",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0.0375,
            outputCostPer1M: 0.15,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-2.5-pro",
            displayName: "Gemini 2.5 Pro",
            provider: .gemini,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 1.25,
            outputCostPer1M: 10.0,
            batchDiscount: 0.5
        ),
    ]

    // `mistral-ocr-latest` resolved to Mistral OCR 4.1 when the bench read the 96 through this app's MistralClient
    // (`ocr_cloud_mistral.py`): 93.01 NES at $4 per 1,000 pages, $2 in a batch (`settings-routes.json`).
    static let mistralModels: [LLMModel] = [
        LLMModel(
            id: "mistral-ocr-latest",
            displayName: "Mistral OCR 4.1",
            provider: .mistral,
            supportsThinking: false,
            returnsMd: true,
            inputCostPer1M: 1.0,
            outputCostPer1M: 1.0,
            batchDiscount: 0.5
        ),
    ]

    // ⚠️ W13.oai-1 PLACEHOLDERS — model IDs AND per-1M pricing remain unverified for the other entries;
    // W21.verify checked gpt-5.4-mini against OpenAI's live model page on 2026-09-26. A wrong price is a
    // silent cost-estimator bug, so confirm the remaining entries before the live OCR smoke; do not treat
    // those prices as authoritative.
    // `supportsThinking: true` marks the reasoning families (o-series / GPT-5) that require
    // `max_completion_tokens` — see `OpenAICompatibleClient.openAI(model:apiKey:)`. First entry is the
    // default OCR model: GPT-5.4 mini, the only OpenAI model the bench read (W43.app-guide-refresh, from
    // `settings-routes.json`: 94.81 NES on the pages it answered of the owner's 96, $5.55 per 1,000 pages, read at
    // reasoning `minimal`); the others, cheapest to flagship, are unmeasured.
    // Model IDs + per-1M prices are the current GPT-5 generation, priced per the owner-provided source
    // (SoCOCRbench — https://noahdasanaike.github.io/posts/sococrbench.html, captured 2026-07-16), ordered
    // cheapest→flagship after the default. `supportsThinking` follows current API capability, not the reasoning mode selected
    // by a benchmark run; GPT-5.4 mini supports `reasoning_effort` and defaults to `none`. IDs follow OpenAI's
    // lowercase-hyphen convention; live request confirmation for the remaining unverified entries remains
    // the keyed OCR smoke — a wrong ID surfaces there, not silently in the estimator.
    static let openaiModels: [LLMModel] = [
        LLMModel(
            id: "gpt-5.4-mini",
            displayName: "GPT-5.4 mini",
            provider: .openai,
            supportsThinking: true,            // OpenAI lists reasoning-effort support; default is `none`.
            returnsMd: false,
            inputCostPer1M: 0.75,
            outputCostPer1M: 4.50,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gpt-5-nano",
            displayName: "GPT-5 nano",
            provider: .openai,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 0.05,
            outputCostPer1M: 0.40,
            batchDiscount: 0.5                 // OpenAI Batch API ~50%; batch skipped in v1 (supportsBatch=false)
        ),
        LLMModel(
            id: "gpt-5-mini",
            displayName: "GPT-5 mini",
            provider: .openai,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 0.25,
            outputCostPer1M: 2.00,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gpt-5.4",
            displayName: "GPT-5.4",
            provider: .openai,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 2.50,
            outputCostPer1M: 15.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gpt-5.5",
            displayName: "GPT-5.5",
            provider: .openai,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 5.00,
            outputCostPer1M: 30.0,
            batchDiscount: 0.5
        ),
    ]

    // W41.app-openrouter, from the W41 OCR panel; figures re-read from the Phase 4 rule table by W43.app-guide-refresh
    // (`segbench-results/settings-routes.json`, reading rows: NES on the pages a route answered of the owner's 96). Each
    // model runs on ONE provider at ONE precision with fallbacks off (`OpenRouterRoute`), as the bench's
    // `ocr_panel.py` / `ocr_cloud.py` routes did, so the price here is that provider's and the figure is the
    // bench's. Prices are the pinned endpoint's, from the panel's frozen OpenRouter catalogs (2026-10-11/13).
    // Until W41.app-openrouter-any the first open route (the rule table's pick for an OpenRouter key with no fallback
    // for a failed page) was the provider's default; now the makers' routes lead, so it is Gemini 3.8 Flash's.
    /// At OpenRouter's listed price for each pinned upstream once read (W42.int-s2, `OpenRouterPrices`), else the bench's.
    /// W41.app-openrouter-any: the measured Gemini, GPT and (W41.app-openrouter-claude) Claude models come first, in their own providers' order, so the
    /// provider's default is the app's (Gemini 3.8 Flash) and one OpenRouter key reaches the recommended route.
    static var openrouterModels: [LLMModel] {
        (OpenRouterRoute.makerRoutes + OpenRouterRoute.openRoutes).map { OpenRouterPrices.priced($0) }
    }
}

// MARK: - OpenRouter routes

/// One OpenRouter model as the bench measured it: the provider it was pinned to, at the precision that provider
/// served, and whether reasoning was switched off. OpenRouter serves an open model through several providers at
/// bf16, fp8 or fp4; a call that let it choose would read with weights the bench never scored and bill at another
/// provider's price, so every request names the provider, its precision, `allow_fallbacks: false` and a
/// `max_price` of the pinned price (`OpenAICompatibleClient.openRouter`).
struct OpenRouterRoute: Sendable, Equatable {
    let model: LLMModel
    /// OpenRouter's endpoint tag (`deepinfra/fp8`), the value of `provider.order`.
    let providerTag: String
    /// The precision OpenRouter lists for that endpoint, sent as `provider.quantizations`.
    let precision: String
    /// OpenRouter's `reasoning` object as the bench sent it.
    let reasoning: Reasoning
    /// What the bench measured for it, shown under the Settings model picker.
    let measured: String
    /// W41.app-openrouter-any: the built-in model of another provider this route reaches (Gemini, OpenAI), on its
    /// maker's own endpoint, as the bench's `ocr_cloud.py` read it; nil for an open-weight model. A maker serves its
    /// own weights, so no precision is pinned (`quantizations` is not sent).
    var maker: LLMModel? = nil
    /// W41.app-openrouter-unmeasured: false for a model the bench never read (`unpinned(_:)`), which OpenRouter routes
    /// to whichever upstream it picks.
    var pinned = true

    enum Reasoning: Sendable, Equatable {
        /// Send no `reasoning` field (a non-reasoning instruct model).
        case none
        /// `{"enabled": false}`.
        case off
        /// `{"effort": <level>, "exclude": true}`.
        case effort(String)

        var body: [String: Any]? {
            switch self {
            case .none: return nil
            case .off: return ["enabled": false]
            case .effort(let level): return ["effort": level, "exclude": true]
            }
        }
    }

    /// Every pinned route: the open-weight models, then the makers' (W41.app-openrouter-any).
    static let catalog: [OpenRouterRoute] = openRoutes + makerRoutes

    static let openRoutes: [OpenRouterRoute] = [
        // Rule table 94.01 NES, all 95 answered, $1.22 per 1,000 pages (ocr_cloud.py `qwen3-vl-235b`). Non-reasoning
        // instruct. With no fallback for a failed page it ties Qwen3.6 27B (−0.37 strict, under the 0.49 floor) and
        // is cheaper, so it is the pick (04-reading.md §9, profile 2).
        OpenRouterRoute(
            model: LLMModel(id: "qwen/qwen3-vl-235b-a22b-instruct", displayName: "Qwen3-VL 235B (deepinfra fp8)",
                            provider: .openrouter, supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 0.20, outputCostPer1M: 0.88, batchDiscount: 1),
            providerTag: "deepinfra/fp8", precision: "fp8", reasoning: .none,
            measured: "Measured on the owner's 96 test pages: 94.01 NES, every page answered, $1.22 per 1,000 pages. "
                + "The pick when a failed page has no second reader."),
        // Rule table 95.38 NES on 94 of 95 (one transport error), $1.94 per 1,000 (ocr_panel.py `qwen3.6-27b`),
        // reasoning off as the panel ran it. The open-weight pick for handwriting (92.61 on the 16; 04-reading.md §9).
        OpenRouterRoute(
            model: LLMModel(id: "qwen/qwen3.6-27b", displayName: "Qwen3.6 27B (chutes fp8)",
                            provider: .openrouter, supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 0.25, outputCostPer1M: 2.00, batchDiscount: 1),
            providerTag: "chutes/fp8", precision: "fp8", reasoning: .off,
            measured: "Measured on the owner's 96 test pages: 95.38 NES on the pages it answered, $1.94 per 1,000 pages; "
                + "the best reader of handwriting in this list (92.61 on 16 pages)."),
        // The budget segmentation voter (`cheap-models.md`, method_openrouter.py `glm5.3-flash`); offered for OCR
        // too, unmeasured there. Price worked out from the seg-cheap call log (cost against tokens, 2026-10-13).
        OpenRouterRoute(
            model: LLMModel(id: "z-ai/glm-5.3-flash", displayName: "GLM-5.3 Flash (z-ai fp8)",
                            provider: .openrouter, supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 0.15, outputCostPer1M: 0.50, batchDiscount: 1),
            providerTag: "z-ai", precision: "fp8", reasoning: .effort("minimal"),
            measured: "Measured for segmentation only (the budget option); its OCR has not been measured."),
        // W43.app-guide-refresh. Rule table 95.11 NES on 92 of 95 (3 refusals), $0.60 per 1,000 (ocr_cloud_full.py
        // `qwen3.8-flash`, Alibaba's endpoint, which lists no precision, so the request pins "unknown" as listed).
        // With a second reader for failed pages it ties Qwen3.6 27B (−0.08) and is cheaper: that profile's pick.
        OpenRouterRoute(
            model: LLMModel(id: "qwen/qwen3.8-flash", displayName: "Qwen3.8 Flash (alibaba, precision unknown)",
                            provider: .openrouter, supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 0.15, outputCostPer1M: 0.47, batchDiscount: 1),
            providerTag: "alibaba", precision: "unknown", reasoning: .off,
            measured: "Measured on the owner's 96 test pages: 95.11 NES on the pages it answered, $0.60 per 1,000 pages; "
                + "it refused 3 pages, so give it a second reader for failed pages."),
        // W43.app-guide-refresh. Rule table 93.38 NES on 91 of 95 (4 at the token cap), $0.25 per 1,000 (ocr_panel.py
        // `qwen3.5-9b`), reasoning off: the pick under a price cap below $0.60 per 1,000 (04-reading.md §9).
        OpenRouterRoute(
            model: LLMModel(id: "qwen/qwen3.5-9b", displayName: "Qwen3.5 9B (deepinfra bf16)",
                            provider: .openrouter, supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 0.10, outputCostPer1M: 0.15, batchDiscount: 1),
            providerTag: "deepinfra/bf16", precision: "bf16", reasoning: .off,
            measured: "Measured on the owner's 96 test pages: 93.38 NES on the pages it answered, $0.25 per 1,000 pages, "
                + "the cheapest measured reader; 4 pages ran to the token cap."),
        // W47.wh-readers-lost-clients (owner call 15): the lower-scoring hosted rows, offered at Advanced only, never a
        // default or a pick. Each on the endpoint and precision the bench pinned (ocr_panel.py, ocr_cloud.py), priced
        // from its frozen catalog listing (ocr-panel-local and ocr-panel-cloud `catalog/`, 2026-10).
        OpenRouterRoute(
            model: LLMModel(id: "qwen/qwen3-vl-8b-instruct", displayName: "Qwen3-VL 8B (parasail bf16)",
                            provider: .openrouter, supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 0.25, outputCostPer1M: 0.75, batchDiscount: 1),
            providerTag: "parasail/bf16", precision: "bf16", reasoning: .none,
            measured: "Measured on the owner's 96 test pages: 93.85 NES on the pages it answered, $1.49 per 1,000 pages; "
                + "Qwen3.8 Flash reads them better for less."),
        OpenRouterRoute(
            model: LLMModel(id: "qwen/qwen3-vl-30b-a3b-instruct", displayName: "Qwen3-VL 30B-A3B (deepinfra fp8)",
                            provider: .openrouter, supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 0.15, outputCostPer1M: 0.60, batchDiscount: 1),
            providerTag: "deepinfra/fp8", precision: "fp8", reasoning: .none,
            measured: "Measured on the owner's 96 test pages: 91.79 NES on the pages it answered, $0.98 per 1,000 pages; "
                + "Qwen3.8 Flash reads them better for less."),
        OpenRouterRoute(
            model: LLMModel(id: "qwen/qwen3.5-35b-a3b", displayName: "Qwen3.5 35B-A3B (deepinfra fp8)",
                            provider: .openrouter, supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 0.14, outputCostPer1M: 1.00, batchDiscount: 1),
            providerTag: "deepinfra/fp8", precision: "fp8", reasoning: .off,
            measured: "Measured on the owner's 96 test pages: 92.82 NES on the pages it answered, $0.83 per 1,000 pages; "
                + "Qwen3.8 Flash reads them better for less."),
        // Mistral's own endpoint, which lists no precision; the bench sent none (a maker's route in ocr_cloud.py), and
        // pinning "unknown" as listed selects the same endpoint, as for Qwen3.8 Flash. Not a maker route: the app has
        // no Mistral chat model of its own for it to stand for (the Mistral key sends Mistral OCR only).
        OpenRouterRoute(
            model: LLMModel(id: "mistralai/mistral-medium-3-5", displayName: "Mistral Medium 3.5 (mistral, precision unknown)",
                            provider: .openrouter, supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 1.50, outputCostPer1M: 7.50, batchDiscount: 1),
            providerTag: "mistral", precision: "unknown", reasoning: .off,
            measured: "Measured on the owner's 96 test pages: 90.94 NES, every page answered, $7.29 per 1,000 pages; "
                + "Mistral Large 4 reads them better for less."),
    ]

    /// W41.app-openrouter-any — the measured models of another provider, through OpenRouter on their maker's own
    /// endpoint (`allow_fallbacks: false`), with the reasoning setting the bench sent (`ocr_cloud.py`,
    /// `method_openrouter.py`); the bench read every one of them this way, so its figures are these routes' own
    /// (owner, 2026-11-18: no parity check). The models' prices before OpenRouter's listing is read are
    /// the maker's plus a tenth, as OpenRouter listed Gemini 3.8 Flash on 2026-11-18 ($0.825/$4.125 against Google's
    /// $0.75/$3.75), so the ceiling is not under a listed price that was never read.
    ///
    /// W41.app-openrouter-claude: Claude Sonnet 5.5 too. 40d3ddee left Claude out as never read by the bench, which was
    /// wrong: the bench read the 96 with it through `claude -p` (the route table's reading row) and split the test boxes
    /// with it (the segmentation row `window-claude`), and both rows' figures are carried by this route (no parity
    /// check). The id is OpenRouter's listing's (`ocr_cloud.py`, and its frozen catalog `ocr-panel-cloud-prices.json`,
    /// 2026-10-14); the reasoning is what the bench sent on this endpoint, low, since it refuses reasoning off (the
    /// cloud pilot, `ocr-panel-cloud-pilot.md`). Its windows go through `OpenRouterClaudeWindowTransport`. Opus 5.5 and
    /// Haiku 4.5 are not here (`LLMModel.anthropicModels` says what they were measured on).
    static let makerRoutes: [OpenRouterRoute] = [
        maker("gemini-3.8-flash", as: "google/gemini-3.8-flash", on: "google-ai-studio", reasoning: .effort("low")),
        maker("gemini-3.5-flash-lite", as: "google/gemini-3.5-flash-lite", on: "google-ai-studio",
              reasoning: .effort("minimal")),
        maker("gemini-3.1-flash-lite", as: "google/gemini-3.1-flash-lite", on: "google-ai-studio",
              reasoning: .effort("minimal")),
        maker("gemini-3.5-flash", as: "google/gemini-3.5-flash", on: "google-ai-studio", reasoning: .effort("minimal")),
        maker("gemini-3.1-pro", as: "google/gemini-3.1-pro-preview", on: "google-ai-studio", reasoning: .effort("low")),
        maker("gpt-5.4-mini", as: "openai/gpt-5.4-mini", on: "openai", reasoning: .effort("minimal")),
        maker("claude-sonnet-5-5", as: "anthropic/claude-sonnet-5.5", on: "anthropic", reasoning: .effort("low")),
    ]

    /// A maker's endpoint tag in the user's words.
    static func upstreamName(_ tag: String) -> String {
        switch tag {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        default: return "Google AI Studio"
        }
    }

    private static func maker(_ id: String, as openRouterID: String, on tag: String, reasoning: Reasoning) -> OpenRouterRoute {
        let m = (LLMModel.geminiModels + LLMModel.openaiModels + LLMModel.anthropicModels).first { $0.id == id }!
        let upstream = upstreamName(tag)
        return OpenRouterRoute(
            model: LLMModel(id: openRouterID, displayName: "\(m.displayName) (\(upstream))", provider: .openrouter,
                            supportsThinking: m.supportsThinking, returnsMd: m.returnsMd,
                            inputCostPer1M: (m.inputCostPer1M * 1.1 * 1_000_000).rounded() / 1_000_000,
                            outputCostPer1M: (m.outputCostPer1M * 1.1 * 1_000_000).rounded() / 1_000_000,
                            batchDiscount: 1),
            providerTag: tag, precision: "", reasoning: reasoning, measured: "", maker: m)
    }

    /// The route that reaches `model` through OpenRouter: itself for an OpenRouter model, the maker's route for a
    /// measured Gemini, GPT or Claude model, else nil.
    static func through(_ model: LLMModel) -> OpenRouterRoute? {
        model.provider == .openrouter ? forModel(model.id)
            : makerRoutes.first { $0.maker?.id == model.id && $0.maker?.provider == model.provider }
    }

    /// The maker's route for a built-in model named by provider and id (a window voter's model), or nil.
    static func through(provider: LLMProvider, modelID: String) -> OpenRouterRoute? {
        makerRoutes.first { $0.maker?.provider == provider && $0.maker?.id == modelID }
    }

    /// The maker's route for a route-table `app_route` (`gemini|gemini-3.8-flash` → `openrouter|google/gemini-3.8-flash`).
    static func appRoute(throughOpenRouter appRoute: String) -> String? {
        makerRoutes.first { $0.makerAppRoute == appRoute }.map { "openrouter|" + $0.model.id }
    }

    /// The maker's own route-table `app_route` (`gemini|gemini-3.8-flash`), whose figures this route carries.
    var makerAppRoute: String? { maker.map { "\($0.provider.rawValue.lowercased())|\($0.id)" } }

    static func forModel(_ id: String) -> OpenRouterRoute? { catalog.first { $0.model.id == id } }

    /// W41.app-openrouter-unmeasured — the route a run of `model` takes: its pinned route with the ceiling at `model`'s
    /// price, or, for a model the listing offers (`OpenRouterListing.unmeasuredModels`) or the user typed, the unpinned
    /// route at that price; nil for any other id (a stale selection), which is never called.
    static func route(for model: LLMModel) -> OpenRouterRoute? {
        guard model.provider == .openrouter else { return nil }
        if let pin = forModel(model.id) { return pin.ceiling(model) }
        guard offered(model.id) else { return nil }
        return unpinned(model)
    }

    static let unavailableModelCode = "openrouter_model_unavailable"

    static func unavailableMessage(_ id: String) -> String {
        "OpenRouter model “\(id)” is no longer available in the model list. Choose another model in Settings › Reading."
    }

    static func unavailableSelection(_ id: String) -> String? {
        guard !id.isEmpty, forModel(id) == nil, !offered(id) else { return nil }
        return unavailableMessage(id)
    }

    /// Whether the app offers `id` unpinned: an eligible image model in OpenRouter's listing, or an id the user typed.
    static func offered(_ id: String) -> Bool {
        OpenRouterListing.entry(id)?.offeredInPicker == true
            || OpenRouterListing.typedModels().contains { $0.id == id }
    }

    /// A model the bench never read, through OpenRouter with no provider pinned: OpenRouter picks the upstream and may
    /// fall back to another, every request says `data_collection: "deny"`, and `max_price` is `model`'s price, the one
    /// its estimate showed, unless it is unpriced. No reasoning field is sent unless the user's thinking level asks.
    static func unpinned(_ model: LLMModel) -> OpenRouterRoute {
        OpenRouterRoute(model: model, providerTag: "", precision: "", reasoning: .none, measured: "", pinned: false)
    }

    /// An unpinned model the app cannot estimate: no estimate and no `max_price`.
    /// A priced model at $0 (a free one) is priced. Read from the model,
    /// never the live listing, so the request's ceiling is what the run's estimate said.
    static func isUnpriced(_ model: LLMModel) -> Bool {
        model.provider == .openrouter && model.unpriced == true && forModel(model.id) == nil
    }

    static let unpricedEstimateMessage = "Price not estimated. OpenRouter may charge for this model without a price ceiling."

    /// Under the Settings model picker for an unpinned model.
    static func unmeasuredNote(_ model: LLMModel) -> String {
        let terms = "OpenRouter chooses which provider serves it and may fall back to another, so neither the precision "
            + "nor whose terms apply is known; every request asks OpenRouter not to use a provider that may keep or "
            + "train on the pages."
        if isUnpriced(model) {
            return "Not measured: the bench has never read pages with this model. " + unpricedEstimateMessage + " " + terms
        }
        let reasoning = model.supportsThinking
            ? " Its reasoning tokens are billed as output; the estimate allows \(Int(CostEstimator.estimatedThinkingTokens(for: model))) a page." : ""
        return "Not measured: the bench has never read pages with this model. At $\(price(model.inputCostPer1M)) in, "
            + "$\(price(model.outputCostPer1M)) out per million tokens (OpenRouter's listing), with no batch discount; "
            + "a provider that would charge more per token is not used." + reasoning + " " + terms
    }

    /// This route with its price ceiling at `model`'s prices: the run's model, priced when its estimate was made
    /// (OpenRouter's listing once read, W42.int-s2, else the bench's), so `max_price` is the price the user saw, even
    /// if the listing is read again during the run. Everything else stays the catalog's.
    func ceiling(_ model: LLMModel) -> OpenRouterRoute {
        guard model.id == self.model.id else { return self }
        let m = self.model
        return OpenRouterRoute(
            model: LLMModel(id: m.id, displayName: m.displayName, provider: m.provider, supportsThinking: m.supportsThinking,
                            returnsMd: m.returnsMd, inputCostPer1M: model.inputCostPer1M,
                            outputCostPer1M: model.outputCostPer1M, batchDiscount: m.batchDiscount),
            providerTag: providerTag, precision: precision, reasoning: reasoning, measured: measured, maker: maker,
            pinned: pinned)
    }

    /// This route sending `reasoning` instead (a maker's model at the user's thinking level, W41.app-openrouter-any).
    func with(reasoning: Reasoning) -> OpenRouterRoute {
        OpenRouterRoute(model: model, providerTag: providerTag, precision: precision, reasoning: reasoning,
                        measured: measured, maker: maker, pinned: pinned)
    }

    /// Under the Settings model picker: where the model runs, so the user knows the price and the precision.
    var settingsNote: String {
        if let maker {
            let priced = OpenRouterPrices.priced(self)
            let upstream = Self.upstreamName(providerTag)
            let row = SettingsRouteTable.bundled?.stage("reading")?.routes.first { $0.appRoute == makerAppRoute }
            let figure = row?.figure("overall").map { value -> String in
                // Claude Sonnet 5.5's figure is its plan route's, read through `claude -p` (W41.app-openrouter-claude).
                let how = maker.provider == .anthropic ? "read through the Claude plan" : "read this way"
                // The geminiModels and anthropicModels comments: a drafter or its relative, so say so wherever it shows.
                let caveat = maker.id == "gemini-3.8-flash"
                    ? ", though it drafted part of their truth, so its lead may be partly flattery. "
                    : maker.provider == .anthropic
                        ? ", though Claude Opus 5.5, of the same family, drafted part of their truth, so its lead may be partly flattery. "
                        : ". "
                return "Measured on the owner's 96 test pages, \(how): \(String(format: "%.2f", value)) NES on the pages it answered" + caveat
            } ?? ""
            return "\(maker.displayName) through OpenRouter. " + figure
                + "Runs on \(upstream) only, with OpenRouter's fallbacks off, at $\(Self.price(priced.inputCostPer1M)) in, "
                + "$\(Self.price(priced.outputCostPer1M)) out per million tokens (\(OpenRouterPrices.source(self))), "
                + "with no batch discount: OpenRouter has no batch here. If \(upstream) is down the page fails rather "
                + "than going elsewhere."
        }
        let provider = providerTag.split(separator: "/").first.map(String.init) ?? providerTag
        let at = precision == "unknown" ? "at the precision it serves (it lists none)" : "at \(precision)"
        let priced = OpenRouterPrices.priced(self)
        return measured + " Runs on \(provider) only, \(at), with OpenRouter's fallbacks off: the provider the bench "
            + "measured, at $\(Self.price(priced.inputCostPer1M)) in, $\(Self.price(priced.outputCostPer1M)) out "
            + "per million tokens (\(OpenRouterPrices.source(self))). If that provider is down the page fails rather "
            + "than going elsewhere."
    }

    private static func price(_ v: Double) -> String { String(format: "%.2f", v) }
}

extension LLMModel {
    /// W41.app-openrouter-any: the built-in model this one stands for, for everything keyed on the model the bench
    /// measured (image tokens, thinking tokens, Gemini's refusals and their second reader, the page guidance): the
    /// maker's model for a maker's route through OpenRouter, else the model itself.
    var measuredModel: LLMModel {
        provider == .openrouter ? (OpenRouterRoute.forModel(id)?.maker ?? self) : self
    }
}

// MARK: - OCR Job

struct OCRJob: Identifiable {
    let id = UUID()
    let sourceURL: URL
    var status: JobStatus = .pending
    var result: OCRResult?
    var classification: DocumentClassification?
    var appliedTags: [String] = []
    /// Rebuilt multi-page PDFs report layer notes by source page in the run log.
    var pdfLayerLogNotes: [String]?

    enum JobStatus {
        case pending, processing, succeeded, failed, removed
    }
}

struct OCRResult: Codable {
    private(set) var text: String?
    let classification: DocumentClassification?
    /// Clockwise rotation in degrees needed to correct image orientation (0, 90, 180, 270).
    let rotationDegrees: Int
    let errorMessage: String?
    let errorCode: String?
    /// W37.dual-date — the OCR model's optional `[enclosure]` marker on a `[document_start]` page: "this
    /// page begins a separate, independently dated/headed document that was sent WITH the covering
    /// letter on the preceding pages". A PROPOSAL only; `DocumentSegmenter` turns it into a segment
    /// relation, and the owner can clear it in review. `nil`/`false` = no relation proposed. Optional so
    /// the synthesized Codable decodes a persisted result written before this field existed.
    let enclosure: Bool?
    /// W37.dual-date — the classification the OCR model itself returned, kept through every review
    /// reclassification (`with`). It is the frame the model's `[enclosure]` judgement was made in:
    /// `DocumentSegmenter.coverPageSequences` over these is the proposal BASELINE, and a rebuilt
    /// segmentation keeps a relation only while its cover pages are still exactly that baseline's.
    /// `nil` on a legacy persisted result (which carries no proposal either).
    let ocrClassification: DocumentClassification?
    /// W37.dual-date — the model's ORIGINAL `[enclosure]` marker, kept through reclassification like
    /// `ocrClassification` (which clears `enclosure`). The baseline must be built from the model's frame
    /// whole: with a reclassified enclosure's flag missing, its page would read as a new letter and move
    /// the recorded cover of every later enclosure that shares the same letter.
    let ocrEnclosure: Bool?
    /// W41.app-ocr-default — set when Gemini refused the page and a second route read it
    /// (`OCRRefusalFallback`). `nil` = read by the run's own model.
    let secondReader: SecondReader?
    /// W41.app-page-kind — the page's kind and the reader its kind chose (`PageReaderPlan`). `nil` = the page was
    /// not classified; set by `performOCRCall` on every page the run's plan names, routed or not.
    var pageReader: PageReaderRecord?
    /// W41.app-institutional-compute — set when the text came in from an institutional-computing bulk run instead of the run's model
    /// (`InstitutionalComputeImport`). `nil` = read in this run.
    let imported: ImportedReading?
    /// W40.fix-processor-failed-ocr-wrapped — on a page no reader could read (`OCRRefusalFallback.exhaustedCode`,
    /// `OCRCascade.exhaustedCode`), the code of every reading the failure folds in: the first reader's, then each
    /// second reader's or the escalation's, "" for one that threw, had no key or was stopped. It is what tells a
    /// page that was never read (a Gemini 500 then a 402 on the only second reader) from a real refusal
    /// (`OCRFailureCode.requestFailed`). `nil` on every other result.
    let readingCodes: [String]?
    /// Gemini returned a server error and neither the cascade nor the refusal fallback had a second reader.
    var noSecondReaderAvailable: Bool? = nil
    /// W46.rotation-default — the agreement rule left this page as it is: Vision and PP-LCNet disagreed, or Vision
    /// found no text, and no cloud route was set. `nil` = rotation was settled (or not checked).
    var rotationUnsure: Bool? = nil
    /// The fixed newspaper layout stage, including a visible whole-page fallback reason.
    var newspaperLayout: NewspaperLayoutRecord? = nil
    /// W46.post-read-quality-flag — this page probably read poorly (`ReadQualityFlag`): Apple Vision read it with low
    /// confidence, or (W47.wh-read-flag-readers) another reader's text disagreed with Vision's past that reader's cut,
    /// set after OCR and batch collection (`ReadQualityDisagreement`). Carried by the rebuilds that keep the text and feed the run
    /// summary (not Live Capture's group rotation, the newspaper region join or re-OCR pairs, which show none).
    /// `nil` = not flagged, or read by a route with no measured cut.
    var readPoorly: ReadQualityFlag?
    /// The image corrector changed this text. The first reader still owns classification and rotation.
    private(set) var imageCorrectionApplied: Bool?

    init(text: String?, classification: DocumentClassification?, rotationDegrees: Int = 0, errorMessage: String?, errorCode: String?,
         enclosure: Bool? = nil, ocrClassification: DocumentClassification?? = nil, ocrEnclosure: Bool?? = nil,
         secondReader: SecondReader? = nil, pageReader: PageReaderRecord? = nil, imported: ImportedReading? = nil,
         readingCodes: [String]? = nil, newspaperLayout: NewspaperLayoutRecord? = nil, readPoorly: ReadQualityFlag? = nil,
         imageCorrectionApplied: Bool? = nil) {
        self.imageCorrectionApplied = imageCorrectionApplied
        self.readPoorly = text == nil ? nil : readPoorly
        self.readingCodes = readingCodes
        self.newspaperLayout = newspaperLayout
        self.secondReader = secondReader
        self.pageReader = pageReader
        self.imported = imported
        self.text = text
        self.classification = classification
        self.rotationDegrees = rotationDegrees
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        // Only a document START can begin an enclosure; anything else carries no proposal.
        self.enclosure = (classification == .documentStart && enclosure == true) ? true : nil
        // A fresh result's model classification IS its classification; a rebuild passes the original.
        self.ocrClassification = ocrClassification ?? classification
        self.ocrEnclosure = ocrEnclosure ?? self.enclosure
    }

    func withImageCorrection(_ text: String) -> OCRResult {
        guard text != self.text else { return self }
        var copy = self
        copy.text = text
        copy.imageCorrectionApplied = true
        return copy
    }

    /// A reply cut off at the token limit (W41.app-ocr-cascade): every client fails the page with this, never the
    /// cut text. Not auto-retried (the same budget would cut it again); the cascade escalates it.
    static let cutOff = OCRResult(text: nil, classification: nil, errorMessage: "The reply was cut off at the token limit",
                                  errorCode: OCRFailureCode.cutOff)

    /// A copy of this result with a new classification and/or rotation, **preserving** `text`,
    /// `errorMessage`, and `errorCode`. The review / retry / rotation flows re-derive only the
    /// classification or the rotation; routing them through one initializer stops each from re-typing
    /// all five fields — which is how `errorCode` got silently dropped before (W9.1). (Sites that
    /// intentionally *reset* `errorCode` to nil on a fresh success rebuild keep their explicit init and
    /// deliberately don't use this.)
    ///
    /// W37: the enclosure proposal survives ONLY an unchanged classification (a rotation-only fix). A
    /// reclassified page is a changed boundary, and a relation is never carried across one.
    func with(classification: DocumentClassification?, rotationDegrees: Int) -> OCRResult {
        var copy = OCRResult(text: text, classification: classification, rotationDegrees: rotationDegrees,
                  errorMessage: errorMessage, errorCode: errorCode,
                  enclosure: classification == self.classification ? enclosure : nil,
                  ocrClassification: .some(ocrClassification), ocrEnclosure: .some(ocrEnclosure),
                  secondReader: secondReader, pageReader: pageReader, imported: imported, readingCodes: readingCodes,
                  readPoorly: readPoorly, imageCorrectionApplied: imageCorrectionApplied)
        copy.noSecondReaderAvailable = noSecondReaderAvailable
        copy.rotationUnsure = rotationUnsure
        copy.newspaperLayout = newspaperLayout
        return copy
    }
}

/// W41.app-ocr-default — who read a page the run's own model did not, and why: a page Gemini refused
/// (`OCRRefusalFallback`), or one the cascade escalated (W41.app-ocr-cascade, `OCRCascade`). `provider`/`model` fill
/// the PDF page-2 header's provenance positions in place of the run's model, so the header names the model that
/// wrote the text without changing the header's shape (`SPEC/tag-format.md`).
struct SecondReader: Codable, Equatable {
    /// Why the run's own reading was not kept.
    enum Trigger: String, Codable {
        /// Gemini refused the page (a finish or block reason, or its bare 500).
        case refusal
        /// The first reader failed: cut off at the token limit, an unparsable reply, a server error.
        case failure
        /// The first reader's word count and Apple Vision's disagreed (`OCRCascade.disagreementRatio`).
        case disagreement
    }

    let provider: String
    let model: String
    /// The first reader's failure code (`Recitation`, `OTHER`, `500`, `length`, …), or for a disagreement the
    /// two word counts.
    let firstCode: String
    /// USD, `CostEstimator.secondReaderPageCost` for the route that read the page (0 for claude by plan).
    var estimatedCost: Double? = nil
    /// nil on a refusal second read (`OCRRefusalFallback`), which predates the cascade and is always Gemini's.
    var trigger: Trigger? = nil
    /// The first reader, `"<provider> · <model>"`; nil = the run's Gemini model (a refusal second read).
    var firstReader: String? = nil
    /// The API model ID for selecting a measured read-quality rule. Local agents have no measured route.
    var modelID: String? = nil

    var summary: String {
        let first = firstReader ?? "Gemini"
        switch trigger ?? .refusal {
        case .refusal: return "\(provider) · \(model), after \(first) returned no text (\(firstCode))"
        case .failure: return "\(provider) · \(model), after \(first) failed (\(firstCode))"
        case .disagreement: return "\(provider) · \(model), after \(first)'s reading disagreed with Apple Vision's (\(firstCode))"
        }
    }
}

// MARK: - Live Processing Mode

/// The two Live Capture processing modes (Settings `liveProcessingMode`). `rawValue` is the string
/// persisted in UserDefaults — NEVER change "stage"/"live" without a migration. Single source of truth
/// replacing the "stage"/"live" magic strings scattered across the views + stores.
enum LiveProcessingMode: String {
    case stage
    case live
}

// MARK: - Gateway Config

struct GatewayConfig: Codable, Equatable {
    var baseURL: String
    var modelID: String
    var displayName: String
    var inputCostPer1M: Double?
    var outputCostPer1M: Double?
    /// W41.app-local-models: the endpoint is an open-weight model on this Mac (`LocalModelRoute`). nil (the
    /// field absent) is a remote gateway.
    var localModel: Bool? = nil
    /// A local model's failed page may go to the cloud escalation model (`OCRCascade`). Off unless the user says so:
    /// someone who chose a local model may have chosen it to keep the pages on this Mac.
    var localEscalates: Bool? = nil

    var isLocalModel: Bool { localModel == true }

    /// The base URL the field wants (`https://…/v1`), from what the user typed or pasted. A pasted full endpoint
    /// (`…/v1/chat/completions`) had the path appended a second time and every call answered 404 (owner session
    /// iphone-1, W40.fix-processor-gateway-url-doubled), so a trailing `/chat/completions`, trailing slashes and
    /// surrounding whitespace are dropped. Applied when the field is submitted and on every read.
    static func normalizedBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func dropSlashes() { while s.hasSuffix("/") { s.removeLast() } }
        dropSlashes()
        let suffix = "/chat/completions"
        if s.lowercased().hasSuffix(suffix) { s.removeLast(suffix.count) }
        dropSlashes()
        return s
    }

    var apiKey: String {
#if DEBUG
        if !isLocalModel, let key = Self.testKeyOverride { return key }
#endif
        return Self.storedKey(localModel: isLocalModel)
    }

#if DEBUG
    /// W40.d1: the key a headless `ProcessFilesTestDriver` run hands the gateway, since a headless launch never opens
    /// the Keychain (`KeychainHelper.isHeadlessTestMode`). Set by that driver for its run only, and cleared after.
    nonisolated(unsafe) static var testKeyOverride: String?
#endif

    /// The gateway key from the Keychain. A local model always gets the placeholder: a saved key belongs to a remote
    /// gateway, and is never sent in plain http to whatever listens on this Mac's port.
    static func storedKey(localModel: Bool) -> String {
#if DEBUG
        // The offscreen UI journey uses only this public dummy key; never reads the owner's Keychain.
        if !localModel, ProcessorUITestConfiguration.usesStandInGateway { return "s044-stand-in" }
#endif
        return localModel ? LocalModelRoute.placeholderKey : (KeychainHelper.load(account: "Gateway") ?? "")
    }

    static func storedKey(_ d: UserDefaults = .standard) -> String {
        storedKey(localModel: d.bool(forKey: DefaultsKeys.gatewayLocalModel))
    }

    func asLLMModel() -> LLMModel {
        LLMModel(
            id: modelID,
            displayName: modelID,
            provider: .anthropic,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: inputCostPer1M ?? 0,
            outputCostPer1M: outputCostPer1M ?? 0,
            batchDiscount: 0
        )
    }

    /// Build the gateway config from the shared app settings, or nil when the gateway is disabled or not
    /// fully configured. Single source of truth for the OCRView / ToolsView `currentGatewayConfig` and
    /// `SessionProcessingConfig.fromDefaults`, which previously each rebuilt this identically (the view
    /// `@AppStorage` keys + defaults match these UserDefaults reads exactly, so the result is unchanged).
    static func fromDefaults(_ d: UserDefaults = .standard) -> GatewayConfig? {
        guard d.bool(forKey: DefaultsKeys.useGateway) else { return nil }
        let baseURL = normalizedBaseURL(d.string(forKey: DefaultsKeys.gatewayBaseURL) ?? "")
        let modelID = d.string(forKey: DefaultsKeys.gatewayModelID) ?? ""
        guard !baseURL.isEmpty, !modelID.isEmpty else { return nil }
        let inCost = d.object(forKey: DefaultsKeys.gatewayInputCost) as? Double ?? -1
        let outCost = d.object(forKey: DefaultsKeys.gatewayOutputCost) as? Double ?? -1
        let name = d.string(forKey: DefaultsKeys.gatewayDisplayName) ?? ""
        return GatewayConfig(baseURL: baseURL, modelID: modelID,
                             displayName: name.isEmpty ? "API Gateway" : name,
                             inputCostPer1M: inCost >= 0 ? inCost : nil,
                             outputCostPer1M: outCost >= 0 ? outCost : nil,
                             localModel: d.bool(forKey: DefaultsKeys.gatewayLocalModel) ? true : nil,
                             localEscalates: d.bool(forKey: DefaultsKeys.gatewayLocalModel)
                                && d.bool(forKey: DefaultsKeys.gatewayLocalEscalates) ? true : nil)
    }
}

// MARK: - Custom Model Store

final class CustomModelStore: ObservableObject, @unchecked Sendable {
    static let shared = CustomModelStore()

    private static let storageKey = "customModels"

    @Published private(set) var allCustomModels: [LLMModel] = []

    private init() {
        allCustomModels = Self.load()
    }

    func models(for provider: LLMProvider) -> [LLMModel] {
        allCustomModels.filter { $0.provider == provider }
    }

    func add(_ model: LLMModel) {
        allCustomModels.append(model)
        save()
    }

    @MainActor func removeById(_ id: String) {
        allCustomModels.removeAll { $0.id == id }
        save()
        // A provider still pointing at the deleted id would read as its fallback while the dead id stayed
        // on disk — and would spring back to life if that id were ever re-added, silently selecting a
        // model (and a price) the user had thrown away. Heal the stored selection now.
        ModelSelectionStore.shared.healUnresolvableSelections(afterRemoving: id)
    }

    func isCustom(_ model: LLMModel) -> Bool {
        allCustomModels.contains { $0.id == model.id && $0.provider == model.provider }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(allCustomModels) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func load() -> [LLMModel] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let models = try? JSONDecoder().decode([LLMModel].self, from: data) else { return [] }
        return models
    }
}

// MARK: - Segmentation Context

struct SegmentationContext {
    /// Characters of previous page's OCR text to include as context
    var previousTextCharCount: Int = 200
    /// Whether to send the full previous page image for higher accuracy
    var sendPreviousImage: Bool = false
    /// Optional custom prompt appended to OCR instructions
    var customPrompt: String? = nil
    /// Image resolution scale factor (0.2–1.0). 1.0 = full resolution.
    var imageScale: Double = 1.0
}
