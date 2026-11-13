import Foundation

// MARK: - The three settings layers (W46.settings-layers)
//
// `12-settings-design.md` §3.5 and the owner's call 1 of `13-stage-rules/14-owner-calls.md`: a general layer (the Mac
// and the user, in the app's own store), an optional project (a group of similar collections), and the collection.
// A project or a collection holds only the values it answered itself; every other value is read live from the layer
// above, so a key added later is offered to old collections at once. Each resolved value says where it came from,
// and a reset removes a layer's own value so the inherited one shows again. When a batch runs the resolution is
// frozen into the run's record (`ResolvedSettingsSnapshot`).
//
// No migration from the old `UserDefaults` profiles: nothing real was produced with them (owner, 2026-08-01).

/// One settings value, typed so it round-trips losslessly through JSON.
enum SettingsValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// An ordered list (languages, scripts, the priority order).
    case strings([String])
    /// Shares or amounts by name (the document mix by kind).
    case numbers([String: Double])

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "bool":    self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int":     self = .int(try c.decode(Int.self, forKey: .value))
        case "double":  self = .double(try c.decode(Double.self, forKey: .value))
        case "string":  self = .string(try c.decode(String.self, forKey: .value))
        case "strings": self = .strings(try c.decode([String].self, forKey: .value))
        case "numbers": self = .numbers(try c.decode([String: Double].self, forKey: .value))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "unknown settings value type \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let b):    try c.encode("bool", forKey: .type);    try c.encode(b, forKey: .value)
        case .int(let i):     try c.encode("int", forKey: .type);     try c.encode(i, forKey: .value)
        case .double(let d):  try c.encode("double", forKey: .type);  try c.encode(d, forKey: .value)
        case .string(let s):  try c.encode("string", forKey: .type);  try c.encode(s, forKey: .value)
        case .strings(let s): try c.encode("strings", forKey: .type); try c.encode(s, forKey: .value)
        case .numbers(let n): try c.encode("numbers", forKey: .type); try c.encode(n, forKey: .value)
        }
    }

    /// Whether two values are the same kind, so a stored value of the wrong kind is ignored rather than used.
    func sameKind(as other: SettingsValue) -> Bool {
        switch (self, other) {
        case (.bool, .bool), (.int, .int), (.double, .double), (.string, .string),
             (.strings, .strings), (.numbers, .numbers): return true
        default: return false
        }
    }

    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var int: Int? { if case .int(let i) = self { return i }; return nil }
    var double: Double? { if case .double(let d) = self { return d }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var strings: [String]? { if case .strings(let s) = self { return s }; return nil }
    var numbers: [String: Double]? { if case .numbers(let n) = self { return n }; return nil }

    /// JSON has no infinity or NaN, so a value holding one could not be written into a run's record.
    var isFinite: Bool {
        switch self {
        case .double(let d): return d.isFinite
        case .numbers(let n): return n.values.allSatisfy(\.isFinite)
        default: return true
        }
    }
}

/// How a layer came to hold a value; the sheet shows it beside the value.
enum SettingsSource: Codable, Equatable, Sendable {
    /// The user answered or chose it.
    case setByUser(Date)
    /// Measured, e.g. the document mix by the kind classifier on `sample` photographs.
    case measured(Date, sample: Int)
    /// Filled by one of the four starting points (owner, 2026-11-04: fills of the answers, not modes).
    case startingPoint(String, Date)
    /// Read from this Mac (a key in the Keychain, a signed-in plan).
    case detected(Date)
    /// Set by the app from another answer, by that answer's label: "pages stay on this Mac" follows "Spending" until
    /// the user sets it (W46.settings-interviews).
    case follows(String, Date)

    var date: Date {
        switch self {
        case .setByUser(let d), .measured(let d, _), .startingPoint(_, let d), .detected(let d), .follows(_, let d): return d
        }
    }

