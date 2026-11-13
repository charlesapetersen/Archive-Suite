import Foundation

// MARK: - The settings solver (W46.settings-solver)

/// What the user has, read by the general interview or detected (`12-settings-design.md` §3.1).
struct SettingsResources: Equatable, Sendable {
    /// This Mac's memory; a Mac route fits when its measured peak plus `headroomGB` does.
    var macMemoryGB: Double
    /// API keys, by the table's names: `gemini`, `openrouter`, `openai`, `mistral`, `anthropic`, `gateway`.
    var keys: Set<String> = []
    /// Signed-in plans: `claude`, `chatgpt`.
    var plans: Set<String> = []
    var cluster = false
    var gpusPerJob = 1
    /// The user accepts a model download to this Mac.
    var downloadsAllowed = true
    /// Model families the user will not send pages to, matched against route ids (`gemini`): a key that reaches a
    /// family through a router (OpenRouter reaches Gemini) is then not a way to it.
    var excludedModelFamilies: Set<String> = []

    /// The prototype's headroom for the rest of the Mac (`12-settings-design.md` §3.3).
    static let headroomGB = 5.0
}

/// What matters most, in the collection interview's order; the order becomes the stage weights.
enum SettingsPriority: String, CaseIterable, Sendable {
    case reading, findingDocuments, dates, names

    var stage: String {
        switch self {
        case .reading: return "reading"
        case .findingDocuments: return "segmentation"
        case .dates: return "dating"
        case .names: return "entities"
        }
    }
}

enum SettingsPreference: String, CaseIterable, Sendable {
    /// The best measured route; a tie under the stage's rule goes to the cheaper, then the faster.
    case bestMeasured
    /// A point of accuracy is traded for money: a gap under a point is a tie too.
    case cheapestWithinPoint
    /// A point of accuracy is traded for time.
    case fastestWithinPoint
}

/// Whether the user can run the training kit (the general interview).
enum FineTuningAnswer: String, CaseIterable, Sendable {
    case no, codingAgent, cluster
}

/// The collection interview's answers, defaulted as `13-profile-tests.md` §Conventions has them.
struct SettingsAnswers: Sendable {
    var pages = 1000
    /// Documents in the batch; nil reads as a third of the pages.
    var documents: Int?
    /// The document mix as shares by kind (`typewritten`, `printed`, `handwritten`, `forms`, `newspapers`, …),
    /// the owner's 96 unless measured.
    var mix: [String: Double] = ["typewritten": 50, "printed": 28, "handwritten": 16]
    /// Public strata the period, languages and scripts select (`L5` … `N6`), each read by its own leader, with its
    /// share of the pages on the mix's scale.
    var strata: [String: Double] = [:]
    /// The batch's money ceiling in dollars; nil is no ceiling.
    var ceilingUSD: Double?
    var hours: Double = 8
    var preference: SettingsPreference = .bestMeasured
    var priorities: [SettingsPriority] = SettingsPriority.allCases
    /// The collection interview's weights by stage, for the ranked priorities; empty is 45, 30, 15, 10 by position.
    var weights: [String: Double] = [:]
    /// The per-batch "stays on the Mac" switch (owner call 2): no page leaves this Mac.
    var staysOnMac = false
    /// A failed page goes on to another reader, so readers are ranked on answered pages; off, on strict NES.
    var readingFallback = true
    /// Minutes the user will spend checking boundaries.
    var checkingMinutes: Double = 0
    var fineTuning: FineTuningAnswer = .no
    var correctedLinesOneHand = 0
    var correctedGapsOneMaterial = 0
    var collectionHasTagsOrFolders = false
    /// A kit manifest past the gate sits beside the Mac build (`W46.kit-mac-build`).
    var kitMacBuild = false
    /// Only routes the app can run today (`app_route` set): what `SegmentationApproach.preferredDefault` asks.
    var appRoutesOnly = false
    /// The stages to solve; nil is every choice stage.
    var stagesToSolve: Set<String>?
    /// Rows a stage is restricted to (the router case of a tie chain); a stage not named keeps every row.
    var onlyRoutes: [String: Set<String>] = [:]

    var documentCount: Int { documents ?? max(1, (pages + 2) / 3) }

    /// A skipped interview is "Free, on this Mac", always (owner call 3): detected keys are listed, nothing is spent,
    /// and names are not ranked.
    static var skippedInterview: SettingsAnswers {
        var a = SettingsAnswers()
        a.staysOnMac = true
        a.ceilingUSD = 0
        a.priorities = [.reading, .findingDocuments, .dates]
        return a
    }
}

/// One stage's choice for one part of the batch: reading per kind or stratum, dating per step, names per kind.
struct SettingsPick: Sendable {
    let stage: String
    let part: String
    let route: SettingsRouteTable.Route?
    /// The figure the user sees for this part, on the stage's metric.
    let figure: Double?
    /// What happens instead when no route serves the part ("needs a download or a key", "no figure").
    let flag: String?
    /// One sentence naming the evidence row.
    let reason: String
    /// The pair entry a tie was read from.
    let gap: OCRPairMatrix.Gap?
    /// Up to four routes with a better figure, each with the one reason it is out.
    let better: [SettingsBetterRoute]
    /// The reader a failed page goes on to.
    let fallbackRouteID: String?
    /// Names: shown on the sheet (the collection ranks names); a cloud route extracts them regardless.
    let shown: Bool
    let usd: Double
    let hours: Double

    var routeID: String? { route?.id }
}

struct SettingsBetterRoute: Sendable {
    let id: String
    let figure: Double
    let reason: String
    /// The reason is a limit (the ceiling or the hours), so relaxing it would let the route in.
    let isLimit: Bool
}

/// An after-training point on the range view (note 12).
struct SettingsKitPoint: Sendable {
    let id: String
    let shown: Bool
    let selectable: Bool
    let reason: String
}

struct SettingsSolution: Sendable {
    let picks: [SettingsPick]
    /// Every row of each solved stage that cannot be used, with why (the hollow marks).
    let blocked: [String: [String: [String]]]
    let usd: Double
    let hours: Double
    let weightedAccuracy: Double?
    /// Which limit to relax and by how much, from the better routes a limit keeps out.
    let relax: [String]
    let afterTraining: [SettingsKitPoint]

