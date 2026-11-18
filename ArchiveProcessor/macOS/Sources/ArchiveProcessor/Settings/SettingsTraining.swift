import Foundation

// MARK: - Whether a route's provider may train on the pages (W46.training-optout)

/// What each way of sending pages off this Mac lets the provider do with them, from its own terms, read 2026-11-17
/// (the record with its sources: `execution-plans/processing-review/13-stage-rules/15-training-terms.md`). The
/// collection's `noTraining` switch hides every route that is not `.never` for the ways this user would send it,
/// so a free tier, a consumer plan and an OpenRouter upstream that trains are all hidden; the sheet says what that
/// costs on each card.
enum SettingsTraining {
    enum Terms: Equatable, Sendable {
        /// The terms say uploads are not used to train models.
        case never
        /// Free use trains on uploads; paid use does not, and the app cannot tell which this account is.
        case unlessPaid
        /// A personal plan trains on uploads unless the account's own setting is switched off.
        case unlessOptedOut
        /// The provider may train on uploads.
        case mayTrain
        /// No terms on record for this way (an OpenRouter model the app does not pin to one provider).
        case unknown
    }

    struct Record: Equatable, Sendable {
        let provider: String
        let terms: Terms
        /// One sentence, in the sheet's words.
        let summary: String
        let source: String
    }

    static let checked = "2026-11-17"

    /// The API keys, by the route table's key name.
    static let keys: [String: Record] = [
        "gateway": Record(provider: "the Stanford AI API Gateway", terms: .never,
                          summary: "Stanford's agreements with its vendors rule out training on what is sent through the gateway",
                          source: "https://uit.stanford.edu/service/ai-api-gateway/faqs"),
        "anthropic": Record(provider: "Anthropic's API", terms: .never,
                            summary: "Anthropic does not train on API traffic (its commercial terms)",
                            source: "https://www.anthropic.com/news/updates-to-our-consumer-terms"),
        "openai": Record(provider: "OpenAI's API", terms: .never,
                         summary: "OpenAI does not train on API traffic by default; only an account that joins its data-sharing programme is trained on",
                         source: "https://help.openai.com/en/articles/5722486-how-your-data-is-used-to-improve-model-performance"),
        "gemini": Record(provider: "a Gemini API key", terms: .unlessPaid,
                         summary: "Google trains on what a Gemini key's free tier is sent; a key on a billed project is not used for training",
                         source: "https://ai.google.dev/gemini-api/terms"),
        "mistral": Record(provider: "a Mistral API key", terms: .unlessPaid,
                          summary: "Mistral trains on its free tier's API traffic unless the account opts out; paid use is opted out",
                          source: "https://help.mistral.ai/en/articles/455207-can-i-opt-out-of-my-input-or-output-data-being-used-for-training"),
    ]

    /// The signed-in subscription plans, by the route table's plan name.
    static let plans: [String: Record] = [
        "claude": Record(provider: "a Claude plan", terms: .unlessOptedOut,
                         summary: "Anthropic trains on Free, Pro and Max sessions when the account's “Help improve Claude” setting is on",
                         source: "https://www.anthropic.com/news/updates-to-our-consumer-terms"),
        "chatgpt": Record(provider: "a ChatGPT plan", terms: .unlessOptedOut,
                          summary: "OpenAI trains on Free, Plus and Pro use unless “Improve the model for everyone” is switched off",
                          source: "https://help.openai.com/en/articles/7730893-data-controls-in-chatgpt"),
    ]

    /// OpenRouter's upstream providers, by the first part of the endpoint tag the app pins (`OpenRouterRoute`).
    /// OpenRouter itself keeps no prompts and trains on none; the terms are the upstream's.
    static let upstreams: [String: Record] = [
        "deepinfra": Record(provider: "DeepInfra, through OpenRouter", terms: .never,
                            summary: "DeepInfra keeps nothing it is sent and does not train on it",
                            source: "https://deepinfra.com/docs/data"),
        "alibaba": Record(provider: "Alibaba Cloud, through OpenRouter", terms: .never,
                          summary: "Alibaba Cloud Model Studio does not use customer data for training",
                          source: "https://www.alibabacloud.com/help/en/model-studio/privacy-notice"),
        "z-ai": Record(provider: "Z.ai, through OpenRouter", terms: .never,
                       summary: "Z.ai's API terms process requests in real time and keep nothing",
                       source: "https://docs.z.ai/legal-agreement/privacy-policy"),
        "chutes": Record(provider: "Chutes, through OpenRouter", terms: .mayTrain,
                         summary: "OpenRouter serves Chutes only to accounts that allow providers to train on prompts",
                         source: "https://x.com/OpenRouterAI/status/1889732807481561112"),
    ]

