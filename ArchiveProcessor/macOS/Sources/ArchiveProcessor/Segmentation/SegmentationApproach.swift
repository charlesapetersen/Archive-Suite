import Foundation

// MARK: - Segmentation approach (W36.seg-opt-engine)

/// Who proposes the document boundaries of a run. Split out of `TaggingMode`, which now answers only who
/// tags (execution-plans/segmentation/04-options-build.md Part 3 §1). The raw values are the approach `id`s
/// of `segbench-results/options.json`; a test fails if the two drift apart.
///
/// Every approach other than `manual` is a first draft the user reviews: the flagged boundaries are put in
/// front of the user (W36.seg-opt-review) and the rest stay visible in the review sheet. Nothing is filed
/// unseen.
enum SegmentationApproach: String, CaseIterable, Identifiable, Codable, Sendable {
    case manual   // the user segments; nothing is proposed (the app as it was)
    case claude   // Claude Sonnet 5.5 over seven-page windows
    case gemini   // Gemini 3.8 Flash over the same windows
    case openai   // an OpenAI model over the same windows; offered only once options.json measures it
    case mix      // the window voters combined by the rule options.json names

    var id: String { rawValue }

    /// Off until the user picks otherwise: an approach that spends money or plan usage is never the default.
    static let defaultApproach: SegmentationApproach = .manual

    var proposesBoundaries: Bool { self != .manual }

    /// The stored choice. An unknown or missing value reads as the default.
    static func stored(_ defaults: UserDefaults = .standard) -> SegmentationApproach {
        defaults.string(forKey: DefaultsKeys.segmentationApproach)
            .flatMap(SegmentationApproach.init(rawValue:)) ?? defaultApproach
    }
}

// MARK: - options.json

/// The bench's figures and parameters for every approach, decoded from `segbench-results/options.json`, which
/// the app bundles by relative path (`project.yml`) so a bench re-run reaches the app on its next build. The
/// engine reads its window shape, each approach's rule and level, and its voters from here and never
/// hard-codes them; the chooser (W36.seg-opt-chooser) reads `figures.test` and the cost.
struct SegmentationOptions: Decodable, Sendable {
    static let supportedVersions: Set<Int> = [1]

    let version: Int
    let measured: String
    let window: Window
    let approaches: [Approach]

    struct Window: Decodable, Sendable {
        let pages: Int
        let stride: Int
        let thumbnailLongEdgePx: Int
        let ocrTextCharsPerPage: Int

        enum CodingKeys: String, CodingKey {
            case pages, stride
            case thumbnailLongEdgePx = "thumbnail_long_edge_px"
            case ocrTextCharsPerPage = "ocr_text_chars_per_page"
        }
    }

    struct Figures: Decodable, Sendable {
        let pages: Int
        let gaps: Int
        let flagged: Int
        let pagesExactNoReview: Double?
        let flaggedPer100Pages: Double
        let pagesExactAfterReview: Double
        let unflaggedErrors: Int
        let unflaggedErrorsPer500Pages: Double

        enum CodingKeys: String, CodingKey {
            case pages, gaps, flagged
            case pagesExactNoReview = "pages_exact_no_review"
            case flaggedPer100Pages = "flagged_per_100_pages"
            case pagesExactAfterReview = "pages_exact_after_review"
            case unflaggedErrors = "unflagged_errors"
            case unflaggedErrorsPer500Pages = "unflagged_errors_per_500_pages"
        }
    }

    struct FigureSets: Decodable, Sendable {
        let test: Figures?
    }

    struct CostTotal: Decodable, Sendable {
        let listUSDPer1000Pages: Double
        let batchUSDPer1000Pages: Double?

        enum CodingKeys: String, CodingKey {
            case listUSDPer1000Pages = "list_usd_per_1000_pages"
            case batchUSDPer1000Pages = "batch_usd_per_1000_pages"
        }
    }

    /// One model's price, as the bench read it. A scheduled price change is an `after_YYYY_MM_DD` key (Gemini's
    /// introductory price ends on 2026-12-31); it is read by pattern so the date is never hard-coded.
    struct ModelCost: Decodable, Sendable {
        let listUSDPer1000Pages: Double
        let batchUSDPer1000Pages: Double?
        /// `yyyy-MM-dd`, the day the price was read off the provider's page.
        let priceRead: String?
        /// The day the price changes (`yyyy-MM-dd`) and the price from then on.
        let priceChange: (date: String, total: CostTotal)?

        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            listUSDPer1000Pages = try c.decode(Double.self, forKey: AnyKey(stringValue: "list_usd_per_1000_pages"))
            batchUSDPer1000Pages = try c.decodeIfPresent(Double.self,
                                                         forKey: AnyKey(stringValue: "batch_usd_per_1000_pages"))
            priceRead = try c.decodeIfPresent(String.self, forKey: AnyKey(stringValue: "price_read"))
            let after = c.allKeys.compactMap { key -> (String, AnyKey)? in
                guard let r = key.stringValue.range(of: #"^after_\d{4}_\d{2}_\d{2}$"#, options: .regularExpression)
                else { return nil }
                return (String(key.stringValue[r].dropFirst("after_".count)).replacingOccurrences(of: "_", with: "-"),
                        key)
            }.min { $0.0 < $1.0 }
            if let (date, key) = after {
                priceChange = (date, try c.decode(CostTotal.self, forKey: key))
            } else {
                priceChange = nil
            }
        }
    }

