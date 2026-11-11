import Foundation

// MARK: - The settings rule table (W46.settings-solver)

/// A JSON value. The rule table's figures change shape by stage (a number with its n, a pair of strings, a block of
/// public strata), so a route keeps them as values and the solver reads only the keys it ranks on.
enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var double: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

/// `segbench-results/settings-routes.json`, written by `scripts/segbench/settings_routes.py` from the bench's result
/// files and bundled straight from there (`project.yml`), so a rebuilt table reaches the app on its next build. The
/// schema is `execution-plans/processing-review/13-stage-rules/00-index.md` §"The table schema".
struct SettingsRouteTable: Decodable, Sendable {
    static let supportedVersions: Set<Int> = [1]
    static let resourceName = "settings-routes"

    let version: Int
    let built: String
    let stages: [Stage]

    struct Stage: Decodable, Sendable {
        let id: String
        let name: String
        let unit: String
        let choice: Bool
        let kinds: [String]
        /// Reading: the public strata each kind is scored on (`forms` → L4, `newspapers` → L9), beside its `source`.
        let kindStrataTable: [String: JSONValue]?
        let fallback: String?
        let routes: [Route]

        enum CodingKeys: String, CodingKey {
            case id, name, unit, choice, kinds, fallback, routes
            case kindStrataTable = "kind_strata"
        }

        var kindStrata: [String: [String]] {
            (kindStrataTable ?? [:]).compactMapValues { v in
                v.array?.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            }
        }

        func route(_ id: String) -> Route? { routes.first { $0.id == id } }
    }

    enum Family: String, Decodable, Sendable {
        case mac, cloud, plan, cluster, manual, kit
    }

    /// What a route needs. Access is any one of a key in `key`, every plan in `plan`, or `cluster`; a row with none of
    /// the three runs on the Mac alone. `mac` means it runs on this Mac, so its memory has to fit.
    struct Needs: Decodable, Sendable, Equatable {
        let key: [String]
        let plan: [String]
        let cluster: Bool
        let gpus: Int?
        let mac: Bool
        let macGB: Double?
        let builtIn: Bool

        enum CodingKeys: String, CodingKey {
            case key, plan, cluster, gpus, mac
            case macGB = "mac_gb"
            case builtIn = "built_in"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decodeIfPresent([String].self, forKey: .key) ?? []
            plan = try c.decodeIfPresent([String].self, forKey: .plan) ?? []
            cluster = try c.decodeIfPresent(Bool.self, forKey: .cluster) ?? false
            gpus = try c.decodeIfPresent(Int.self, forKey: .gpus)
            mac = try c.decodeIfPresent(Bool.self, forKey: .mac) ?? false
            macGB = try c.decodeIfPresent(Double.self, forKey: .macGB)
            builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
        }

        /// The route is reached some other way than this Mac alone.
        var needsAccess: Bool { !key.isEmpty || !plan.isEmpty || cluster }
    }

    struct Route: Decodable, Sendable {
        let id: String
        let name: String
        let family: Family
        /// The Processor's `provider|model` id when the app offers this route; nil when it does not yet.
        let appRoute: String?
        let status: String
        let needs: Needs
        let figures: [String: JSONValue]
        let cost: JSONValue?
        let time: JSONValue?
        let memory: JSONValue?
        let caveats: [String]
        let kindRules: [String]
        let fallback: String?
        let conditions: [String]
        /// Dating: the pipeline steps the route serves.
        let step: [Int]?
        /// A cascade: its readers in order, and what sends a page on.
        let stages: [String]?
        let trigger: String?