    func pick(_ stage: String, _ part: String) -> SettingsPick? {
        picks.first { $0.stage == stage && $0.part == part }
    }

    func blockers(_ stage: String, _ id: String) -> [String] { blocked[stage]?[id] ?? [] }
}

/// Picks one route per stage and part from `settings-routes.json` for the answers given (`12-settings-design.md`
/// §3.3, the stage notes' section 3, `13-profile-tests.md`). Stages are solved in the order of their weights, each
/// taking the best route it can use within what the ceiling and the hours leave (the router case "spends on the stage
/// with the highest weight first"); a tie under the stage's rule is judged against the best usable route only and
/// goes to the cheaper, then the faster route, never chained. No route a stage cannot use is ever picked.
struct SettingsSolver {
    let table: SettingsRouteTable
    let pairs: OCRPairMatrix?
    let resources: SettingsResources
    let answers: SettingsAnswers

    /// The prototype's weights, given to the priorities in order (`12-settings-design.md` §4); an unranked stage
    /// weighs nothing but still runs.
    static let weights: [Double] = [45, 30, 15, 10]
    static let stageOrder = ["reading", "segmentation", "dating", "entities"]

    /// Ties in points of the stage metric. Reading reads its tie from the pair matrix (floor 0.49 hosted, 0 between
    /// Mac routes, 0.60 for hands) and falls back to these floors where a pair has no per-page scores.
    static let readingHostedFloor = 0.49
    static let readingHandsFloor = 0.60
    /// Segmentation, built as reading's is: twice the larger window-offset range of the two routes compared, in
    /// pooled test-box pages exact (`test-boxes.offset_range`), a route with no range taking the largest measured.
    /// Measured: Gemini 3.7 on g2 0.3 points, on g1 2.1 (`seg-g2-offsets.md`, `seg-boxes-score.md`); no other route
    /// has one, so every pair the table holds is twice 2.1 (W46.seg-g2-offsets; 07-segmentation.md §3). The test
    /// driver checks this against the table.
    static let segmentationTie = 4.2
    /// Dating: the rerun floor is the same year on 94% (85/90) of documents between identical runs, read as a gap of
    /// up to 6 points of exact year; reading the rate as points is the note's [I] (08-dating.md §3).
    static let datingTie = 6.0
    /// Names: an unpaired gap of a few points of F1 is noise (ENT-1 ruled 0.60 against 0.56 a tie).
    static let entitiesTie = 0.05

    func weight(_ stage: String) -> Double {
        guard let i = answers.priorities.firstIndex(where: { $0.stage == stage }) else { return 0 }
        if !answers.weights.isEmpty { return max(0, answers.weights[stage] ?? 0) }
        return i < Self.weights.count ? Self.weights[i] : 0
    }

    // MARK: Solve

    func solve() -> SettingsSolution {
        var state = SolveState(ceiling: answers.ceilingUSD ?? .infinity, hours: answers.hours)
        let stages = Self.stageOrder
            .filter { answers.stagesToSolve?.contains($0) ?? true }
            .sorted { weight($0) > weight($1) }   // stable: equal weights keep the default order
        var picks: [SettingsPick] = []
        var blocked: [String: [String: [String]]] = [:]
        for s in stages {
            guard let stage = table.stage(s) else { continue }
            var rows: [String: [String]] = [:]
            for r in stage.routes where !r.afterTraining {
                let b = blockers(r, stage: s)
                if !b.isEmpty { rows[r.id] = b }
            }
            blocked[s] = rows
            switch s {
            case "reading": picks += solveReading(stage, &state)
            case "segmentation": picks += solveSegmentation(stage, &state)
            case "dating": picks += solveDating(stage, &state)
            case "entities": picks += solveEntities(stage, &state)
            default: break
            }
        }
        picks.sort { (Self.stageOrder.firstIndex(of: $0.stage) ?? 9) < (Self.stageOrder.firstIndex(of: $1.stage) ?? 9) }
        var relax: [String] = []
        if state.wall > answers.hours + 1e-9 {
            relax.append("allow about \(Self.num(state.wall - answers.hours)) more hours: this batch needs about "
                         + "\(Self.num(state.wall)) on the cheapest usable routes")
        }
        if let c = answers.ceilingUSD, state.usd > c + 1e-9 {
            relax.append("raise the ceiling by $\(String(format: "%.2f", state.usd - c))")
        }
        for p in picks {
            for b in p.better where b.isLimit {
                let line = "\(b.reason) for \(b.id) (\(p.stage), \(p.part))"
                if !relax.contains(line) { relax.append(line) }
            }
        }
        return SettingsSolution(picks: picks, blocked: blocked, usd: state.usd, hours: state.wall,
                                weightedAccuracy: weightedAccuracy(picks), relax: relax,
                                afterTraining: kitPoints(picks))
    }

    // MARK: Feasibility

    struct Access {
        let viaPlan: Bool
        let viaKey: Bool
        let viaCluster: Bool
    }

    func access(_ r: SettingsRouteTable.Route) -> Access {
        let n = r.needs
        return Access(viaPlan: !n.plan.isEmpty && Set(n.plan).isSubset(of: resources.plans),
                      viaKey: !Set(n.key).isDisjoint(with: resources.keys),
                      viaCluster: n.cluster && resources.cluster && resources.gpusPerJob >= (n.gpus ?? 1))
    }

