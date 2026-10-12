import Foundation

// MARK: - The approach chooser's rows (W36.seg-opt-chooser)

/// What the user has that an approach's voters can run on. Read once by the view (the Keychain is never read in a
/// view body) and passed in, so the row text is a pure function the headless test can drive.
struct SegmentationRoutes: Equatable, Sendable {
    var hasAnthropicKey = false
    var hasGeminiKey = false
    var hasOpenAIKey = false
    /// The user's own `claude` is installed. Whether it is signed in is only known at the first call: the app
    /// never reads the login (`segbench-results/usage.md`).
    var hasClaudeCLI = false

    static let none = SegmentationRoutes()

    /// Reads the Keychain and looks for `claude`. Never call it from a view body.
    static func current(_ defaults: UserDefaults = .standard) -> SegmentationRoutes {
        // The path override belongs to whichever CLI the OCR backend uses; it names `claude` only when that is it.
        let tool = defaults.string(forKey: DefaultsKeys.localAgentTool).flatMap(LocalAgentTool.init(rawValue:))
        let override = tool == .claude ? (defaults.string(forKey: DefaultsKeys.localAgentBinaryPath) ?? "") : ""
        return SegmentationRoutes(
            hasAnthropicKey: !(KeychainHelper.load(account: LLMProvider.anthropic.rawValue) ?? "").isEmpty,
            hasGeminiKey: !(KeychainHelper.load(account: LLMProvider.gemini.rawValue) ?? "").isEmpty,
            hasOpenAIKey: !(KeychainHelper.load(account: LLMProvider.openai.rawValue) ?? "").isEmpty,
            hasClaudeCLI: LocalAgentClient.resolveBinaryPath(tool: .claude, override: override) != nil)
    }

    func hasKey(_ p: WindowProvider) -> Bool {
        switch p {
        case .anthropic: return hasAnthropicKey
        case .gemini: return hasGeminiKey
        case .openai: return hasOpenAIKey
        }
    }

    /// A voter can run by API key, or (Claude only) through the user's own `claude`.
    func canRun(_ p: WindowProvider) -> Bool { hasKey(p) || (p == .anthropic && hasClaudeCLI) }
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
    /// One line per way of paying, in order: dollars by API key, then the share of the Claude plan.
    let costLines: [String]
    /// What qualifies the dollars: a scheduled price change, or prices read more than 90 days ago.
    let priceNotes: [String]
    /// The dollars this approach adds to the run by API key (nil when it is paid by plan only, or manual = 0).
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
    ///   - batch: the run goes by batch, so the batch price is shown beside the list price.
    ///   - today: the day the prices are judged against (`yyyy-MM-dd` comparisons; tests pass a fixed day).
    static func make(_ approach: SegmentationApproach, options: SegmentationOptions, pageCount: Int,
                     routes: SegmentationRoutes, batch: Bool = false, today: Date = Date()) -> SegmentationRow {
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
            ? costLines(entry, pageCount: n, routes: routes, batch: batch, today: today)
            : (["No cost"], [], 0)

        return SegmentationRow(
            approach: approach, label: label, pageCount: n,
            rightWithNoChecking: fig.pagesExactNoReview.map { "about \(percent($0)) of pages" },
            toCheck: toCheck,
            rightAfterChecking: "about \(percent(fig.pagesExactAfterReview)) of pages",
            unshownErrors: unshown, costLines: lines, priceNotes: notes, apiDollars: dollars, footnote: footnote,
            unavailableReason: reason, missingKeys: missingKeys)
    }

    static func all(options: SegmentationOptions, pageCount: Int, routes: SegmentationRoutes,
                    batch: Bool = false, today: Date = Date()) -> [SegmentationRow] {
        SegmentationApproach.allCases.map {
            make($0, options: options, pageCount: pageCount, routes: routes, batch: batch, today: today)
        }
    }

    // MARK: Cost (Part 3 §4)

    /// Each model priced on its own: dollars by API key when the user has that provider's key, else the Claude
    /// plan's notional share when `claude` is installed. A model with neither contributes nothing (the row is
    /// unavailable anyway).
    private static func costLines(_ entry: SegmentationOptions.Approach, pageCount n: Int,
                                  routes: SegmentationRoutes, batch: Bool,
                                  today: Date) -> ([String], [String], Double?) {
        let models = (entry.cost?.perModel ?? [:]).sorted { $0.key < $1.key }
        let day = dayString(today)
        var apiList = 0.0, apiBatch = 0.0, anyAPI = false, allBatch = true
        var notes: [String] = []
        var planNotional = 0.0, anyPlan = false
        for (key, cost) in models {
            let modelID = entry.tokensPer1000Pages?[key]?.model
            let provider = WindowVoter.catalog.first { $0.modelID == modelID }?.provider
            guard let provider else { continue }
            if routes.hasKey(provider) {
                anyAPI = true
                var list = cost.listUSDPer1000Pages, bat = cost.batchUSDPer1000Pages
                if let change = cost.priceChange {
                    if day >= change.date {
                        list = change.total.listUSDPer1000Pages
                        bat = change.total.batchUSDPer1000Pages
                    } else {
                        notes.append("\(providerName(provider)): introductory price until \(longDate(change.date))")
                    }
                }
                apiList += list * Double(n) / 1000
                if let bat { apiBatch += bat * Double(n) / 1000 } else { allBatch = false }
                if let read = cost.priceRead, let age = daysBetween(read, day), age > 90 {
                    notes.append("\(providerName(provider)) prices as of \(longDate(read))")
                }
            } else if provider == .anthropic, routes.hasClaudeCLI,
                      let notional = entry.tokensPer1000Pages?[key]?.subscriptionRouteNotionalUSDPer1000Pages {
                anyPlan = true
                planNotional += notional * Double(n) / 1000
            }
        }
        var lines: [String] = []
        if anyAPI {
            var line = "about \(dollars(apiList)) by API key at list price"
            if batch && allBatch { line += " (\(dollars(apiBatch)) by batch)" }
            lines.append(line)
        }
        if anyPlan {
            lines.append("Claude plan: uses about as much of your plan as \(dollars(planNotional)) of API calls "
                         + "at list price; measured on your account after the first run")
        }
        return (lines, notes, anyAPI ? (batch && allBatch ? apiBatch : apiList) : nil)
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

    static func dollars(_ v: Double) -> String {
        if v > 0 && v < 0.01 { return "under $0.01" }
        return "$" + String(format: "%.2f", v)
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
        }
    }

    private static func needPhrase(_ p: WindowProvider) -> String {
        switch p {
        case .anthropic: return "an Anthropic API key, or the claude tool installed and signed in"
        case .gemini: return "a Gemini API key"
        case .openai: return "an OpenAI API key"
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ d: Date) -> String { dayFormatter.string(from: d) }

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