    /// A closed model reached through OpenRouter runs on its maker's paid API, so the maker's API terms hold.
    static let makersThroughOpenRouter: [String: Record] = [
        "gemini": Record(provider: "Google, through OpenRouter", terms: .never,
                         summary: "OpenRouter pays for Google's API, whose paid terms rule out training",
                         source: "https://ai.google.dev/gemini-api/terms"),
        "openai": Record(provider: "OpenAI, through OpenRouter", terms: .never,
                         summary: "OpenRouter reaches OpenAI's API, which does not train on API traffic",
                         source: "https://help.openai.com/en/articles/5722486-how-your-data-is-used-to-improve-model-performance"),
    ]
    // Not Mistral: its models are open-weight, so OpenRouter may serve them from third parties; an unpinned Mistral
    // row through OpenRouter is `unpinned`.

    static let unpinned = Record(provider: "OpenRouter, with no provider pinned", terms: .unknown,
                                 summary: "the app does not pin this model to one provider, so whose terms apply is not known",
                                 source: "https://openrouter.ai/docs/guides/privacy/provider-logging")

    /// The terms for a route reached through OpenRouter.
    static func openRouter(_ r: SettingsRouteTable.Route, appRoute: String?) -> Record {
        if let maker = r.needs.key.first(where: { makersThroughOpenRouter[$0] != nil }) { return makersThroughOpenRouter[maker]! }
        guard let ar = appRoute, ar.hasPrefix("openrouter|"),
              let pin = OpenRouterRoute.catalog.first(where: { "openrouter|" + $0.model.id == ar }) else { return unpinned }
        let upstream = pin.providerTag.split(separator: "/").first.map(String.init) ?? pin.providerTag
        return upstreams[upstream] ?? unpinned
    }

    /// The first way this user would send the route's pages whose terms are not `.never`; nil when every way is safe.
    /// The ways counted are the ones the user has (a key, a plan); a route the user cannot reach counts every way it
    /// names, so the sheet can still say what it would mean. A route on this Mac, done by hand or on the user's
    /// cluster sends nothing to a provider. A cascade is as safe as its least safe reader.
    /// `lookup` finds a cascade's readers among the reading rows. A row's OpenRouter pin is its own `app_route` only:
    /// a row of another stage that shares a reading row's id is not pinned by it.
    static func risk(_ r: SettingsRouteTable.Route, resources: SettingsResources,
                     lookup: (String) -> SettingsRouteTable.Route?, depth: Int = 0) -> Record? {
        // A cascade sends pages only through its readers; its own row names no provider of its own.
        if let stages = r.stages, depth == 0 {
            for id in stages {
                guard let row = lookup(id) else { return unpinned }
                if let bad = risk(row, resources: resources, lookup: lookup, depth: 1) { return bad }
            }
            return nil
        }
        let n = r.needs
        let haveKeys = n.key.filter { resources.keys.contains($0) }
        let havePlan = !n.plan.isEmpty && Set(n.plan).isSubset(of: resources.plans)
        let reachable = !haveKeys.isEmpty || havePlan || (n.cluster && resources.cluster)
        // Only the cluster: the user's own institution's machines.
        if n.cluster && resources.cluster && haveKeys.isEmpty && !havePlan { return nil }
        let ways = reachable ? haveKeys : n.key
        let planWays = reachable ? (havePlan ? n.plan : []) : n.plan
        let appRoute = r.appRoute
        for k in ways {
            let rec = k == "openrouter" ? openRouter(r, appRoute: appRoute)
                : Self.keys[k] ?? Record(provider: k, terms: .unknown, summary: "no terms are on record for this key", source: "")
            if rec.terms != .never { return rec }
        }
        for p in planWays {
            let rec = Self.plans[p] ?? Record(provider: p, terms: .unknown, summary: "no terms are on record for this plan", source: "")
            if rec.terms != .never { return rec }
        }
        return nil
    }

    /// The solver's blocker: one fixed prefix the sheet recognises, then the provider's own sentence.
    static let blockerPrefix = "may train on the pages: "
    static func blocker(_ rec: Record) -> String { blockerPrefix + rec.provider + " — " + rec.summary }
}