    /// Why a route cannot be used, in the sheet's words; empty when it can.
    func blockers(_ r: SettingsRouteTable.Route, stage: String) -> [String] {
        var out: [String] = []
        if let only = answers.onlyRoutes[stage], !only.contains(r.id) { out.append("not in this comparison") }
        if !r.offered, let c = r.conditions.first(where: { $0.hasPrefix("not offered") || $0.hasPrefix("never offered") }) {
            out.append(c)
        }
        // A cascade's condition is what it waits for in the app ("not built: …", "a Mac escalation stage in
        // OCRCascade"); a disagreement partner is not a voter alone (note 07).
        if r.stages != nil, let c = r.conditions.first { out.append("waits for: \(c)") }
        if let c = r.conditions.first(where: { $0.contains("not as a voter alone") }) { out.append(c) }
        // A family the user will not send pages to: only routes whose pages leave this Mac.
        if r.family != .mac && r.family != .manual {
            let text = ([r.id, r.name] + (r.stages ?? [])).joined(separator: " ").lowercased()
            if let fam = resources.excludedModelFamilies.sorted().first(where: { text.contains($0.lowercased()) }) {
                out.append("you chose not to send pages to \(fam.capitalized) models")
            }
        }
        if answers.appRoutesOnly && r.appRoute == nil { out.append("not in the app yet") }
        let n = r.needs
        if answers.staysOnMac && r.family != .mac && r.family != .manual {
            out.append("this batch stays on the Mac")
        } else if answers.staysOnMac && n.needsAccess && r.family == .mac {
            out.append("this batch stays on the Mac")   // a Mac-side cascade that escalates over the network
        } else if n.needsAccess {
            let a = access(r)
            if !(a.viaPlan || a.viaKey || a.viaCluster) {
                var ways: [String] = []
                if !n.key.isEmpty { ways.append("a " + n.key.map(Self.keyName).joined(separator: " or ") + " key") }
                if !n.plan.isEmpty {
                    ways.append("the " + n.plan.map { $0 == "claude" ? "Claude" : "ChatGPT" }.joined(separator: " and ")
                                + (n.plan.count > 1 ? " plans" : " plan"))
                }
                if n.cluster {
                    ways.append(resources.cluster && resources.gpusPerJob < (n.gpus ?? 1)
                                ? "\(n.gpus ?? 1) GPUs a job" : "a cluster")
                }
                out.append("needs " + ways.joined(separator: ", or "))
            }
        }
        if n.mac {
            if r.needsDownload && !resources.downloadsAllowed { out.append("needs a download") }
            if let peak = r.peakGB, peak > 0, peak + SettingsResources.headroomGB > resources.macMemoryGB {
                out.append("needs about \(Int((peak + SettingsResources.headroomGB).rounded(.up))) GB of memory ("
                           + "\(Self.num(peak)) GB measured)")
            }
            if let floor = n.macGB, resources.macMemoryGB < floor { out.append("needs a \(Int(floor)) GB Mac") }
        }
        return out
    }

    static func keyName(_ k: String) -> String {
        ["gemini": "Gemini", "openrouter": "OpenRouter", "openai": "OpenAI", "mistral": "Mistral",
         "anthropic": "Anthropic", "gateway": "Stanford gateway"][k] ?? k
    }

    // MARK: Money and time

    enum Bucket { case mac, net, cluster, none }

    struct SolveState {
        let ceiling: Double
        let hours: Double
        var usd = 0.0
        var mac = 0.0
        var net = 0.0
        var cluster = 0.0

        /// Mac stages run one after another; network calls overlap them; the cluster runs apart.
        var wall: Double { max(mac, net, cluster) }

        func adding(_ c: Cand) -> SolveState {
            var s = self
            s.usd += c.usd
            switch c.bucket {
            case .mac: s.mac += c.hours
            case .net: s.net += c.hours
            case .cluster: s.cluster += c.hours
            case .none: break
            }
            return s
        }

        func fits(_ c: Cand) -> Bool {
            let s = adding(c)
            return s.usd <= ceiling + 1e-9 && s.wall <= hours + 1e-9
        }

        mutating func add(_ c: Cand) { self = adding(c) }
    }

    /// A route priced and timed for one part of the batch.
    struct Cand {
        let route: SettingsRouteTable.Route
        let value: Double
        let usdPer1000: Double
        let usd: Double
        let hours: Double
        let bucket: Bucket
        let blockers: [String]
        var id: String { route.id }
    }

    func usdPer1000(_ r: SettingsRouteTable.Route, stage: String) -> Double {
        switch r.family {
        case .mac, .manual, .kit: return 0
        default: break
        }
        let a = access(r)
        if a.viaPlan || a.viaCluster { return 0 }   // a plan's usage and the user's cluster are not money
        // Overnight unlocks batch prices for reading; the segmentation engine sends every window interactively
        // (`SegmentationRow.make`), so its batch figure is not a price the app pays.
        if stage == "reading", answers.hours >= 24, let batch = r.batchUSDPer1000 { return batch }
        return r.listUSDPer1000 ?? 0
    }

    func bucket(_ r: SettingsRouteTable.Route) -> Bucket {
        let a = access(r)
        switch r.family {
        case .manual, .kit: return .none
        case .mac: return .mac
        case .cluster: return a.viaCluster ? .cluster : .net
        case .cloud, .plan: return .net
        }
    }

    func hours(_ r: SettingsRouteTable.Route, units: Double) -> Double {
        // A cascade reads every page with its first reader at least; its own time is not tabulated.
        if r.secondsPerUnit == nil, r.pagesPerHourPerGPUSet == nil, let first = r.stages?.first,
           let row = table.stage("reading")?.route(first), row.stages == nil {
            return hours(row, units: units)
        }
        switch bucket(r) {
        case .none: return 0
        case .mac: return (r.secondsPerUnit ?? 0) * units / 3600
        case .net: return (r.secondsPerUnit ?? 0) * units / 3 / 3600   // three calls at once, as the prototype
        case .cluster:
            if let pph = r.pagesPerHourPerGPUSet, pph > 0 { return units / pph }
            return (r.secondsPerUnit ?? 0) * units / 3600
        }
    }

    func cand(_ r: SettingsRouteTable.Route, stage: String, value: Double, units: Double,
              minus base: Cand? = nil, baseUnits: Double = 0) -> Cand {
        let per = usdPer1000(r, stage: stage)
        var usd = per * units / 1000
        var h = hours(r, units: units)
        var bucket = bucket(r)
        if let base {
            // A part read by its own route instead of the stage's main one gives that route's share back.
            usd -= base.usdPer1000 * baseUnits / 1000
            if base.bucket == bucket { h -= hours(base.route, units: baseUnits) }
            if base.id == r.id { usd = 0; h = 0; bucket = .none }
        }
        return Cand(route: r, value: value, usdPer1000: per, usd: usd, hours: h, bucket: bucket,
                    blockers: blockers(r, stage: stage))
    }