        enum CodingKeys: String, CodingKey {
            case id, name, family, status, needs, figures, cost, time, memory, caveats, fallback, conditions, step
            case stages, trigger
            case appRoute = "app_route"
            case kindRules = "kind_rules"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            family = try c.decode(Family.self, forKey: .family)
            appRoute = try c.decodeIfPresent(String.self, forKey: .appRoute)
            status = try c.decode(String.self, forKey: .status)
            needs = try c.decode(Needs.self, forKey: .needs)
            figures = try c.decodeIfPresent([String: JSONValue].self, forKey: .figures) ?? [:]
            cost = try c.decodeIfPresent(JSONValue.self, forKey: .cost)
            time = try c.decodeIfPresent(JSONValue.self, forKey: .time)
            memory = try c.decodeIfPresent(JSONValue.self, forKey: .memory)
            caveats = try c.decodeIfPresent([String].self, forKey: .caveats) ?? []
            kindRules = try c.decodeIfPresent([String].self, forKey: .kindRules) ?? []
            fallback = try c.decodeIfPresent(String.self, forKey: .fallback)
            conditions = try c.decodeIfPresent([String].self, forKey: .conditions) ?? []
            step = try c.decodeIfPresent([Int].self, forKey: .step)
            stages = try c.decodeIfPresent([String].self, forKey: .stages)
            trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        }

        /// A figure's value: `figures[key].value`, or the figure itself when the table gives a bare number.
        func figure(_ key: String) -> Double? {
            guard let f = figures[key] else { return nil }
            return f.double ?? f["value"]?.double
        }

        /// The strict figure beside a figure's value (reading's `overall`).
        func strict(_ key: String) -> Double? { figures[key]?["strict"]?.double }

        /// Strict NES on one public stratum of the 895 (`figures.public.<stratum>` is `[strict, answered, "a/n"]`).
        /// The pooled L1-L3 figure is `figures.public_L1-L3.value`.
        func publicStrict(_ stratum: String) -> Double? {
            if stratum == "L1-L3" { return figure("public_L1-L3") }
            return figures["public"]?[stratum]?.array?.first?.double
        }

        var listUSDPer1000: Double? { cost?["usd_1000_list"]?.double }
        var batchUSDPer1000: Double? { cost?["usd_1000_batch"]?.double }
        var secondsPerUnit: Double? { time?["per_unit_s"]?.double }
        var pagesPerHourPerGPUSet: Double? { time?["pages_per_hour_per_gpu_set"]?.double }
        /// The memory the route takes on this Mac: the whole process's footprint where it was measured, else the
        /// model's peak (the MLX peak leaves out the process around it: Xiaomi-OCR-0 2.93 GB against 4.46).
        var peakGB: Double? {
            let peak = memory?["peak_gb"]?.double, whole = memory?["whole_process_gb"]?.double
            switch (peak, whole) {
            case let (p?, w?): return max(p, w)
            default: return peak ?? whole
            }
        }

        /// A row the notes keep as a measured floor or a measured loss, never offered (owner call 11 and the notes'
        /// conditions: "not offered …", "never offered …").
        var offered: Bool {
            !conditions.contains { $0.hasPrefix("not offered") || $0.hasPrefix("never offered") }
        }

        var afterTraining: Bool { status == "after-training" }

        /// A model this Mac has to download first. The table marks the OS's own routes `built_in`; rows with no memory
        /// peak are rules over another route's output (Vision's rule dating, the text page), except the kraken
        /// specialists, which are models whose memory was not tabulated ("where installed", note 04 §9).
        var needsDownload: Bool {
            family == .mac && !needs.builtIn && (peakGB.map { $0 > 0 } == true || id.hasPrefix("kraken-"))
        }
    }

    func stage(_ id: String) -> Stage? { stages.first { $0.id == id } }

    // MARK: Loading

    static func decode(_ data: Data) throws -> SettingsRouteTable {
        try JSONDecoder().decode(SettingsRouteTable.self, from: data)
    }

    static func loadBundled(_ bundle: Bundle = .main) throws -> SettingsRouteTable {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }

    /// Decoded once; nil when the resource is missing or does not decode (the self-test fails on that).
    static let bundled: SettingsRouteTable? = try? loadBundled()

