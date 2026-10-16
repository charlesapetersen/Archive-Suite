import Foundation

// MARK: - The approach chooser's rows (W36.seg-opt-chooser)

/// What the user has that an approach's voters can run on. Read once by the view (the Keychain is never read in a
/// view body) and passed in, so the row text is a pure function the headless test can drive.
struct SegmentationRoutes: Equatable, Sendable {
    var hasAnthropicKey = false
    var hasGeminiKey = false
    var hasOpenAIKey = false
    var hasOpenRouterKey = false
    /// The user's own `claude` is installed. Whether it is signed in is only known at the first call: the app
    /// never reads the login (`segbench-results/usage.md`).
    var hasClaudeCLI = false
    /// Which way Claude goes when both an Anthropic key and `claude` exist (W36.seg-opt-subscription).
    var claudeRoute: ClaudeRoute = .apiKey
    /// The signed-in ChatGPT account (Sign in with ChatGPT), or nil (W36.seg-opt-siwc).
    var chatGPTAccount: String?
    /// A ChatGPT registration is saved whose tokens went bad: offer to forget it, so another account can sign in.
    var chatGPTStale = false
    /// Which way ChatGPT goes when both an OpenAI key and a ChatGPT sign-in exist.
    var chatGPTRoute: ChatGPTRoute = .apiKey
    /// The plan's share, measured on this account by earlier runs.
    var planCalibration = PlanCalibrationStore()

    static let none = SegmentationRoutes()

    /// Claude's windows go by the user's own plan: `claude` is there, and either no key or the user chose the plan.
    var claudeByPlan: Bool { hasClaudeCLI && (!hasAnthropicKey || claudeRoute == .plan) }
    /// The route is the user's to choose only when both exist.
    var offersClaudeRouteChoice: Bool { hasClaudeCLI && hasAnthropicKey }
    var hasChatGPTPlan: Bool { chatGPTAccount != nil }
    /// ChatGPT's windows go by the user's ChatGPT plan: signed in, and either no key or the user chose the plan.
    var chatGPTByPlan: Bool { hasChatGPTPlan && (!hasOpenAIKey || chatGPTRoute == .plan) }
    var offersChatGPTRouteChoice: Bool { hasChatGPTPlan && hasOpenAIKey }

    /// Reads the Keychain and looks for `claude`. Never call it from a view body.
    static func current(_ defaults: UserDefaults = .standard) -> SegmentationRoutes {
        // The path override belongs to whichever CLI the OCR backend uses; it names `claude` only when that is it.
        let tool = defaults.string(forKey: DefaultsKeys.localAgentTool).flatMap(LocalAgentTool.init(rawValue:))
        let override = tool == .claude ? (defaults.string(forKey: DefaultsKeys.localAgentBinaryPath) ?? "") : ""
        return SegmentationRoutes(
            hasAnthropicKey: !(KeychainHelper.load(account: LLMProvider.anthropic.rawValue) ?? "").isEmpty,
            hasGeminiKey: !(KeychainHelper.load(account: LLMProvider.gemini.rawValue) ?? "").isEmpty,
            hasOpenAIKey: !(KeychainHelper.load(account: LLMProvider.openai.rawValue) ?? "").isEmpty,
            hasOpenRouterKey: !(KeychainHelper.load(account: LLMProvider.openrouter.rawValue) ?? "").isEmpty,
            hasClaudeCLI: LocalAgentClient.resolveBinaryPath(tool: .claude, override: override) != nil,
            claudeRoute: ClaudeRoute.stored(defaults),
            chatGPTAccount: ChatGPTAuth.shared.signedInAccount(),
            chatGPTStale: ChatGPTAuth.shared.hasStaleRegistration,
            chatGPTRoute: ChatGPTRoute.stored(defaults),
            planCalibration: PlanCalibrationStore.load(defaults))
    }

    /// `current()` for the views that show the chooser: once the keys are read, an unsaved approach is
    /// preselected from them (`SegmentationApproach.preselect`, W41.app-seg-default). Never from a view body.
    static func currentPreselecting(_ defaults: UserDefaults = .standard) -> SegmentationRoutes {
        let routes = current(defaults)
        SegmentationApproach.preselect(routes, defaults: defaults)
        return routes
    }