    // MARK: Choosing

    struct Choice {
        let pick: Cand
        let best: Cand
        let pool: [Cand]
        let overLimits: Bool
    }

    /// The best usable candidate within the limits, then the cheaper (or faster) of it and those tied with it.
    func choose(_ cands: [Cand], _ state: SolveState, tie: (Cand, Cand) -> Bool,
                prefer: (Cand, Cand) -> Bool) -> Choice? {
        let feasible = cands.filter { $0.blockers.isEmpty }
        let within = feasible.filter { state.fits($0) }
        guard !within.isEmpty else {
            // Nothing fits the ceiling and the hours: the cheapest usable route, then the fastest (the prototype's
            // fallback), and the better routes say which limit to relax.
            guard let c = feasible.min(by: { ($0.usd, $0.hours) < ($1.usd, $1.hours) }) else { return nil }
            return Choice(pick: c, best: c, pool: [c], overLimits: true)
        }
        let best = within.max { a, b in
            a.value != b.value ? a.value < b.value : (a.usd, a.hours) > (b.usd, b.hours)
        }!
        let pool = [best] + within.filter { $0.id != best.id && tie($0, best) }
        let pick = pool.min { prefer($0, $1) }!
        return Choice(pick: pick, best: best, pool: pool, overLimits: false)
    }

    func defaultPrefer(_ a: Cand, _ b: Cand) -> Bool {
        if answers.preference == .fastestWithinPoint {
            if a.hours != b.hours { return a.hours < b.hours }
            return a.usd < b.usd
        }
        if abs(a.usd - b.usd) > 1e-9 { return a.usd < b.usd }
        return a.hours < b.hours
    }

    /// A gap under a point is a tie too when the user trades a point for money or time.
    var withinPoint: Double { answers.preference == .bestMeasured ? 0 : 1.0 }

    func betterRoutes(_ cands: [Cand], than choice: Choice?, pickValue: Double?, state: SolveState,
                      extraReason: ((Cand) -> String?)? = nil) -> [SettingsBetterRoute] {
        let pool = Set(choice?.pool.map(\.id) ?? [])
        let floor = pickValue ?? -Double.infinity
        let out = cands
            .filter { $0.value > floor + 1e-9 && !pool.contains($0.id) }
            .sorted { $0.value > $1.value }
            .map { c in
                if let b = c.blockers.first { return SettingsBetterRoute(id: c.id, figure: c.value, reason: b, isLimit: false) }
                if let r = extraReason?(c) { return SettingsBetterRoute(id: c.id, figure: c.value, reason: r, isLimit: false) }
                let after = state.adding(c)
                if after.usd > state.ceiling + 1e-9 {
                    let short = c.usd - (state.ceiling - state.usd)
                    return SettingsBetterRoute(id: c.id, figure: c.value,
                                               reason: "raise the ceiling by $\(String(format: "%.2f", short))",
                                               isLimit: true)
                }
                if after.wall > state.hours + 1e-9 {
                    return SettingsBetterRoute(id: c.id, figure: c.value,
                                               reason: "allow about \(Self.num(after.wall - state.hours)) more hours",
                                               isLimit: true)
                }
                return SettingsBetterRoute(id: c.id, figure: c.value, reason: "ties the pick and costs more or is slower",
                                           isLimit: false)
            }
        // A route a limit keeps out comes first: relaxing the limit is the one change that lets it in.
        return Array((out.filter(\.isLimit) + out.filter { !$0.isLimit }).prefix(4))
    }

    /// One sentence naming the evidence row.
    func explain(_ choice: Choice, metric: String, unit: String, gap: OCRPairMatrix.Gap?, tieText: String? = nil,
                 tieWhy: ((Cand, Cand) -> String?)? = nil) -> String {
        let p = choice.pick
        let head = "\(p.route.name) (\(p.id))"
        if choice.overLimits {
            return "\(head): no route fits the ceiling and the hours together, so the cheapest usable one is used "
                + "(\(metric) \(Self.num(p.value)))."
        }
        if p.id == choice.best.id {
            let next = choice.pool.count > 1 ? ", and the routes tied with it cost more or are slower" : ""
            return "\(head) is the best route this batch can use, \(metric) \(Self.num(p.value))\(next)."
        }
        let b = choice.best
        let why: String
        if abs(p.usd - b.usd) > 1e-9 {
            why = "cheaper, \(Self.money(p.usdPer1000)) against \(Self.money(b.usdPer1000)) per 1,000 \(unit)"
        } else if p.hours != b.hours {
            why = "faster"
        } else if let w = tieWhy?(p, b) {
            why = w
        } else {
            why = "preferred by the stage's tie order"
        }
        let evidence = gap.map { "\($0.citation), under the \(Self.num($0.floor)) floor" }
            ?? tieText ?? "\(metric) \(Self.num(p.value)) against \(Self.num(b.value))"
        return "\(head) ties the best usable route, \(b.id) (\(evidence)), and is \(why)."
    }