    struct Cost: Decodable, Sendable {
        let total: CostTotal
        /// Keyed by the bench's voter letter (`C`, `G`), as `tokens_per_1000_pages` is.
        let perModel: [String: ModelCost]?

        enum CodingKeys: String, CodingKey {
            case total
            case perModel = "per_model"
        }
    }

    /// What one voter's model uses per 1,000 pages, whatever the plan. The subscription route's notional
    /// figure is what the same calls would cost at API list price, so the plan's share can be put in dollars
    /// before the user's own account has been measured.
    struct Tokens: Decodable, Sendable {
        let model: String
        let inputPer1000Pages: Double
        let outputPer1000Pages: Double
        let subscriptionRouteNotionalUSDPer1000Pages: Double?

        enum CodingKeys: String, CodingKey {
            case model
            case inputPer1000Pages = "input_per_1000_pages"
            case outputPer1000Pages = "output_per_1000_pages"
            case subscriptionRouteNotionalUSDPer1000Pages = "subscription_route_notional_usd_per_1000_pages"
        }
    }

    struct Approach: Decodable, Sendable {
        let id: String
        let label: String
        let available: Bool
        let voters: [String]?
        let rule: String?
        let level: Double?
        let reason: String?
        let figures: FigureSets?
        let cost: Cost?
        let tokensPer1000Pages: [String: Tokens]?

        enum CodingKeys: String, CodingKey {
            case id, label, available, voters, rule, level, reason, figures, cost
            case tokensPer1000Pages = "tokens_per_1000_pages"
        }
    }

    func approach(_ a: SegmentationApproach) -> Approach? {
        approaches.first { $0.id == a.rawValue }
    }

    // MARK: Loading

    /// The bundled file's name. `project.yml` adds `../segbench-results/options.json` as a resource.
    static let resourceName = "options"

    static func decode(_ data: Data) throws -> SegmentationOptions {
        try JSONDecoder().decode(SegmentationOptions.self, from: data)
    }

    static func loadBundled(_ bundle: Bundle = .main) throws -> SegmentationOptions {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw SegmentationOptionsError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    // MARK: Validation

    /// Everything about the file that would make the app show a number the bench did not measure, or run an
    /// approach with a missing parameter. Empty means the file is fit to ship.
    func problems() -> [String] {
        var out: [String] = []
        if !Self.supportedVersions.contains(version) { out.append("unknown version \(version)") }
        if window.pages < 2 || window.stride < 1 { out.append("window \(window.pages)/\(window.stride)") }
        for a in approaches {
            guard let approach = SegmentationApproach(rawValue: a.id) else {
                out.append("approach \(a.id) has no SegmentationApproach case")
                continue
            }
            guard a.available else {
                if a.reason?.isEmpty ?? true { out.append("\(a.id): unavailable with no reason") }
                continue
            }
            if a.figures?.test == nil { out.append("\(a.id): no figures.test") }
            guard approach.proposesBoundaries else { continue }
            if a.level == nil { out.append("\(a.id): no level") }
            if let cost = a.cost {
                // The chooser prices each model on its own (a price change can reach one before another), so
                // the per-model figures have to add up to the file's total, and each needs its model's tokens.
                let models = cost.perModel ?? [:]
                let sum = models.values.reduce(0) { $0 + $1.listUSDPer1000Pages }
                if models.isEmpty || abs(sum - cost.total.listUSDPer1000Pages) > 1e-6 {
                    out.append("\(a.id): per-model list prices do not add up to the total")
                }
                for key in models.keys where a.tokensPer1000Pages?[key] == nil {
                    out.append("\(a.id): cost \(key) has no tokens_per_1000_pages entry")
                }
            } else {
                out.append("\(a.id): no cost")
            }
            if WindowCombineRule(rawValue: a.rule ?? "") == nil { out.append("\(a.id): rule \(a.rule ?? "nil")") }
            let voters = a.voters ?? []
            if voters.isEmpty { out.append("\(a.id): no voters") }
            for v in voters {
                switch WindowVoter.resolve(v) {
                case .success: break
                case .failure(let e): out.append("\(a.id): \(e.description)")
                }
            }
        }
        for c in SegmentationApproach.allCases where approach(c) == nil {
            out.append("SegmentationApproach.\(c.rawValue) has no approach in the file")
        }
        return out
    }

    /// The engine's parameters for one approach, or why it cannot run.
    func spec(for a: SegmentationApproach) throws -> ApproachSpec {
        guard a.proposesBoundaries else { throw SegmentationOptionsError.manual }
        guard let entry = approach(a) else { throw SegmentationOptionsError.unknownApproach(a.rawValue) }
        guard entry.available else { throw SegmentationOptionsError.unavailable(a.rawValue, entry.reason ?? "") }
        guard let level = entry.level, let rule = WindowCombineRule(rawValue: entry.rule ?? "") else {
            throw SegmentationOptionsError.incomplete(a.rawValue)
        }
        var voters: [WindowVoter] = []
        for name in entry.voters ?? [] {
            switch WindowVoter.resolve(name) {
            case .success(let v): voters.append(v)
            case .failure(let e): throw SegmentationOptionsError.voter(a.rawValue, e.description)
            }
        }
        guard !voters.isEmpty else { throw SegmentationOptionsError.incomplete(a.rawValue) }
        return ApproachSpec(approach: a, voters: voters, rule: rule, level: level,
                            windowPages: window.pages, windowStride: window.stride,
                            thumbnailLongEdgePx: window.thumbnailLongEdgePx,
                            ocrTextChars: window.ocrTextCharsPerPage)
    }
}

enum SegmentationOptionsError: Error, LocalizedError, Equatable {
    case missingResource
    case manual
    case unknownApproach(String)
    case unavailable(String, String)
    case incomplete(String)
    case voter(String, String)