    func hasKey(_ p: WindowProvider) -> Bool {
        switch p {
        case .anthropic: return hasAnthropicKey
        case .gemini: return hasGeminiKey
        case .openai: return hasOpenAIKey
        case .openrouter: return hasOpenRouterKey
        }
    }

    /// A voter can run by API key, Claude through the user's own `claude`, ChatGPT through the user's ChatGPT plan.
    func canRun(_ p: WindowProvider) -> Bool {
        hasKey(p) || (p == .anthropic && hasClaudeCLI) || (p == .openai && hasChatGPTPlan)
    }
}

/// One approach's row, scaled to the run: the five figures of Part 3 §3 and the cost of §4, as the user reads
/// them. Built only from `options.json`'s `figures.test` and cost, so the app never shows a number the bench did
/// not measure (`execution-plans/segmentation/04-options-build.md` Part 3 §3–4).
struct SegmentationRow: Equatable, Sendable {
    let approach: SegmentationApproach
    let label: String
    let pageCount: Int
    /// nil for manual, which proposes nothing.
    let rightWithNoChecking: String?
    let toCheck: String
    let rightAfterChecking: String
    let unshownErrors: String
    /// One line per way of paying, in order: dollars by API key, the share of the Claude plan, the ChatGPT plan.
    let costLines: [String]
    /// What qualifies the dollars: a scheduled price change, or prices read more than 90 days ago.
    let priceNotes: [String]
    /// The dollars this approach adds to the run by API key: 0 for manual, nil when it is paid by the plan only
    /// or cannot run (a run's total never includes an approach it cannot use).
    let apiDollars: Double?
    /// The same footnote on every row, built from the file.
    let footnote: String
    /// Why it cannot run, or nil. A row with a reason is shown greyed out.
    let unavailableReason: String?
    /// The providers whose key would make it runnable (offered through the key wizard).
    let missingKeys: [WindowProvider]

    var canRun: Bool { unavailableReason == nil }

    /// The cost panes' one-line figure: $0 for manual, the dollars by API key, or "your plan" when only the
    /// user's own `claude` can run it.
    var costSummary: String {
        if !approach.proposesBoundaries { return CostEstimate.money(0) }
        if let d = apiDollars { return CostEstimate.money(d) }
        return canRun ? "your plan" : "—"
    }

    // MARK: Building

    /// - Parameters:
    ///   - pageCount: the pages the run will segment (`N`).
    ///   - today: the day the prices are judged against, in the user's own time zone (tests pass a fixed day).
    ///
    /// There is no batch figure: the engine sends every window interactively, so §4's "batch beside list" has
    /// nothing to describe until a batch route exists.
    static func make(_ approach: SegmentationApproach, options: SegmentationOptions, pageCount: Int,
                     routes: SegmentationRoutes, today: Date = Date()) -> SegmentationRow {
        let n = max(0, pageCount)
        let entry = options.approach(approach)
        let label = entry?.label ?? approach.rawValue
        let footnote = footnote(options)
        guard let entry, entry.available, let fig = entry.figures?.test else {
            return SegmentationRow(approach: approach, label: label, pageCount: n, rightWithNoChecking: nil,
                                   toCheck: "", rightAfterChecking: "", unshownErrors: "", costLines: [],
                                   priceNotes: [],
                                   apiDollars: nil, footnote: footnote,
                                   unavailableReason: entry?.reason ?? "Not measured yet.", missingKeys: [])
        }

        let checks = max(1, Int((fig.flaggedPer100Pages * Double(n) / 100).rounded()))
        let toCheck = approach.proposesBoundaries
            ? "about \(checks) boundar\(checks == 1 ? "y" : "ies") to check"
            : "about \(checks) boundar\(checks == 1 ? "y" : "ies") to judge"
        let unshown: String
        if fig.unflaggedErrors == 0 || fig.unflaggedErrorsPer500Pages <= 0 {
            unshown = "none in \(fig.pages) test pages"
        } else {
            unshown = "about 1 in \(twoSignificant(500 / fig.unflaggedErrorsPer500Pages)) pages"
        }

        // Which providers this approach needs, and which of them the user can reach.
        let providers = providerOrder(entry)
        let missing = providers.filter { !routes.canRun($0) }
        let missingKeys = missing.filter { !routes.hasKey($0) }
        let reason: String? = missing.isEmpty ? nil : "Needs " + missing.map(needPhrase).joined(separator: " and ") + "."

        let (lines, notes, dollars) = approach.proposesBoundaries
            ? costLines(entry, pageCount: n, routes: routes, today: today)
            : (["No cost"], [], 0)

        return SegmentationRow(
            approach: approach, label: label, pageCount: n,
            rightWithNoChecking: fig.pagesExactNoReview.map { "about \(percent($0)) of pages" },
            toCheck: toCheck,
            rightAfterChecking: "about \(percent(fig.pagesExactAfterReview)) of pages",
            unshownErrors: unshown, costLines: lines, priceNotes: notes,
            // An approach that cannot run adds nothing to a run's total; its row still shows what it would cost.
            apiDollars: reason == nil ? dollars : nil, footnote: footnote,
            unavailableReason: reason, missingKeys: missingKeys)
    }

