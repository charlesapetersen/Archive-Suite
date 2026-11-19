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
        "custom-gateway": Record(provider: "a gateway other than Stanford's", terms: .unknown,
                                 summary: "the app has no terms on record for this gateway, so whether it trains is not known",
                                 source: ""),
        "gemini": Record(provider: "a Gemini API key", terms: .unlessPaid,
                         summary: "Google trains on what a Gemini key's free tier is sent; a key on a billed project is not used for training",
                         source: "https://ai.google.dev/gemini-api/terms"),
        "mistral": Record(provider: "a Mistral API key", terms: .unlessPaid,
                          summary: "Mistral trains on its free tier's API traffic unless the account opts out; paid use is opted out",
                          source: "https://help.mistral.ai/en/articles/455207-can-i-opt-out-of-my-input-or-output-data-being-used-for-training"),
    ]

    /// The signed-in subscription plans, by the route table's plan name (and the Gemini CLI, which the table lacks).
    static let plans: [String: Record] = [
        "gemini-cli": Record(provider: "the Gemini CLI", terms: .mayTrain,
                             summary: "the Gemini CLI signs in with a Google account, whose free use Google may train on",
                             source: "https://developers.google.com/gemini-code-assist/resources/privacy-notice-gemini-code-assist-individuals"),
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
        // W41.app-openrouter-any: a maker's own endpoint (`OpenRouterRoute.makerRoutes`) holds the maker's API terms.
        "google-ai-studio": makersThroughOpenRouter["gemini"]!,
        "openai": makersThroughOpenRouter["openai"]!,
        "anthropic": makersThroughOpenRouter["anthropic"]!,   // W41.app-openrouter-claude
    ]

    /// A closed model reached through OpenRouter runs on its maker's paid API, so the maker's API terms hold.
    static let makersThroughOpenRouter: [String: Record] = [
        "gemini": Record(provider: "Google, through OpenRouter", terms: .never,
                         summary: "OpenRouter pays for Google's API, whose paid terms rule out training",
                         source: "https://ai.google.dev/gemini-api/terms"),
        "openai": Record(provider: "OpenAI, through OpenRouter", terms: .never,
                         summary: "OpenRouter reaches OpenAI's API, which does not train on API traffic",
                         source: "https://help.openai.com/en/articles/5722486-how-your-data-is-used-to-improve-model-performance"),
        "anthropic": Record(provider: "Anthropic, through OpenRouter", terms: .never,
                            summary: "OpenRouter reaches Anthropic's API, which does not train on API traffic (its commercial terms)",
                            source: "https://www.anthropic.com/news/updates-to-our-consumer-terms"),
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
            if !safe(rec, way: keyWay(k), resources: resources) { return rec }
        }
        for p in planWays {
            let rec = Self.plans[p] ?? Record(provider: p, terms: .unknown, summary: "no terms are on record for this plan", source: "")
            if !safe(rec, way: planWay(p), resources: resources) { return rec }
        }
        return nil
    }

    // MARK: The user's own answer per key and plan (W46.training-optout-run)

    /// The general interview's names for a way in, as `SettingsResources.trainingOff` holds them: `key:gemini`,
    /// `plan:claude`. Prefixed, so a key and a plan never share a name.
    static func keyWay(_ key: String) -> String { "key:" + key }
    static func planWay(_ plan: String) -> String { "plan:" + plan }

    /// A way's terms with the user's answer: a key the user says is billed, or a plan whose training setting the
    /// user says is off, is safe. Only terms that depend on the account can be answered; a provider that may train
    /// whatever the account (`.mayTrain`) or whose terms are unknown stays hidden.
    static func safe(_ rec: Record, way: String, resources: SettingsResources) -> Bool {
        switch rec.terms {
        case .never: return true
        case .unlessPaid, .unlessOptedOut: return resources.trainingOff.contains(way)
        case .mayTrain, .unknown: return false
        }
    }

    /// The ways the general interview asks about: the keys and plans whose terms depend on the account, with the
    /// question in the interview's words.
    static let answerableWays: [(way: String, question: String)] = [
        (keyWay("gemini"), "My Gemini key is on a billed Google Cloud project"),
        (keyWay("mistral"), "My Mistral key is on a paid plan, or its training setting is off"),
        (planWay("claude"), "My Claude plan's “Help improve Claude” setting is off"),
        (planWay("chatgpt"), "My ChatGPT plan's “Improve the model for everyone” setting is off"),
    ]

    /// The answers in the Settings window's words; ArchiveCore's `CollectionSettingsVocabulary.trainingOffWords` is
    /// the same table, checked by the settings-layers test driver.
    static let wayWords: [String: String] = [
        "key:gemini": "the Gemini key (billed)", "key:mistral": "the Mistral key (paid or opted out)",
        "plan:claude": "the Claude plan (training off)", "plan:chatgpt": "the ChatGPT plan (training off)",
    ]

    // MARK: The run (W46.training-optout-run)

    /// One way a run sends pages off this Mac, in the solver's names.
    enum RunWay: Equatable, Sendable {
        case key(String)
        case plan(String)
        /// An OpenRouter model, by its id; its pinned upstream's terms hold.
        case openRouter(modelID: String)
        /// Nothing leaves the Mac, or it goes through a way whose terms rule training out (the gateway).
        case safe
    }

    /// What Process Files says before it runs a way the switch hides, or nil when every way is safe. `ways` are the
    /// run's readers and segmenter, each with what it does in the run ("reads the pages").
    static func runWarning(_ ways: [(RunWay, String)], resources: SettingsResources) -> String? {
        var lines: [String] = []
        var seen = Set<String>()
        for (way, role) in ways {
            let rec: Record?
            let wayName: String
            switch way {
            case .safe: continue
            case .key(let k):
                wayName = keyWay(k)
                rec = keys[k] ?? Record(provider: k, terms: .unknown, summary: "no terms are on record for this key", source: "")
            case .plan(let p):
                wayName = planWay(p)
                rec = plans[p] ?? Record(provider: p, terms: .unknown, summary: "no terms are on record for this plan", source: "")
            case .openRouter(let id):
                wayName = "openrouter:" + id
                let pin = OpenRouterRoute.catalog.first { $0.model.id == id }
                let upstream = pin.flatMap { $0.providerTag.split(separator: "/").first.map(String.init) }
                let up = upstream.flatMap { upstreams[$0] }
                // An upstream that trains is refused by OpenRouter under the switch (`data_collection: deny`), so the
                // call fails instead of reading; say so before the run.
                if let up, up.terms == .never { continue }
                rec = up ?? unpinned
            }
            guard let rec, !safe(rec, way: wayName, resources: resources), seen.insert(wayName + role).inserted else { continue }
            if case .openRouter = way {
                lines.append("• \(role.prefix(1).uppercased() + role.dropFirst()) through \(rec.provider): \(rec.summary). "
                             + "OpenRouter is told not to send these pages to a provider that may train, so those calls will fail.")
            } else {
                lines.append("• \(role.prefix(1).uppercased() + role.dropFirst()) with \(rec.provider): \(rec.summary).")
            }
        }
        guard !lines.isEmpty else { return nil }
        return "This collection's settings say its pages must not train a provider's models, but this run would send them where they may:\n\n"
            + lines.joined(separator: "\n")
            + "\n\nIf the key is billed or the plan's training setting is off, say so in Settings, under the general questions, and this warning stops."
    }

    /// The solver's blocker: one fixed prefix the sheet recognises, then the provider's own sentence.
    static let blockerPrefix = "may train on the pages: "
    static func blocker(_ rec: Record) -> String { blockerPrefix + rec.provider + " — " + rec.summary }
}