    /// "you set this on 2026-11-04", "measured on 2026-11-04 from 200 photos".
    var phrase: String {
        let day = Self.day.string(from: date)
        switch self {
        case .setByUser: return "you set this on \(day)"
        case .measured(_, let n): return "measured on \(day) from \(n) photo\(n == 1 ? "" : "s")"
        case .startingPoint(let name, _): return "filled by “\(name)” on \(day)"
        case .detected: return "found on this Mac on \(day)"
        case .follows(let answer, _): return "follows your answer to “\(answer)”, \(day)"
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// A layer's own value and where it came from.
struct SettingsEntry: Codable, Equatable, Sendable {
    var value: SettingsValue
    var source: SettingsSource
}

enum SettingsLayerKind: String, Codable, Sendable {
    case general, project, collection
}

/// One layer: only the values it answered itself.
struct SettingsLayer: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: SettingsLayerKind
    var name: String
    var entries: [String: SettingsEntry] = [:]

    init(id: UUID = UUID(), kind: SettingsLayerKind, name: String, entries: [String: SettingsEntry] = [:]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.entries = entries
    }

    /// One entry a newer build wrote in a form this one does not know (a new value kind or source) is dropped, not
    /// the whole layer: the layer above answers for that key instead.
    private struct LenientEntry: Decodable {
        let entry: SettingsEntry?
        init(from decoder: Decoder) throws { entry = try? SettingsEntry(from: decoder) }
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(SettingsLayerKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        let raw = try c.decodeIfPresent([String: LenientEntry].self, forKey: .entries) ?? [:]
        entries = raw.compactMapValues(\.entry)
    }

    /// Store a value this layer answered. A key the catalog keeps to the general layer, or a value of the wrong kind,
    /// is refused, so a collection can never hold the Mac's memory or a cluster.
    @discardableResult
    mutating func set(_ key: SettingsKey, _ value: SettingsValue, source: SettingsSource) -> Bool {
        guard key.allowed(in: kind), value.sameKind(as: key.defaultValue), value.isFinite else { return false }
        entries[key.rawValue] = SettingsEntry(value: value, source: source)
        return true
    }

    /// Remove this layer's own value; the inherited one shows again.
    mutating func reset(_ key: SettingsKey) { entries[key.rawValue] = nil }

    /// This layer's own value for `key`, ignored when it is of the wrong kind or the key may not live here (a
    /// hand-edited document cannot smuggle one in).
    func entry(_ key: SettingsKey) -> SettingsEntry? {
        guard key.allowed(in: kind), let e = entries[key.rawValue], e.value.sameKind(as: key.defaultValue),
              e.value.isFinite else {
            return nil
        }
        return e
    }
}

/// Every value the layers hold, with its built-in default: the skipped interview, "Free, on this Mac" (owner call 3).
/// Stage overrides (a card set to Custom) are `SettingsKey.override(stage:part:)`.
struct SettingsKey: Hashable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    // The general layer only: the Mac and the user (§3.1).
    static let keys = SettingsKey(rawValue: "keys")
    static let plans = SettingsKey(rawValue: "plans")
    static let cluster = SettingsKey(rawValue: "cluster")
    static let gpusPerJob = SettingsKey(rawValue: "gpusPerJob")
    static let downloadsAllowed = SettingsKey(rawValue: "downloadsAllowed")
    static let moneyHabit = SettingsKey(rawValue: "moneyHabit")
    static let monthCeilingUSD = SettingsKey(rawValue: "monthCeilingUSD")
    static let fineTuning = SettingsKey(rawValue: "fineTuning")

    // Any layer: the habits a collection may answer for itself, and the collection interview (§3.2).
    static let batchCeilingUSD = SettingsKey(rawValue: "batchCeilingUSD")
    static let hours = SettingsKey(rawValue: "hours")
    static let excludedModelFamilies = SettingsKey(rawValue: "excludedModelFamilies")
    static let mix = SettingsKey(rawValue: "mix")
    static let strata = SettingsKey(rawValue: "strata")
    static let period = SettingsKey(rawValue: "period")
    static let languages = SettingsKey(rawValue: "languages")
    static let scripts = SettingsKey(rawValue: "scripts")
    static let preference = SettingsKey(rawValue: "preference")
    static let priorities = SettingsKey(rawValue: "priorities")
    /// Each ranked priority's stage weight, by `SettingsPriority` name; empty is 45, 30, 15, 10 by position.
    static let weights = SettingsKey(rawValue: "weights")
    static let staysOnMac = SettingsKey(rawValue: "staysOnMac")
    static let readingFallback = SettingsKey(rawValue: "readingFallback")
    static let checkingMinutes = SettingsKey(rawValue: "checkingMinutes")
    static let straightenReadingCopy = SettingsKey(rawValue: "straightenReadingCopy")
    /// Placement's one switch (note 05, the settings sheet's rules tab): handwritten text on the page image.
    static let placeHandOnImage = SettingsKey(rawValue: "placeHandOnImage")
    /// Dating's one switch (owner, 2026-11-12, W46.date-route-owner-ok (b)): the image pass on documents whose text
    /// already has a year, for their stamp dates. Off: step 2 runs only where the text has no year (call 7.3).
    static let dateImageEveryDocument = SettingsKey(rawValue: "dateImageEveryDocument")

    static let overridePrefix = "override."
    /// A stage card's chosen route, set when the user overrides the solver's pick.
    static func override(stage: String, part: String) -> SettingsKey {
        SettingsKey(rawValue: "\(overridePrefix)\(stage).\(part)")
    }

    static let generalOnly: [SettingsKey] = [
        .keys, .plans, .cluster, .gpusPerJob, .downloadsAllowed, .moneyHabit, .monthCeilingUSD, .fineTuning,
    ]
    static let anyLayer: [SettingsKey] = [
        .batchCeilingUSD, .hours, .excludedModelFamilies, .mix, .strata, .period, .languages, .scripts,
        .preference, .priorities, .weights, .staysOnMac, .readingFallback, .checkingMinutes, .straightenReadingCopy,
        .placeHandOnImage, .dateImageEveryDocument,
    ]
    static let catalog: [SettingsKey] = generalOnly + anyLayer

    var isOverride: Bool { rawValue.hasPrefix(Self.overridePrefix) }
    var isKnown: Bool { isOverride || Self.catalog.contains(self) }

    func allowed(in kind: SettingsLayerKind) -> Bool {
        guard isKnown else { return false }
        return kind == .general || !Self.generalOnly.contains(self)
    }

    /// The built-in value: the skipped interview (`SettingsAnswers.skippedInterview`) and the general interview's
    /// cheapest safe answers (§3.1: no cluster, no money, overnight, no kit).
    var defaultValue: SettingsValue {
        let skipped = SettingsAnswers.skippedInterview
        switch self {
        case .keys, .plans, .excludedModelFamilies, .languages, .scripts: return .strings([])
        case .cluster: return .bool(false)
        case .gpusPerJob: return .int(1)
        case .downloadsAllowed: return .bool(true)
        case .moneyHabit: return .string(MoneyHabit.none.rawValue)
        case .monthCeilingUSD: return .double(0)
        case .fineTuning: return .string(FineTuningAnswer.no.rawValue)
        case .batchCeilingUSD: return .double(skipped.ceilingUSD ?? 0)
        case .hours: return .double(skipped.hours)
        case .mix: return .numbers(skipped.mix)
        case .strata: return .numbers(skipped.strata)
        case .period: return .string("")
        case .preference: return .string(skipped.preference.rawValue)
        case .priorities: return .strings(skipped.priorities.map(\.rawValue))
        case .weights: return .numbers([:])
        case .staysOnMac: return .bool(skipped.staysOnMac)
        case .readingFallback: return .bool(skipped.readingFallback)
        case .checkingMinutes: return .double(skipped.checkingMinutes)
        // Owner call 6: straightening on by default, switchable off.
        case .straightenReadingCopy: return .bool(true)
        case .placeHandOnImage: return .bool(true)   // the table's default (05-placement.md)
        case .dateImageEveryDocument: return .bool(false)   // owner, 2026-11-12: off unless the user turns it on
        default: return .string("")   // an override: empty is the solver's pick
        }
    }
}

extension SettingsKey {
    /// The name the Settings window shows, in words a user can explain from the screen.
    var label: String {
        if isOverride {
            let parts = rawValue.dropFirst(Self.overridePrefix.count).split(separator: ".", maxSplits: 1)
            let stage = parts.first.map(String.init) ?? ""
            let part = parts.count > 1 ? String(parts[1]) : "all"
            return part == "all" ? "Your choice for \(stage)" : "Your choice for \(stage) (\(part))"
        }
        switch self {
        case .keys: return "API keys found"
        case .plans: return "Signed-in plans"
        case .cluster: return "A computing cluster"
        case .gpusPerJob: return "Graphics cards a cluster job may use"
        case .downloadsAllowed: return "Models may be downloaded to this Mac"
        case .moneyHabit: return "Spending"
        case .monthCeilingUSD: return "Most to spend in a month"
        case .fineTuning: return "Training a model on your corrections"
        case .batchCeilingUSD: return "Most to spend on a batch"
        case .hours: return "How long a batch may run"
        case .excludedModelFamilies: return "Models pages are never sent to"
        case .mix: return "Kinds of document"
        case .strata: return "Public test sets that apply"
        case .period: return "Period"
        case .languages: return "Languages"
        case .scripts: return "Scripts"
        case .preference: return "When two choices are close"
        case .priorities: return "What matters most"
        case .weights: return "How much each one counts"
        case .staysOnMac: return "Pages stay on this Mac"
        case .readingFallback: return "A page that fails goes to another reader"
        case .checkingMinutes: return "Minutes you will spend checking where documents begin"
        case .straightenReadingCopy: return "Straighten the copy you read"
        case .placeHandOnImage: return "Place handwritten text on the page image"
        case .dateImageEveryDocument: return "Search the page image for dates on every document"
        default: return rawValue
        }
    }

    /// The value in words: "On", "$5.00", "8 hours", "typewritten 60%, handwritten 40%".
    func describe(_ value: SettingsValue) -> String {
        switch value {
        case .bool(let b): return b ? "On" : "Off"
        case .int(let i): return "\(i)"
        case .double(let d):
            switch self {
            case .batchCeilingUSD, .monthCeilingUSD: return String(format: "$%.2f", d)
            case .hours: return d == 1 ? "1 hour" : String(format: "%g hours", d)
            case .checkingMinutes: return String(format: "%g minutes", d)
            default: return String(format: "%g", d)
            }
        case .string(let s):
            if s.isEmpty { return isOverride ? "the app's pick" : "not given" }
            if isOverride {   // a route id: its name in the rule table
                let stage = rawValue.dropFirst(Self.overridePrefix.count).split(separator: ".").first.map(String.init)
                return stage.flatMap { SettingsRouteTable.bundled?.stage($0)?.route(s)?.name } ?? s
            }
            switch self {
            case .moneyHabit:
                switch MoneyHabit(rawValue: s) {
                case .none?: return "Nothing is spent"
                case .perBatch?: return "A ceiling for each batch"
                case .perMonth?: return "A ceiling for each month"
                case .noCeiling?: return "No ceiling"
                default: return s
                }
            case .preference:
                switch SettingsPreference(rawValue: s) {
                case .bestMeasured?: return "The best measured"
                case .cheapestWithinPoint?: return "The cheaper, within a point"
                case .fastestWithinPoint?: return "The faster, within a point"
                default: return s
                }
            case .fineTuning:
                switch FineTuningAnswer(rawValue: s) {
                case .no?: return "No"
                case .codingAgent?: return "With a coding agent"
                case .cluster?: return "On a cluster"
                default: return s
                }
            default: return s
            }
        case .strings(let list):
            guard !list.isEmpty else { return "none" }
            switch self {
            case .priorities:
                return list.map { SettingsPriority(rawValue: $0)?.label ?? $0 }.joined(separator: ", then ")
            case .languages:
                return list.map { c in CollectionInterviewAnswers.languageChoices.first { $0.code == c }?.label ?? c }
                    .joined(separator: ", ")
            case .scripts:
                return list.map { s -> String in
                    let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
                    let name = CollectionScript(rawValue: parts[0])?.label ?? parts[0]
                    return parts.count > 1 ? "\(name) \(parts[1])%" : name
                }.joined(separator: ", ")
            default:
                return list.joined(separator: ", ")
            }
        case .numbers(let n):
            guard !n.isEmpty else { return "none" }
            let sorted = n.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            func number(_ x: Double) -> String { String(format: "%.0f", x) }
            switch self {
            case .weights:
                return sorted.map { "\(SettingsPriority(rawValue: $0.key)?.label ?? $0.key) \(number($0.value))" }
                    .joined(separator: ", ")
            case .strata:
                return sorted.map { "\(number($0.value))% judged on \(PublicStratum.label($0.key))" }.joined(separator: "; ")
            case .mix:
                return sorted.map { kind in
                    let name = CollectionInterviewAnswers.measuredKinds.contains(kind.key)
                        ? PageKindName.label(kind.key).lowercased() : CollectionInterviewAnswers.unmeasuredLabel(kind.key).lowercased()
                    return "\(name) \(number(kind.value))%"
                }.joined(separator: ", ")
            default:
                return sorted.map { "\($0.key) \(String(format: "%g", $0.value))%" }.joined(separator: ", ")
            }
        }
    }
}

extension SettingsPriority {
    var label: String {
        switch self {
        case .reading: return "reading"
        case .findingDocuments: return "finding documents"
        case .dates: return "dates"
        case .names: return "names"
        }
    }
}

/// The money habit (§3.1): none, a ceiling per batch, or a ceiling per month tracked against the ledger; or no ceiling,
/// the starting point "Best measured, no limit" (owner, 2026-11-04), which only the general layer can choose.
enum MoneyHabit: String, Codable, CaseIterable, Sendable {
    case none, perBatch, perMonth, noCeiling
}

/// What a batch spent, in the general layer, so a per-month ceiling can be tracked (W46.settings-ledger). Written
/// when a batch finishes, at the same list-price estimate the processing history shows, and for the pages it read
/// when it ends early or a Live Capture session files (W46.settings-ledger-more); `date` is when it was last counted,
/// which is the month it counts against. One line per run and month.
struct SettingsLedgerEntry: Codable, Equatable, Sendable {
    var date: Date
    var usd: Double
    var collectionID: UUID?
    var runID: UUID?
    /// The collection's name when the batch ran, for a ledger line whose collection has since moved.
    var collectionName: String? = nil
    var files: Int? = nil
}

/// The ledger's total for one calendar month, and the batches behind it, newest first.
struct SettingsMonthSpend: Equatable, Sendable {
    var usd: Double = 0
    var entries: [SettingsLedgerEntry] = []
    var batches: Int { entries.count }

    /// "$12.40 by 3 batches", or "nothing yet".
    var summary: String {
        entries.isEmpty ? "nothing yet"
            : String(format: "$%.2f", usd) + " by \(batches) \(batches == 1 ? "batch" : "batches")"
    }

    /// "$12.40 of $20.00, from 3 batches", or "$0.00 of $20.00, no batches yet".
    func summary(of limit: Double) -> String {
        String(format: "$%.2f of $%.2f, ", usd, limit)
            + (entries.isEmpty ? "no batches yet" : "from \(batches) \(batches == 1 ? "batch" : "batches")")
    }
}

// MARK: - Resolution

/// A value as a batch would see it, and where it came from.
struct ResolvedSetting: Codable, Equatable, Sendable {
    var value: SettingsValue
    /// The layer that answered; nil is the built-in default.
    var layer: SettingsLayerKind?
    var source: SettingsSource?
    /// The project's name when the project answered.
    var layerName: String?

    /// "from your general settings", "from the project “Letters”, you set this on 2026-11-04", "built in".
    var sourceText: String {
        switch layer {
        case nil: return "built in: Free, on this Mac"
        case .general?: return "from your general settings" + (source.map { ", \($0.phrase)" } ?? "")
        case .project?: return "from the project “\(layerName ?? "")”" + (source.map { ", \($0.phrase)" } ?? "")
        case .collection?: return "set for this collection" + (source.map { ", \($0.phrase)" } ?? "")
        }
    }
}

/// The three layers read together, the nearest first. Live: nothing is copied down.
struct SettingsResolver: Sendable {
    var general: SettingsLayer
    var project: SettingsLayer?
    var collection: SettingsLayer?

    func resolve(_ key: SettingsKey) -> ResolvedSetting {
        for layer in [collection, project, general].compactMap({ $0 }) {
            if let e = layer.entry(key) {
                return ResolvedSetting(value: e.value, layer: layer.kind, source: e.source,
                                       layerName: layer.kind == .project ? layer.name : nil)
            }
        }
        return ResolvedSetting(value: key.defaultValue, layer: nil, source: nil, layerName: nil)
    }

    /// The overrides any layer holds, by stage card.
    var overrideKeys: [SettingsKey] {
        let raw = [general, project, collection].compactMap { $0 }.flatMap { $0.entries.keys }
        return Set(raw).map(SettingsKey.init(rawValue:)).filter(\.isOverride).sorted { $0.rawValue < $1.rawValue }
    }

    /// Every catalog value and every override, resolved.
    func resolveAll() -> [String: ResolvedSetting] {
        var out: [String: ResolvedSetting] = [:]
        for key in SettingsKey.catalog + overrideKeys { out[key.rawValue] = resolve(key) }
        return out
    }

    /// What the solver reads as resources. `macMemoryGB` is read live from the Mac, never stored.
    func resources(macMemoryGB: Double) -> SettingsResources {
        var r = SettingsResources(macMemoryGB: macMemoryGB)
        r.keys = Set(resolve(.keys).value.strings ?? [])
        r.plans = Set(resolve(.plans).value.strings ?? [])
        r.cluster = resolve(.cluster).value.bool ?? false
        r.gpusPerJob = max(1, resolve(.gpusPerJob).value.int ?? 1)
        r.downloadsAllowed = resolve(.downloadsAllowed).value.bool ?? true
        r.excludedModelFamilies = Set(resolve(.excludedModelFamilies).value.strings ?? [])
        return r
    }

    /// What the solver reads as this batch's answers. `spentThisMonthUSD` is the ledger's total for the month, read
    /// only under the per-month habit.
    func answers(pages: Int, documents: Int? = nil, spentThisMonthUSD: Double = 0) -> SettingsAnswers {
        var a = SettingsAnswers()
        a.pages = max(1, pages)
        a.documents = documents
        if let mix = resolve(.mix).value.numbers, !mix.isEmpty { a.mix = mix }
        // Registers are asked apart (they are not measured) and read as forms and tables (the public set L4).
        if let r = a.mix.removeValue(forKey: "registers") { a.mix["forms", default: 0] += r }
        a.strata = resolve(.strata).value.numbers ?? [:]
        let ceiling = ceilingUSD(spentThisMonthUSD: spentThisMonthUSD)
        a.ceilingUSD = ceiling.isFinite ? ceiling : nil
        a.hours = resolve(.hours).value.double ?? a.hours
        a.preference = resolve(.preference).value.string.flatMap(SettingsPreference.init(rawValue:)) ?? .bestMeasured
        a.priorities = (resolve(.priorities).value.strings ?? []).compactMap(SettingsPriority.init(rawValue:))
        // The weights count only beside the order they were given with, from the same layer.
        let weights = resolve(.weights)
        let order = resolve(.priorities)
        if weights.layer == order.layer, weights.layerName == order.layerName {
            for (name, w) in weights.value.numbers ?? [:] {
                if let p = SettingsPriority(rawValue: name), w >= 0 { a.weights[p.stage] = w }
            }
        }
        a.staysOnMac = resolve(.staysOnMac).value.bool ?? true
        a.readingFallback = resolve(.readingFallback).value.bool ?? true
        a.checkingMinutes = max(0, resolve(.checkingMinutes).value.double ?? 0)
        a.fineTuning = resolve(.fineTuning).value.string.flatMap(FineTuningAnswer.init(rawValue:)) ?? .no
        return a
    }

    /// This batch's ceiling. Under the money habit "none" nothing is spent, whatever a collection says (§3.1: the
    /// cheapest safe answer where money is involved). Per batch, the nearest layer's batch ceiling. Per month, what
    /// is left of the month's ceiling, and no more than a batch ceiling a layer set. No ceiling is infinity, unless a
    /// project or collection set its own batch ceiling, which then holds.
    func ceilingUSD(spentThisMonthUSD: Double = 0) -> Double {
        func usable(_ v: Double?) -> Double { (v ?? 0).isFinite ? max(0, v ?? 0) : 0 }
        let habit = resolve(.moneyHabit).value.string.flatMap(MoneyHabit.init(rawValue:)) ?? MoneyHabit.none
        let batch = resolve(.batchCeilingUSD)
        switch habit {
        case .none: return 0
        case .noCeiling: return batch.layer == nil || batch.layer == .general ? .infinity : usable(batch.value.double)
        case .perBatch: return usable(batch.value.double)
        case .perMonth:
            let left = max(0, usable(resolve(.monthCeilingUSD).value.double) - usable(spentThisMonthUSD))
            return batch.layer == nil ? left : min(left, usable(batch.value.double))
        }
    }
}

// MARK: - The frozen record

/// The resolved settings frozen into a run's record when a batch starts, so a result can always say what produced
/// it. Written into the pending run and appended to the collection's settings document.
struct ResolvedSettingsSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    /// The run this was frozen for; the collection's run record of the same id holds the same snapshot.
    var runID: UUID
    var resolvedAt: Date
    var collectionID: UUID?
    var projectID: UUID?
    var projectName: String?
    /// This Mac's memory when the batch started.
    var macMemoryGB: Double
    /// Every layered value with its source.
    var values: [String: ResolvedSetting]
    /// The app's processing settings as the run read them (provider, model, tagging, sizing…), by `DefaultsKeys`
    /// name; the per-provider model ids are under `selectedModelId_<provider>`. Never an API key.
    var processing: [String: SettingsValue]

    init(runID: UUID, resolvedAt: Date, collectionID: UUID?, projectID: UUID?, projectName: String?,
         macMemoryGB: Double, values: [String: ResolvedSetting], processing: [String: SettingsValue]) {
        self.runID = runID
        self.resolvedAt = resolvedAt
        self.collectionID = collectionID
        self.projectID = projectID
        self.projectName = projectName
        self.macMemoryGB = macMemoryGB
        self.values = values
        self.processing = processing
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, runID, resolvedAt, collectionID, projectID, projectName, macMemoryGB, values, processing
    }

    /// A value of a kind this build does not know is dropped rather than failing the whole record (it rides in the
    /// pending run, which a resume must still be able to read).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        runID = try c.decode(UUID.self, forKey: .runID)
        resolvedAt = try c.decode(Date.self, forKey: .resolvedAt)
        collectionID = try c.decodeIfPresent(UUID.self, forKey: .collectionID)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        macMemoryGB = try c.decode(Double.self, forKey: .macMemoryGB)
        values = (try c.decodeIfPresent([String: Lenient<ResolvedSetting>].self, forKey: .values) ?? [:])
            .compactMapValues(\.value)
        processing = (try c.decodeIfPresent([String: Lenient<SettingsValue>].self, forKey: .processing) ?? [:])
            .compactMapValues(\.value)
    }
}