    static func all(options: SegmentationOptions, pageCount: Int, routes: SegmentationRoutes,
                    today: Date = Date()) -> [SegmentationRow] {
        SegmentationApproach.allCases.map {
            make($0, options: options, pageCount: pageCount, routes: routes, today: today)
        }
    }

    // MARK: Cost (Part 3 §4)

    /// The notional dollars of an approach's Claude windows for `pageCount` pages: what the plan's share is
    /// scaled by. nil when the approach has no Claude voter or the file has no figure.
    static func planNotionalUSD(_ approach: SegmentationApproach, options: SegmentationOptions?,
                                pageCount: Int) -> Double? {
        guard let tokens = options?.approach(approach)?.tokensPer1000Pages else { return nil }
        let claude = tokens.values.filter { t in
            WindowVoter.catalog.first(where: { $0.modelID == t.model })?.provider == .anthropic
        }.compactMap(\.subscriptionRouteNotionalUSDPer1000Pages)
        guard !claude.isEmpty else { return nil }
        return claude.reduce(0, +) * Double(max(0, pageCount)) / 1000
    }

    /// Each model priced on its own. A Claude model goes by the Claude plan when `claude` is installed and either
    /// there is no Anthropic key or the user chose the plan; every other model is priced by API key at list
    /// price, including one whose key the user does not have yet, so a greyed-out row still says what the key
    /// would cost. The plan line is the notional figure until a run has measured this account, then the share.
    /// ChatGPT by its plan has no meter an app can read (usage.md), so its line is the token figure and the notional
    /// API price of the same calls, labelled approximate, with "Using ChatGPT plan".
    private static func costLines(_ entry: SegmentationOptions.Approach, pageCount n: Int,
                                  routes: SegmentationRoutes, today: Date) -> ([String], [String], Double?) {
        let models = (entry.cost?.perModel ?? [:]).sorted { $0.key < $1.key }
        let day = dayString(today)
        var apiList = 0.0, anyAPI = false
        var notes: [String] = []
        var planNotional = 0.0, anyPlan = false
        var chatGPTTokens = 0.0, chatGPTNotional = 0.0, anyChatGPTPlan = false
        for (key, cost) in models {
            let tokens = entry.tokensPer1000Pages?[key]
            // problems() refuses a model outside the catalog, so this never skips in a shipped file.
            guard let provider = WindowVoter.catalog.first(where: { $0.modelID == tokens?.model })?.provider
            else { continue }
            if provider == .anthropic, routes.claudeByPlan,
               let notional = tokens?.subscriptionRouteNotionalUSDPer1000Pages {
                anyPlan = true
                planNotional += notional * Double(n) / 1000
                continue
            }
            if provider == .openai, routes.chatGPTByPlan {
                anyChatGPTPlan = true
                chatGPTTokens += (tokens?.appTokensPer1000Pages ?? 0) * Double(n) / 1000
                chatGPTNotional += cost.listUSDPer1000Pages * Double(n) / 1000
                continue
            }
            anyAPI = true
            var list = cost.listUSDPer1000Pages
            if let change = cost.priceChange {
                // `after_2026_12_31`: the old price holds through that day, the new one from the next.
                if day > change.date {
                    list = change.total.listUSDPer1000Pages
                } else {
                    notes.append("\(providerName(provider)): introductory price until \(longDate(change.date))")
                }
            }
            apiList += list * Double(n) / 1000
            if let read = cost.priceRead, let age = daysBetween(read, day), age > 90 {
                notes.append("\(providerName(provider)) prices as of \(longDate(read))")
            }
        }
        var lines: [String] = []
        if anyAPI { lines.append("about \(dollars(apiList)) by API key at list price") }
        if anyPlan {
            if let share = routes.planCalibration.estimate(notionalUSD: planNotional),
               let date = routes.planCalibration.lastMeasured {
                lines.append("Claude plan: \(share); measured on your account, \(PlanShareText.measuredDate(date))")
            } else {
                lines.append("Claude plan: uses about as much of your plan as \(dollars(planNotional)) of API calls "
                             + "at list price; measured on your account after the first run")
            }
        }
        if anyChatGPTPlan {
            let tokenText = chatGPTTokens > 0 ? "about \(tokenCount(chatGPTTokens)) tokens, " : ""
            lines.append("ChatGPT plan: \(tokenText)roughly \(dollars(chatGPTNotional)) "
                         + "of API calls at list price (approximate). Using ChatGPT plan")
        }
        return (lines, notes, anyAPI ? apiList : nil)
    }