    /// What would make the solver rank on a figure the table does not hold. Empty means fit to ship.
    func problems() -> [String] {
        var out: [String] = []
        if !Self.supportedVersions.contains(version) { out.append("unknown version \(version)") }
        for id in ["reading", "segmentation", "dating", "entities", "training-kit"] where stage(id) == nil {
            out.append("no \(id) stage")
        }
        for s in stages {
            var seen = Set<String>()
            for r in s.routes where !seen.insert(r.id).inserted { out.append("\(s.id): route \(r.id) twice") }
        }
        return out
    }
}

// MARK: - The pair matrix

/// `segbench-results/ocr-pair-matrix.json` (W46.ocr-pair-matrix): every reading pair's paired gap, a minus b, with its
/// 95% interval, on the 96 (all pages, per kind, hands16) and on the 895 (per stratum, pooled L1-L3). The reading tie
/// is read from here (the owner, 2026-11-11: on the 96 a gap under the pair's floor; the interval makes no tie).
struct OCRPairMatrix: Decodable, Sendable {
    static let resourceName = "ocr-pair-matrix"

    struct Score: Decodable, Sendable {
        let n: Int
        let delta: Double
        let lo: Double?
        let hi: Double?
        let underFloor: Bool

        enum CodingKeys: String, CodingKey {
            case n, delta, lo, hi
            case underFloor = "under_floor"
        }
    }

    struct Pair: Decodable, Sendable {
        let set: String
        let group: String
        let a: String
        let b: String
        let floor: Double
        let strict: Score?
        let answered: Score?
    }

    /// One pair read as `a` minus `b`, whichever way the file holds it.
    struct Gap: Sendable {
        let set: String
        let group: String
        let score: String
        let floor: Double
        let n: Int
        let delta: Double
        let lo: Double?
        let hi: Double?
        let underFloor: Bool

        /// "−0.08 [−1.62, +1.64], n 91, owner96/all/answered"
        var citation: String {
            func f(_ x: Double) -> String { (x < 0 ? "−" : "+") + String(format: "%.2f", abs(x)) }
            let interval = (lo != nil && hi != nil) ? " [\(f(lo!)), \(f(hi!))]" : ""
            return "\(f(delta))\(interval), n \(n), \(set)/\(group)/\(score)"
        }
    }

    let pairs: [Pair]
    private let index: [String: Int]

    enum CodingKeys: String, CodingKey { case pairs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairs = try c.decode([Pair].self, forKey: .pairs)
        var index: [String: Int] = [:]
        for (i, p) in pairs.enumerated() { index[Self.key(p.set, p.group, p.a, p.b)] = i }
        self.index = index
    }

    private static func key(_ set: String, _ group: String, _ a: String, _ b: String) -> String {
        "\(set)\u{1}\(group)\u{1}\(a)\u{1}\(b)"
    }

    /// `a` minus `b` on one set, group and score (`strict` or `answered`), or nil when the pair was not measured.
    func gap(_ set: String, _ group: String, _ a: String, _ b: String, score: String) -> Gap? {
        let flipped: Bool
        let pair: Pair
        if let i = index[Self.key(set, group, a, b)] {
            pair = pairs[i]; flipped = false
        } else if let i = index[Self.key(set, group, b, a)] {
            pair = pairs[i]; flipped = true
        } else {
            return nil
        }
        guard let s = score == "answered" ? pair.answered : pair.strict else { return nil }
        return Gap(set: set, group: group, score: score, floor: pair.floor, n: s.n,
                   delta: flipped ? -s.delta : s.delta,
                   lo: flipped ? s.hi.map { -$0 } : s.lo, hi: flipped ? s.lo.map { -$0 } : s.hi,
                   underFloor: s.underFloor)
    }

    static let bundled: OCRPairMatrix? = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OCRPairMatrix.self, from: data)
    }()
}