// MARK: - The ways a Process Files run sends pages (W46.training-optout-run)

extension SettingsTraining {
    /// The reader's way: the Local Agent's plan first, then the gateway, then the provider's own key, as the run
    /// picks them (`OCRProcessor`'s client choice).
    /// `gatewayKnown`: the gateway is Stanford's (the record's) or a model on this Mac; another is a way with no terms.
    static func readingWay(provider: LLMProvider, modelID: String, gateway: Bool, gatewayKnown: Bool = true,
                           localAgent: LocalAgentTool?) -> RunWay {
        switch localAgent {
        case .claude?: return .plan("claude")
        case .codex?: return .plan("chatgpt")
        // The Gemini CLI signs in with a personal Google account, whose free entitlement Google may train on; the
        // billed-key answer does not cover it, so it is a plan no answer lifts.
        case .gemini?: return .plan("gemini-cli")
        case nil: break
        }
        if gateway { return gatewayKnown ? .safe : .key("custom-gateway") }
        switch provider {
        case .appleVision: return .safe
        case .openrouter: return .openRouter(modelID: modelID)
        case .anthropic: return .key("anthropic")
        case .openai: return .key("openai")
        case .gemini: return .key("gemini")
        case .mistral: return .key("mistral")
        }
    }

    /// A refused page's second readers that may train (`OCRRefusalFallback.availableRoutes`, in its order): the
    /// Claude plan, Qwen3.6 27B through OpenRouter, a Mistral key. The Anthropic and OpenAI keys never train.
    static func refusalFallbackWays(claudeByPlan: Bool, openRouterKey: Bool, mistralKey: Bool) -> [RunWay] {
        var out: [RunWay] = []
        if claudeByPlan { out.append(.plan("claude")) }
        if openRouterKey { out.append(.openRouter(modelID: OCRRefusalFallback.keyedModels[1].id)) }
        if mistralKey { out.append(.key("mistral")) }
        return out
    }

    /// The window segmenter's ways: each voter of the approach (and the 2B's partner), by the way the run sends it.
    static func segmentationWays(_ plan: SegmentationPlan, routes: SegmentationRoutes,
                                 options: SegmentationOptions?) -> [RunWay] {
        guard case .windows(let approach) = plan, let options else { return [] }
        let spec: ApproachSpec?
        if approach == .local, let partner = routes.localPartner {
            spec = try? options.spec(for: approach, partner: partner)
        } else {
            spec = try? options.spec(for: approach)
        }
        return (spec?.voters ?? []).map { v in
            switch v.provider {
            case .local: return .safe
            case .gemini: return .key("gemini")
            case .anthropic:
                // W41.app-openrouter-claude: Claude outside the mix may go through OpenRouter (`WindowStageTransport.make`).
                if routes.claudeByPlan { return .plan("claude") }
                if approach != .mix, routes.claudeThroughOpenRouter, let id = OpenRouterRoute.through(
                    provider: .anthropic, modelID: v.modelID)?.model.id { return .openRouter(modelID: id) }
                return .key("anthropic")
            case .openai: return routes.chatGPTByPlan ? .plan("chatgpt") : .key("openai")
            case .openrouter: return .openRouter(modelID: v.modelID)
            }
        }
    }
}