    // MARK: Formatting

    static func footnote(_ o: SegmentationOptions) -> String {
        let test = o.approaches.compactMap { $0.figures?.test }.first
        let pages = test.map { " (\($0.pages) pages)" } ?? ""
        return "Measured once on two boxes\(pages) of one archive, \(longDate(o.measured)). Your material may differ."
    }

    /// Whole percent, from a fraction.
    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    /// Two significant figures: 121 → 120, 181.5 → 180, 47.3 → 47, 8.04 → 8.
    static func twoSignificant(_ v: Double) -> String {
        guard v > 0, v.isFinite else { return "0" }
        let magnitude = pow(10, floor(log10(v)) - 1)
        let r = (v / magnitude).rounded() * magnitude
        return r >= 10 ? String(Int(r.rounded())) : String(format: "%.1f", r).replacingOccurrences(of: ".0", with: "")
    }

    /// 6.9 million → "6.9M", 48,000 → "48K", 900 → "900".
    static func tokenCount(_ v: Double) -> String {
        if v >= 1_000_000 { return twoSignificant(v / 1_000_000) + "M" }
        if v >= 1_000 { return twoSignificant(v / 1_000) + "K" }
        return twoSignificant(v)
    }

    static func dollars(_ v: Double) -> String {
        if v > 0 && v < 0.01 { return "under $0.01" }
        return "$" + String(format: "%.2f", v)
    }

    /// The providers an approach's voters are reached through, in voter order.
    static func providers(_ approach: SegmentationApproach, options: SegmentationOptions?) -> [WindowProvider] {
        options?.approach(approach).map(providerOrder) ?? []
    }

    private static func providerOrder(_ e: SegmentationOptions.Approach) -> [WindowProvider] {
        var out: [WindowProvider] = []
        for name in e.voters ?? [] {
            if case .success(let v) = WindowVoter.resolve(name), !out.contains(v.provider) { out.append(v.provider) }
        }
        return out
    }

    private static func providerName(_ p: WindowProvider) -> String {
        switch p {
        case .anthropic: return "Claude"
        case .gemini: return "Gemini"
        case .openai: return "ChatGPT"
        case .openrouter: return "GLM-5.3 Flash"
        }
    }

    private static func needPhrase(_ p: WindowProvider) -> String {
        switch p {
        case .anthropic: return "an Anthropic API key, or the claude tool installed and signed in"
        case .gemini: return "a Gemini API key"
        case .openai: return "an OpenAI API key, or Sign in with ChatGPT"
        case .openrouter: return "an OpenRouter API key"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The user's own calendar day, so a price changes at their midnight rather than UTC's.
    static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let a = dayFormatter.date(from: from), let b = dayFormatter.date(from: to) else { return nil }
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    /// `2026-12-31` → `31 Dec 2026`; anything else comes back unchanged.
    static func longDate(_ s: String) -> String {
        guard let d = dayFormatter.date(from: s) else { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }
}

/// The bundled figures, decoded once. nil when the file is missing or does not decode (a build defect the
/// engine test catches); the chooser then shows only Manual.
enum SegmentationOptionsStore {
    static let shared: SegmentationOptions? = try? SegmentationOptions.loadBundled()
}