    var errorDescription: String? {
        switch self {
        case .missingResource: return "The segmentation figures (options.json) are missing from the app."
        case .manual: return "Manual segmentation proposes nothing."
        case .unknownApproach(let id): return "No figures for the approach \(id)."
        case .unavailable(let id, let why): return "\(id) is not available: \(why)"
        case .incomplete(let id): return "The figures for \(id) lack a level, rule or voter."
        case .voter(let id, let why): return "\(id): \(why)"
        }
    }
}

// MARK: - The engine's parameters

/// How a mix turns several voters' verdicts on one gap into one. Read from options.json, never assumed.
enum WindowCombineRule: String, Sendable {
    /// `ensemble.py` `judge`: majority decision (a tie to the more confident voter); flagged unless every
    /// voter agrees and the lowest confidence is above the level.
    case min
    /// `options.py` `mean_judge`: the voters' P(new) averaged; flagged when max(m, 1 − m) is at or below the
    /// level. For one voter the two rules are the same.
    case mean
}

/// One approach, fully resolved: its voters, its rule and level, and the bench's window shape.
struct ApproachSpec: Sendable {
    let approach: SegmentationApproach
    let voters: [WindowVoter]
    let rule: WindowCombineRule
    let level: Double
    let windowPages: Int
    let windowStride: Int
    let thumbnailLongEdgePx: Int
    let ocrTextChars: Int
}

/// The provider a voter's model is reached through.
enum WindowProvider: String, Sendable {
    case anthropic, gemini, openai
}

/// A window voter: one model with one fixed prompt, exactly as the bench ran it. The app does not use the
/// global provider and model picker for these, because an approach fixes its models; that keeps the shipped
/// figures true.
struct WindowVoter: Sendable, Equatable {
    /// The bench's method name, the part of the options.json voter string before " (".
    let name: String
    let provider: WindowProvider
    let modelID: String
    /// Gemini `thinkingConfig.thinkingLevel`, as the bench sent it.
    let thinkingLevel: String?
    let prompt: WindowPromptID

    /// The voters the app can run. A voter in options.json that is not here (or whose prompt id differs)
    /// fails validation, so a bench change cannot silently run against the wrong prompt.
    static let catalog: [WindowVoter] = [
        WindowVoter(name: "window-claude", provider: .anthropic, modelID: "claude-sonnet-5-5",
                    thinkingLevel: nil, prompt: .w1),
        WindowVoter(name: "window-gemini-3.8-flash-low", provider: .gemini, modelID: "gemini-3.8-flash",
                    thinkingLevel: "low", prompt: .g1),
    ]

    struct ResolveError: Error, CustomStringConvertible {
        let description: String
    }

    /// Resolves an options.json voter string such as `window-claude (Claude Sonnet 5.5, prompt w1)`.
    static func resolve(_ text: String) -> Result<WindowVoter, ResolveError> {
        let name = text.components(separatedBy: " (").first ?? text
        guard let voter = catalog.first(where: { $0.name == name }) else {
            return .failure(ResolveError(description: "voter \(name) is not one the app can run"))
        }
        guard let range = text.range(of: #"prompt ([A-Za-z0-9]+)"#, options: .regularExpression) else {
            return .failure(ResolveError(description: "voter \(name) names no prompt id"))
        }
        let id = text[range].dropFirst("prompt ".count)
        guard id == voter.prompt.rawValue else {
            return .failure(ResolveError(description:
                "voter \(name): the file says prompt \(id), the app carries \(voter.prompt.rawValue)"))
        }
        return .success(voter)
    }
}