    static func num(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e6 ? String(format: "%.0f", x) : String(format: "%.2f", x)
            .replacingOccurrences(of: #"0$"#, with: "", options: .regularExpression)
    }

    static func money(_ x: Double) -> String { x == 0 ? "$0" : String(format: "$%.2f", x) }

    // MARK: Reading

    func solveReading(_ stage: SettingsRouteTable.Stage, _ state: inout SolveState) -> [SettingsPick] {
        let score = answers.readingFallback ? "answered" : "strict"
        let pages = Double(answers.pages)
        let rows = stage.routes.filter { !$0.afterTraining && $0.id != "apple-fm-27" }   // rule no-apple-fm
        let singles = rows.filter { $0.stages == nil }
        let cascades = rows.filter { $0.stages != nil }
        func overall(_ r: SettingsRouteTable.Route) -> Double? {
            score == "answered" ? r.figure("overall") : r.strict("overall")
        }
        // The free default (owner call 4): when nothing but this Mac can read, typed and printed pages go to Apple
        // Vision and handwriting to a downloaded hand reader, else it is flagged.
        let free = !singles.contains { r in
            guard r.family != .mac, let v = overall(r) else { return false }
            let c = cand(r, stage: "reading", value: v, units: pages)
            return c.blockers.isEmpty && state.fits(c)
        }

        func readingTie(_ x: Cand, _ best: Cand, group: String, score: String, hands: Bool) -> (Bool, OCRPairMatrix.Gap?) {
            if let g = pairs?.gap("owner96", group, x.id, best.id, score: score) {
                return (g.underFloor || abs(g.delta) < withinPoint, g)
            }
            // No per-page scores: the floor alone ("pair not measured").
            let bothMac = x.route.family == .mac && best.route.family == .mac
            let floor = bothMac ? 0 : (hands ? Self.readingHandsFloor : Self.readingHostedFloor)
            return (abs(x.value - best.value) < max(floor, withinPoint), nil)
        }

        var out: [SettingsPick] = []
        let share = answers.mix.values.reduce(0, +) + answers.strata.values.reduce(0, +)
        func pagesOf(_ kind: String) -> Double { share > 0 ? pages * (answers.mix[kind] ?? 0) / share : 0 }

        // The batch's reader, for every page no kind rule sends elsewhere.
        var main: Cand?
        var mainGap: OCRPairMatrix.Gap?
        var mainReason = ""
        var mainBetter: [SettingsBetterRoute] = []
        var fallbackID: String?
        let mainCands = singles.compactMap { r in overall(r).map { cand(r, stage: "reading", value: $0, units: pages) } }
        if free, let vision = stage.route("apple-vision"), blockers(vision, stage: "reading").isEmpty {
            let c = cand(vision, stage: "reading", value: overall(vision) ?? 0, units: pages)
            main = c
            mainReason = "Apple Vision (apple-vision) is the free default for typed and printed pages on this Mac "
                + "(owner call 4): \(Self.num(vision.figure("typewritten") ?? 0)) typewritten and "
                + "\(Self.num(vision.figure("printed") ?? 0)) printed strict on owner96."
            mainBetter = betterRoutes(mainCands, than: nil, pickValue: c.value, state: state) { _ in
                "the free default reads typed and printed pages with Apple Vision (owner call 4)"
            }
        } else if let ch = choose(mainCands, state, tie: { readingTie($0, $1, group: "all", score: score, hands: false).0 },
                                  prefer: defaultPrefer) {
            var chosen = ch
            mainGap = ch.pick.id == ch.best.id ? nil
                : readingTie(ch.pick, ch.best, group: "all", score: score, hands: false).1
            mainReason = explain(ch, metric: "owner96 all \(score)", unit: "pages", gap: mainGap)
            // A measured cascade is a route, picked when it beats the single pick by more than the floor (no per-page
            // scores, so the floor alone).
            let cc = cascades.compactMap { r in r.figure("overall").map { cand(r, stage: "reading", value: $0, units: pages) } }
                .filter { $0.blockers.isEmpty && state.fits($0) && $0.value > ch.best.value + Self.readingHostedFloor }
            if let top = cc.max(by: { $0.value < $1.value }) {
                chosen = Choice(pick: top, best: top, pool: [top], overLimits: false)
                mainGap = nil
                mainReason = "\(top.route.name) (\(top.id)), a measured cascade, beats the best single route "
                    + "\(ch.best.id) by more than the \(Self.num(Self.readingHostedFloor)) floor: "
                    + "\(Self.num(top.value)) against \(Self.num(ch.best.value))."
            }
            main = chosen.pick
            mainBetter = betterRoutes(mainCands, than: chosen, pickValue: chosen.pick.value, state: state)
            // Its failed pages go on to the best other usable route (the cascade row's second reader).
            if answers.readingFallback, chosen.pick.route.stages == nil,
               case .object(let f)? = chosen.pick.route.figures["overall"]?["failures"], !f.isEmpty {
                fallbackID = chosen.best.id != chosen.pick.id ? chosen.best.id
                    : mainCands.filter { $0.blockers.isEmpty && $0.id != chosen.pick.id && state.fits($0) }
                        .max { $0.value < $1.value }?.id
            }
        }
        guard let main else {
            return [SettingsPick(stage: "reading", part: "all", route: nil, figure: nil, flag: "no reader",
                                 reason: "No reading route can run here.", gap: nil, better: [], fallbackRouteID: nil,
                                 shown: true, usd: 0, hours: 0)]
        }
        state.add(main)
        out.append(SettingsPick(stage: "reading", part: "all", route: main.route, figure: main.value, flag: nil,
                                reason: mainReason, gap: mainGap, better: mainBetter, fallbackRouteID: fallbackID,
                                shown: true, usd: main.usd, hours: main.hours))
        for kind in ["typewritten", "printed"] where (answers.mix[kind] ?? 0) > 0 {
            out.append(SettingsPick(stage: "reading", part: kind, route: main.route, figure: main.route.figure(kind) ?? main.value,
                                    flag: nil, reason: mainReason, gap: mainGap, better: mainBetter,
                                    fallbackRouteID: fallbackID, shown: true, usd: 0, hours: 0))
        }

        // Handwriting: ranked on hands16; among the routes tied with its leader the public L1-L3, an independent
        // truth, decides where they read it (rule hands-ranked-on-hands16, OCR-1).
        if (answers.mix["handwritten"] ?? 0) > 0 {
            let hp = pagesOf("handwritten")
            let hc = singles.filter { $0.id != "apple-vision" }   // handwriting is flagged, never read at 60 (owner call 4)
                .compactMap { r in r.figure("hands16").map { cand(r, stage: "reading", value: $0, units: hp, minus: main, baseUnits: hp) } }
            if let ch = choose(hc, state, tie: { readingTie($0, $1, group: "hands16", score: "strict", hands: true).0 },
                               prefer: defaultPrefer), !ch.overLimits {
                var pick = ch.pick
                var reason: String
                var gap = pick.id == ch.best.id ? nil : readingTie(pick, ch.best, group: "hands16", score: "strict", hands: true).1
                let pub = ch.pool.filter { $0.route.publicStrict("L1-L3") != nil }
                if ch.pool.count > 1, let lead = pub.max(by: { $0.route.publicStrict("L1-L3")! < $1.route.publicStrict("L1-L3")! }) {
                    pick = lead
                    let runner = pub.filter { $0.id != lead.id }.max { $0.route.publicStrict("L1-L3")! < $1.route.publicStrict("L1-L3")! }
                    gap = runner.flatMap { pairs?.gap("public895", "L1-L3", lead.id, $0.id, score: "strict") }
                    reason = "\(lead.route.name) (\(lead.id)) ties the hands16 leader \(ch.best.id) and leads the "
                        + "independent public895 L1-L3 at \(Self.num(lead.route.publicStrict("L1-L3")!))"
                        + (gap.map { " (\($0.citation) against \(runner!.id))" } ?? "") + ", which decides."
                } else {
                    reason = explain(ch, metric: "owner96 hands16 strict", unit: "pages", gap: gap)
                }
                let before = state
                state.add(pick)
                out.append(SettingsPick(stage: "reading", part: "handwritten", route: pick.route, figure: pick.value,
                                        flag: nil, reason: reason, gap: gap,
                                        better: betterRoutes(hc, than: ch, pickValue: pick.value, state: before),
                                        fallbackRouteID: nil, shown: true, usd: pick.usd, hours: pick.hours))
            } else {
                out.append(SettingsPick(stage: "reading", part: "handwritten", route: nil, figure: nil,
                                        flag: "needs a download or a key",
                                        reason: "No hand reader fits this Mac and its limits, so handwritten pages are "
                                            + "flagged \"needs a download or a key\", never read by Apple Vision at "
                                            + "\(Self.num(stage.route("apple-vision")?.figure("hands16") ?? 0)) (owner call 4).",
                                        gap: nil, better: betterRoutes(hc, than: nil, pickValue: nil, state: state),
                                        fallbackRouteID: nil, shown: true, usd: 0, hours: 0))
            }
        }

        // Public strata: a kind measured only on the 895 (forms L4, newspapers L9) and the strata the collection's
        // period, languages and scripts select; a pick takes the stratum's leader (owner, 2026-11-11).
        var strata: [(String, Double)] = []
        for (kind, list) in stage.kindStrata.sorted(by: { $0.key < $1.key })
        where list.count == 1 && (answers.mix[kind] ?? 0) > 0 && kind != "handwritten" {
            strata.append((list[0], pagesOf(kind)))
        }
        for (s, x) in answers.strata.sorted(by: { $0.key < $1.key }) where !strata.contains(where: { $0.0 == s }) {
            strata.append((s, share > 0 ? pages * x / share : 0))
        }
        for (s, sp) in strata {
            let sc = singles
                .filter { !(s.hasPrefix("N") && $0.id == "apple-vision") }   // rule nonlatin-not-vision
                .compactMap { r in r.publicStrict(s).map { cand(r, stage: "reading", value: $0, units: sp, minus: main, baseUnits: sp) } }
            let usable = sc.filter { $0.blockers.isEmpty && state.fits($0) }
            if let lead = usable.max(by: { $0.value < $1.value }) {
                let runner = usable.filter { $0.id != lead.id }.max { $0.value < $1.value }
                let gap = runner.flatMap { pairs?.gap("public895", s, lead.id, $0.id, score: "strict") }
                let reason = "\(lead.route.name) (\(lead.id)) leads public895 \(s) strict among the routes this batch "
                    + "can use, \(Self.num(lead.value))" + (gap.map { " (\($0.citation) against \(runner!.id))" } ?? "") + "."
                let before = state
                state.add(lead)
                out.append(SettingsPick(stage: "reading", part: s, route: lead.route, figure: lead.value, flag: nil,
                                        reason: reason, gap: gap,
                                        better: betterRoutes(sc, than: Choice(pick: lead, best: lead, pool: [lead], overLimits: false),
                                                             pickValue: lead.value, state: before),
                                        fallbackRouteID: nil, shown: true, usd: lead.usd, hours: lead.hours))
            } else {
                out.append(SettingsPick(stage: "reading", part: s, route: main.route, figure: nil, flag: "no figure",
                                        reason: "No route this batch can use was scored on public895 \(s), so "
                                            + "\(main.route.name) (\(main.id)) reads it and its card shows \"no figure\" "
                                            + "for \(s) beside its overall \(Self.num(main.value)), never a borrowed one.",
                                        gap: nil, better: betterRoutes(sc, than: nil, pickValue: nil, state: state),
                                        fallbackRouteID: nil, shown: true, usd: 0, hours: 0))
            }
        }
        return out
    }

    // MARK: Segmentation

    func segmentationFigure(_ r: SettingsRouteTable.Route) -> Double? {
        r.figure("test-boxes") ?? (r.family == .manual ? 0 : nil)   // by hand nothing is found until a gap is checked
    }

    /// The figure a user sees: the no-checking figure moved toward the after-checking one by the share of the needed
    /// checks their minutes cover, at 20 s a boundary (an assumption to measure, `W46.seg-check-time`).
    func segmentationShown(_ r: SettingsRouteTable.Route) -> Double? {
        guard let base = segmentationFigure(r) else { return nil }
        guard let after = r.figure("test-boxes.after_checking"), let per100 = r.figure("test-boxes.checks_per_100"),
              per100 > 0 else { return base }
        let needed = per100 * Double(answers.pages) / 100
        let can = answers.checkingMinutes * 60 / 20
        return base + (after - base) * min(1, can / needed)
    }

    func solveSegmentation(_ stage: SettingsRouteTable.Stage, _ state: inout SolveState) -> [SettingsPick] {
        let pages = Double(answers.pages)
        let chosen = answers.onlyRoutes["segmentation"] ?? []
        let cands = stage.routes.filter { !$0.afterTraining && (!$0.userChoiceOnly || chosen.contains($0.id)) }
            .compactMap { r in segmentationFigure(r).map { cand(r, stage: "segmentation", value: $0, units: pages) } }
        let tie = max(Self.segmentationTie, withinPoint)
        guard let ch = choose(cands, state, tie: { abs($0.value - $1.value) < tie }, prefer: { a, b in
            if abs(a.usd - b.usd) > 1e-9 || a.hours != b.hours { return defaultPrefer(a, b) }
            if a.value != b.value { return a.value > b.value }
            // Equal cost, time and figure: the fewer checks a user is asked for.
            return (a.route.figure("test-boxes.checks_per_100") ?? 100) < (b.route.figure("test-boxes.checks_per_100") ?? 100)
        }) else { return [] }
        let before = state
        state.add(ch.pick)
        return [SettingsPick(stage: "segmentation", part: "all", route: ch.pick.route,
                             figure: segmentationShown(ch.pick.route), flag: nil,
                             reason: explain(ch, metric: "test-boxes pages exact", unit: "pages", gap: nil,
                                             tieText: "test-boxes \(Self.num(ch.pick.value)) against "
                                                + "\(Self.num(ch.best.value)), under the \(Self.num(tie))-point floor"),
                             gap: nil, better: betterRoutes(cands, than: ch, pickValue: ch.pick.value, state: before),
                             fallbackRouteID: nil, shown: true, usd: ch.pick.usd, hours: ch.pick.hours)]
    }

    // MARK: Dating

    func solveDating(_ stage: SettingsRouteTable.Stage, _ state: inout SolveState) -> [SettingsPick] {
        let docs = Double(answers.documentCount)
        var used: [String: Cand] = [:]
        var out: [SettingsPick] = []
        for step in [1, 2, 4] {
            let key = step == 2 ? "unprinted_122_doc_year" : "not_in_text"
            let rows = stage.routes.filter { ($0.step ?? []).contains(step) }
                // Step 4 writes a year only with checked evidence, so it is a trace row (no-untraceable-guess).
                .filter { step != 4 || $0.figures["evidence_valid"] != nil }
            let cands = rows.compactMap { r -> Cand? in
                guard let v = r.figure(key) else { return nil }
                if let u = used[r.id] {   // the same route serving an earlier step costs nothing more
                    return Cand(route: r, value: v, usdPer1000: u.usdPer1000, usd: 0, hours: 0, bucket: .none,
                                blockers: u.blockers)
                }
                return cand(r, stage: "dating", value: v, units: docs)
            }
            let tie = max(Self.datingTie, withinPoint)
            let ch = choose(cands, state, tie: { abs($0.value - $1.value) <= tie + 1e-9 }, prefer: { a, b in
                // A tie goes to the route whose years carry evidence, then the cheaper, then in-text, then the faster.
                let ea = a.route.figures["evidence_valid"] != nil, eb = b.route.figures["evidence_valid"] != nil
                if ea != eb { return ea }
                if abs(a.usd - b.usd) > 1e-9 { return a.usd < b.usd }
                let ia = a.route.figure("in_text") ?? 0, ib = b.route.figure("in_text") ?? 0
                if ia != ib { return ia > ib }
                return a.hours < b.hours
            })
            let part = "step \(step)"
            guard let ch else {
                let flag = step == 2 ? "no image pass; the document goes on to step 4"
                    : step == 4 ? "propagation: the nearest earlier dated document, at most three back (t=3)"
                    : "no year from the text"
                out.append(SettingsPick(stage: "dating", part: part, route: nil, figure: nil, flag: flag,
                                        reason: "No dating route serves \(part) here: \(flag).", gap: nil,
                                        better: betterRoutes(cands, than: nil, pickValue: nil, state: state),
                                        fallbackRouteID: nil, shown: true, usd: 0, hours: 0))
                continue
            }
            let before = state
            state.add(ch.pick)
            used[ch.pick.id] = ch.pick
            let reason = explain(ch, metric: key.replacingOccurrences(of: "_", with: " "), unit: "documents", gap: nil,
                                 tieText: "\(key) \(Self.num(ch.pick.value)) against \(Self.num(ch.best.value)), "
                                    + "inside the rerun floor") { p, b in
                if (p.route.figures["evidence_valid"] != nil) != (b.route.figures["evidence_valid"] != nil) {
                    return "its years carry checked evidence"
                }
                guard let ip = p.route.figure("in_text"), let ib = b.route.figure("in_text"), ip != ib else { return nil }
                return "better where the year is in the text, \(Self.num(ip)) against \(Self.num(ib))"
            }
            out.append(SettingsPick(stage: "dating", part: part, route: ch.pick.route, figure: ch.pick.value, flag: nil,
                                    reason: reason, gap: nil,
                                    better: betterRoutes(cands, than: ch, pickValue: ch.pick.value, state: before),
                                    fallbackRouteID: nil, shown: true, usd: ch.pick.usd, hours: ch.pick.hours))
        }
        return out
    }

    // MARK: Names

    func solveEntities(_ stage: SettingsRouteTable.Stage, _ state: inout SolveState) -> [SettingsPick] {
        let docs = Double(answers.documentCount)
        let ranked = answers.priorities.contains(.names)
        // On the Mac the local extractor runs only when names are ranked; a cloud route extracts them with its call
        // and shows them when ranked (owner call 11, rule ent-run).
        // `none` is always there, at 0, so a batch whose limits leave no time for names runs without them.
        let cands = stage.routes.filter { ranked || $0.family != .mac }
            .compactMap { r in (r.figure("sender") ?? (r.id == "none" ? 0 : nil)).map { cand(r, stage: "entities", value: $0, units: docs) } }
        let tie = max(Self.entitiesTie, withinPoint / 100)
        guard let ch = choose(cands, state, tie: { abs($0.value - $1.value) <= tie + 1e-9 }, prefer: defaultPrefer)
        else {
            let why = ranked ? "no names route can run here" : "names are not ranked, and on this Mac they are read only when they are (owner call 11)"
            return ["correspondence-typed", "correspondence-handwritten", "non-correspondence"].map {
                SettingsPick(stage: "entities", part: $0, route: nil, figure: nil, flag: "none",
                             reason: "No names: \(why).", gap: nil,
                             better: $0 == "correspondence-typed" ? betterRoutes(cands, than: nil, pickValue: nil, state: state) : [],
                             fallbackRouteID: nil, shown: ranked, usd: 0, hours: 0)
            }
        }
        if ch.pick.id == "none" {
            let why = ranked ? "no names route fits this batch" : "names are not ranked, and on this Mac they are read only when they are (owner call 11)"
            return ["correspondence-typed", "correspondence-handwritten", "non-correspondence"].map {
                SettingsPick(stage: "entities", part: $0, route: ch.pick.route, figure: nil, flag: "none",
                             reason: "No names (none): \(why).", gap: nil,
                             better: $0 == "correspondence-typed" ? betterRoutes(cands, than: ch, pickValue: 0, state: state) : [],
                             fallbackRouteID: nil, shown: ranked, usd: 0, hours: 0)
            }
        }
        let better = betterRoutes(cands, than: ch, pickValue: ch.pick.value, state: state)
        state.add(ch.pick)
        let reason = explain(ch, metric: "sender ed2 F1", unit: "documents", gap: nil,
                             tieText: "sender \(Self.num(ch.pick.value)) against \(Self.num(ch.best.value)), "
                                + "inside the few points ENT-1 rules a tie")
        let mac = ch.pick.route.family == .mac
        return [
            SettingsPick(stage: "entities", part: "correspondence-typed", route: ch.pick.route, figure: ch.pick.value,
                         flag: nil, reason: reason, gap: nil, better: better, fallbackRouteID: nil, shown: ranked,
                         usd: ch.pick.usd, hours: ch.pick.hours),
            mac
                ? SettingsPick(stage: "entities", part: "correspondence-handwritten", route: nil, figure: nil, flag: "none",
                               reason: "\(ch.pick.route.name) (\(ch.pick.id)) reads names from Vision text here, which is "
                                + "never used on handwriting (rule ent-vision-hands).",
                               gap: nil, better: [], fallbackRouteID: nil, shown: ranked, usd: 0, hours: 0)
                : SettingsPick(stage: "entities", part: "correspondence-handwritten", route: ch.pick.route,
                               figure: ch.pick.value, flag: nil, reason: reason, gap: nil, better: better,
                               fallbackRouteID: nil, shown: ranked, usd: 0, hours: 0),
            SettingsPick(stage: "entities", part: "non-correspondence", route: nil, figure: nil, flag: "none",
                         reason: "Names run on correspondence only; elsewhere they are unmeasured (rule "
                            + "ent-correspondence-only).",
                         gap: nil, better: [], fallbackRouteID: nil, shown: ranked, usd: 0, hours: 0),
        ]
    }

    // MARK: Totals and the kit

    func weightedAccuracy(_ picks: [SettingsPick]) -> Double? {
        var sum = 0.0, w = 0.0
        func add(_ stage: String, _ v: Double?) {
            guard let v else { return }
            let wt = weight(stage)
            sum += wt * v; w += wt
        }
        let share = answers.mix.filter { ["typewritten", "printed", "handwritten"].contains($0.key) }
        let total = share.values.reduce(0, +)
        if total > 0 {
            var r = 0.0
            for (k, s) in share {
                let v = picks.first { $0.stage == "reading" && $0.part == k }?.figure ?? 0
                r += v * s / total
            }
            add("reading", r)
        }
        add("segmentation", picks.first { $0.stage == "segmentation" }?.figure)
        add("dating", picks.first { $0.stage == "dating" && $0.part == "step 1" }?.figure)
        add("entities", picks.first { $0.stage == "entities" && $0.part == "correspondence-typed" }?.figure.map { $0 * 100 })
        return w > 0 ? sum / w : nil
    }

    /// The kit's after-training points, by the fine-tuning answer (note 12 §3, `13-profile-tests.md` F).
    func kitPoints(_ picks: [SettingsPick]) -> [SettingsKitPoint] {
        guard answers.fineTuning != .no, let kit = table.stage("training-kit") else { return [] }
        var out: [SettingsKitPoint] = []
        if kit.route("kit-hands-ppocrv6-ft") != nil {
            let hand = picks.first { $0.stage == "reading" && $0.part == "handwritten" }?.routeID
            let onKraken = hand == "ppocrv6-kraken-blla"
            let lines = answers.correctedLinesOneHand
            out.append(SettingsKitPoint(
                id: "kit-hands-ppocrv6-ft", shown: onKraken && lines >= 80, selectable: false,
                reason: !onKraken ? "shown only where the handwriting reader is kraken PP-OCRv6"
                    : lines < 80 ? "needs 80 corrected lines of one hand (\(lines) so far; target 160)"
                    : "after training on \(lines) corrected lines of one hand (target 160; +2.50 at 160 on one hand)"))
        }
        if kit.route("kit-seg-lora-mac") != nil {
            out.append(SettingsKitPoint(id: "kit-seg-lora-mac", shown: true, selectable: false,
                                        reason: "not offered: not measured to fit"))
        }
        if answers.fineTuning == .cluster {
            let gate = answers.kitMacBuild ? nil : "needs the Mac build step"
            if kit.route("kit-seg-student-tags") != nil {
                out.append(SettingsKitPoint(
                    id: "kit-seg-student-tags", shown: answers.collectionHasTagsOrFolders,
                    selectable: answers.collectionHasTagsOrFolders && gate == nil,
                    reason: !answers.collectionHasTagsOrFolders ? "shown when the collection has tags or per-document folders"
                        : gate ?? "after training on the collection's own tags"))
            }
            if kit.route("seg-2b-lora-k200") != nil {
                let gaps = answers.correctedGapsOneMaterial
                out.append(SettingsKitPoint(
                    id: "seg-2b-lora-k200", shown: gaps >= 200, selectable: gaps >= 200 && gate == nil,
                    reason: gaps < 200 ? "needs 200 corrected gaps of one material (\(gaps) so far)"
                        : gate ?? "the next boxes of this material, flagging kept on"))
            }
        }
        return out
    }
}
