import Foundation

// MARK: - The two interviews (W46.settings-interviews)
//
// `12-settings-design.md` §3.1-3.2 and the owner's calls of 2026-11-04 and 2026-11-06 (`13-stage-rules/14-owner-calls.md`).
// The general interview runs once, at the app's first start: it reads the Mac and the Keychain, shows what it found,
// and asks the few things it cannot read. The collection interview runs when a collection or a project is created: it
// measures the document mix on a sample of the photographs and asks what a classifier cannot see. Both write ordinary
// layer values (`SettingsLayers.swift`) with their source; nothing depends on which starting point was pressed. A
// skipped interview writes nothing but what was found on the Mac, which is "Free, on this Mac" (owner call 3).
//
// This file is the logic, with no view and no Keychain of its own, so the headless driver can test every answer.

// MARK: What the Mac has

/// What the general interview reads rather than asks (§3.1): the chip and memory, which keys are in the Keychain, the
/// Claude command-line tool and a ChatGPT sign-in. Only whether a key exists is read, never the key itself.
struct MacInventory: Equatable, Sendable {
    var chip: String
    var memoryGB: Double
    /// Keys found, by the route table's names (`gemini`, `openrouter`, `openai`, `mistral`, `anthropic`, `gateway`).
    var keys: [String]
    /// Where the `claude` tool is, if it is installed. Whether it is signed in needs a check (`claudeSignedIn`).
    var claudePath: String?
    /// Set by the interview's sign-in check; nil until it has run.
    var claudeSignedIn: Bool?
    var chatGPTSignedIn: Bool

    /// The route table's key names and the Keychain account each is stored under, in the order they are shown.
    static let keyAccounts: [(name: String, account: String, label: String)] = [
        ("gemini", LLMProvider.gemini.rawValue, "Google Gemini"),
        ("openrouter", LLMProvider.openrouter.rawValue, "OpenRouter"),
        ("openai", LLMProvider.openai.rawValue, "OpenAI"),
        ("mistral", LLMProvider.mistral.rawValue, "Mistral"),
        ("anthropic", LLMProvider.anthropic.rawValue, "Anthropic"),
        ("gateway", "Gateway", "Your institution's AI gateway"),
    ]
    static let chatGPTAccount = KeychainChatGPTCredentialStore.account

    /// Read the Mac. `exists` answers whether a Keychain account holds an item (the app passes
    /// `KeychainHelper.exists`, which never reads the secret); `claudePath` is where the tool was found.
    static func read(exists: (String) -> Bool, claudePath: String?, memoryGB: Double = SettingsLayerStore.thisMacMemoryGB,
                     chip: String = MacInventory.thisChip) -> MacInventory {
        MacInventory(chip: chip, memoryGB: memoryGB,
                     keys: keyAccounts.filter { exists($0.account) }.map(\.name),
                     claudePath: claudePath, claudeSignedIn: nil, chatGPTSignedIn: exists(chatGPTAccount))
    }

    /// The plans the solver may use: Claude only once the check found it signed in (a logged-out tool must never be
    /// saved as a plan), ChatGPT when a sign-in is kept on this Mac.
    var plans: [String] {
        var p: [String] = []
        if claudePath != nil, claudeSignedIn == true { p.append("claude") }
        if chatGPTSignedIn { p.append("chatgpt") }
        return p
    }

    static func keyLabel(_ name: String) -> String { keyAccounts.first { $0.name == name }?.label ?? name }

    static var thisChip: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "this Mac" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "this Mac" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: Starting points

/// The four starting points (owner, 2026-11-04): fills of the answers, not modes. Pressing one fills the answers it
/// names, each marked with its source; every value stays editable and nothing later depends on which was pressed.
enum SettingsStartingPoint: String, CaseIterable, Sendable {
    case free, fewDollars, plan, best

    var name: String {
        switch self {
        case .free: return "Free, on this Mac"
        case .fewDollars: return "A few dollars, overnight"
        case .plan: return "My Claude plan, no money"
        case .best: return "Best measured, no limit"
        }
    }

    var summary: String {
        switch self {
        case .free: return "Nothing is spent and no page leaves this Mac."
        case .fewDollars: return "Up to $5 a batch, the cheaper choice when two are within a point, and a long run."
        case .plan: return "No money; pages may go to the Claude plan you are signed in to."
        case .best: return "The best measured choice for each step, whatever it costs."
        }
    }

    /// The general layer's spending habit this point means (the prototype's `PRESETS`).
    var moneyHabit: MoneyHabit {
        switch self {
        case .free, .plan: return .none
        case .fewDollars: return .perBatch
        case .best: return .noCeiling
        }
    }
    var batchCeilingUSD: Double { self == .fewDollars ? 5 : 0 }
    var hours: Double {
        switch self {
        case .free: return 48
        case .fewDollars: return 30
        case .plan, .best: return 8
        }
    }
    var preference: SettingsPreference { self == .fewDollars ? .cheapestWithinPoint : .bestMeasured }
    var staysOnMac: Bool { self == .free }
}

// MARK: The general interview

/// The general interview's answers (§3.1). Every default is the one most users keep, and the cheapest safe one where
/// money is involved: no cluster, no money, overnight, no training.
struct GeneralInterviewAnswers: Equatable, Sendable {
    var cluster = false
    var gpusPerJob = 1
    var moneyHabit: MoneyHabit = .none
    var batchCeilingUSD: Double = 5
    var monthCeilingUSD: Double = 20
    var hours: Double = 8
    var fineTuning: FineTuningAnswer = .no
    var downloadsAllowed = true
    /// Whether pages may leave this Mac at all; the collection interview's switch can still keep one collection here.
    var staysOnMac = true
    /// Whether the user set "pages may leave this Mac" themselves; until then choosing to spend money lets them leave.
    var staysOnMacChosen = false
    var preference: SettingsPreference = .bestMeasured
    /// The starting point last pressed, and the answers it filled that the user has not changed since.
    var startingPoint: SettingsStartingPoint?
    var filled: Set<String> = []

    /// Read back what the general layer already holds, so running the interview again starts from the last answers.
    init(from layer: SettingsLayer? = nil) {
        guard let layer else { return }
        let r = SettingsResolver(general: layer)
        cluster = r.resolve(.cluster).value.bool ?? cluster
        gpusPerJob = max(1, r.resolve(.gpusPerJob).value.int ?? gpusPerJob)
        moneyHabit = r.resolve(.moneyHabit).value.string.flatMap(MoneyHabit.init(rawValue:)) ?? moneyHabit
        if layer.entry(.batchCeilingUSD) != nil { batchCeilingUSD = r.resolve(.batchCeilingUSD).value.double ?? batchCeilingUSD }
        if layer.entry(.monthCeilingUSD) != nil { monthCeilingUSD = r.resolve(.monthCeilingUSD).value.double ?? monthCeilingUSD }
        hours = r.resolve(.hours).value.double ?? hours
        fineTuning = r.resolve(.fineTuning).value.string.flatMap(FineTuningAnswer.init(rawValue:)) ?? fineTuning
        downloadsAllowed = r.resolve(.downloadsAllowed).value.bool ?? downloadsAllowed
        staysOnMac = r.resolve(.staysOnMac).value.bool ?? staysOnMac
        if let e = layer.entry(.staysOnMac), case .follows = e.source {} else { staysOnMacChosen = layer.entry(.staysOnMac) != nil }
        preference = r.resolve(.preference).value.string.flatMap(SettingsPreference.init(rawValue:)) ?? preference
    }

    mutating func fill(_ point: SettingsStartingPoint) {
        moneyHabit = point.moneyHabit
        if point.moneyHabit == .perBatch { batchCeilingUSD = point.batchCeilingUSD }
        hours = point.hours
        preference = point.preference
        staysOnMac = point.staysOnMac
        startingPoint = point
        filled = [SettingsKey.moneyHabit, .batchCeilingUSD, .hours, .preference, .staysOnMac].map(\.rawValue).reduce(into: []) { $0.insert($1) }
    }

    /// A changed answer is the user's own from then on.
    mutating func touch(_ key: SettingsKey) { filled.remove(key.rawValue) }

    /// Money can only be spent off this Mac, so choosing to spend lets pages leave, and choosing to spend nothing
    /// keeps them here, until the user sets that switch themselves.
    mutating func setMoneyHabit(_ habit: MoneyHabit) {
        moneyHabit = habit
        touch(.moneyHabit)
        if !staysOnMacChosen { staysOnMac = habit == .none }
    }

    /// Write the answers and what was found into the general layer. The money a habit does not use is not written,
    /// so the general layer holds only what this interview actually answered.
    func apply(to layer: inout SettingsLayer, inventory: MacInventory, now: Date = Date()) {
        GeneralInterviewAnswers.applyFound(inventory, to: &layer, now: now)
        func source(_ key: SettingsKey) -> SettingsSource {
            if let p = startingPoint, filled.contains(key.rawValue) { return .startingPoint(p.name, now) }
            return .setByUser(now)
        }
        func put(_ key: SettingsKey, _ value: SettingsValue) { layer.set(key, value, source: source(key)) }
        put(.cluster, .bool(cluster))
        if cluster { put(.gpusPerJob, .int(max(1, gpusPerJob))) } else { layer.reset(.gpusPerJob) }
        put(.moneyHabit, .string(moneyHabit.rawValue))
        switch moneyHabit {
        case .none, .noCeiling:
            layer.reset(.batchCeilingUSD); layer.reset(.monthCeilingUSD)
        case .perBatch:
            put(.batchCeilingUSD, .double(max(0, batchCeilingUSD))); layer.reset(.monthCeilingUSD)
        case .perMonth:
            put(.monthCeilingUSD, .double(max(0, monthCeilingUSD))); layer.reset(.batchCeilingUSD)
        }
        put(.hours, .double(max(1, hours)))
        put(.fineTuning, .string(fineTuning.rawValue))
        put(.downloadsAllowed, .bool(downloadsAllowed))
        if staysOnMacChosen || filled.contains(SettingsKey.staysOnMac.rawValue) { put(.staysOnMac, .bool(staysOnMac)) }
        else { layer.set(.staysOnMac, .bool(staysOnMac), source: .follows(SettingsKey.moneyHabit.label, now)) }
        put(.preference, .string(preference.rawValue))
    }

    /// The general values this interview answers; a skip clears these and nothing else.
    static let keys: [SettingsKey] = [.cluster, .gpusPerJob, .moneyHabit, .batchCeilingUSD, .monthCeilingUSD, .hours,
                                      .fineTuning, .downloadsAllowed, .staysOnMac, .preference]

    /// What a skipped interview writes: only what was found on the Mac, so the sheet can list it. Every answer an
    /// earlier run gave is removed, so every other value is the built-in "Free, on this Mac" and nothing is spent
    /// (owner call 3), also when the interview is skipped from Settings after it was once answered.
    static func skip(_ inventory: MacInventory, layer: inout SettingsLayer, now: Date = Date()) {
        for key in keys { layer.reset(key) }
        applyFound(inventory, to: &layer, now: now)
    }

    /// Whether the general layer holds any of this interview's answers.
    static func hasAnswers(_ layer: SettingsLayer) -> Bool { keys.contains { layer.entry($0) != nil } }

    static func applyFound(_ inventory: MacInventory, to layer: inout SettingsLayer, now: Date = Date()) {
        layer.set(.keys, .strings(inventory.keys), source: .detected(now))
        layer.set(.plans, .strings(inventory.plans), source: .detected(now))
    }
}

// MARK: The collection interview

/// The document mix measured by the on-device kind classifier on a sample of the photographs.
struct KindMeasurement: Equatable, Sendable {
    /// Photographs the classifier was given.
    var sample: Int
    /// Pages by the kind it called.
    var counts: [String: Int]
    /// Pages it called with less than `PageKindRouting.minimumConfidence`, still counted under their kind.
    var unsure: Int
    /// Pages it could not tell (an unreadable image, an older macOS).
    var unknown: Int
    var date: Date

    /// Shares in percent over the pages it could tell.
    var shares: [String: Double] {
        let told = counts.values.reduce(0, +)
        guard told > 0 else { return [:] }
        return counts.filter { $0.value > 0 }.mapValues { 100 * Double($0) / Double(told) }
    }

    static func tally(_ kinds: [PageKind?], date: Date = Date()) -> KindMeasurement {
        var counts: [String: Int] = [:]
        var unsure = 0
        var unknown = 0
        for k in kinds {
            guard let k else { unknown += 1; continue }
            counts[k.kind, default: 0] += 1
            if k.confidence < PageKindRouting.minimumConfidence { unsure += 1 }
        }
        return KindMeasurement(sample: kinds.count, counts: counts, unsure: unsure, unknown: unknown, date: date)
    }

    /// The photographs to classify: at most `limit`, spread evenly through the batch in name order, so a box that
    /// changes kind halfway is sampled on both sides.
    static func sample(_ urls: [URL], limit: Int = KindMeasurement.sampleLimit) -> [URL] {
        let sorted = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard sorted.count > limit, limit > 0 else { return sorted }
        return (0..<limit).map { sorted[$0 * sorted.count / limit] }
    }

    /// About 0.6 s a page (`kind-classifier.md` §6), so 40 photographs take under half a minute.
    static let sampleLimit = 40
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
    /// The classifier on the owner's pages after the mixed-cut rework (`kind-atrium.md`).
    static let ownerRight = 137, ownerPages = 141
}

/// Scripts the collection interview asks about. Kurrent and Fraktur are forms of the Latin alphabet, so they are a
/// switch, not a share; the others are asked as a share of the pages.
enum CollectionScript: String, CaseIterable, Sendable {
    case latin, kurrent, fraktur, greek, hebrew, arabic, cyrillic, chinese, devanagari

    var label: String {
        switch self {
        case .latin: return "Latin alphabet (English, French, German…)"
        case .kurrent: return "German handwriting (Kurrent or secretary hand)"
        case .fraktur: return "Blackletter or Fraktur print"
        case .greek: return "Greek"
        case .hebrew: return "Hebrew"
        case .arabic: return "Arabic"
        case .cyrillic: return "Cyrillic"
        case .chinese: return "Chinese"
        case .devanagari: return "Devanagari"
        }
    }

    var isLatinForm: Bool { self == .latin || self == .kurrent || self == .fraktur }

    /// The public test set its pages are judged on (`execution-plans/benchmark-corpus/00-plan.md`).
    var stratum: String? {
        switch self {
        case .arabic: return "N1"
        case .cyrillic: return "N2"
        case .greek: return "N3"
        case .hebrew: return "N4"
        case .chinese: return "N5"
        case .devanagari: return "N6"
        default: return nil
        }
    }
}

/// The public test sets, in words (`benchmark-corpus/00-plan.md`), so the interview can say what a collection's pages
/// will be judged on.
enum PublicStratum {
    static func label(_ id: String) -> String {
        switch id {
        case "L4": return "ledgers, forms and tables, 1800-1950"
        case "L5": return "Dutch, Spanish and Portuguese archival hands, 1600-1850"
        case "L6": return "German Kurrent and secretary hands, 1500-1900"
        case "L7": return "medieval and early-modern charters, before 1600"
        case "L8": return "printed books and pamphlets, Fraktur included, 1500-1900"
        case "L9": return "newspapers from microfilm, 1850-1920"
        case "N1": return "Arabic manuscripts"
        case "N2": return "Cyrillic, early 1700s"
        case "N3": return "Greek minuscule, about 1500"
        case "N4": return "Hebrew book hands, medieval"
        case "N5": return "Chinese print"
        case "N6": return "Devanagari print"
        default: return id
        }
    }
}

/// The collection interview's answers (§3.2). The interview shows every value as the layers resolve it now, but writes
/// only what this interview answered (the user changed it, a starting point filled it, or the layer already held it):
/// everything else stays inherited live from the project and the general settings (owner, 2026-11-04, "Layers").
struct CollectionInterviewAnswers: Equatable, Sendable {
    static let measuredKinds = ["typewritten", "printed", "handwritten", "forms"]
    /// Kinds the classifier does not measure, asked and labelled "not measured" (owner, 2026-11-06). `registers` is
    /// kept under its own name and read as forms (`SettingsResolver.answers`).
    static let unmeasuredKinds = ["clippings", "newspapers", "registers", "mixed"]
    static let languageChoices: [(code: String, label: String)] = [
        ("en", "English"), ("fr", "French"), ("de", "German"), ("nl", "Dutch"), ("es", "Spanish"),
        ("pt", "Portuguese"), ("it", "Italian"), ("la", "Latin"), ("other", "Another language"),
    ]
    /// The values the interview may write. The mix and what it was derived from (the strata, the scripts, the period
    /// and the languages) are one group, written together into one layer, so a collection's mix never sits beside a
    /// project's strata, and an emptied answer still overrides the project's.
    static let keys: [SettingsKey] = [.mix, .period, .languages, .scripts, .batchCeilingUSD, .hours, .checkingMinutes,
                                      .priorities, .preference, .straightenReadingCopy, .staysOnMac]
    static let mixGroup: [SettingsKey] = [.mix, .strata, .scripts, .period, .languages]
    /// Where the mix shown came from when this layer did not answer it ("the project “Letters”", "your general
    /// settings"); nil when it is this layer's own or there is none.
    var mixInheritedFrom: String?

    /// The mix in percent by measured kind: the measurement's shares until the user corrects them.
    var measuredShares: [String: Double] = [:]
    var measurement: KindMeasurement?
    /// Whether the user changed a measured share, which makes the mix theirs rather than measured.
    var correctedMix = false
    /// Percent of all pages for each kind the classifier does not measure.
    var unmeasuredShares: [String: Double] = [:]
    var periodFrom: Int?
    var periodTo: Int?
    var languages: [String] = []
    /// Kurrent and Fraktur as switches; the non-Latin scripts with their share of the pages in percent.
    var latinForms: Set<CollectionScript> = []
    var scriptShares: [CollectionScript: Double] = [:]
    var batchCeilingUSD: Double = 0
    var hours: Double = 8
    var checkingMinutes: Double = 0
    /// What matters most, in order, and each one's weight (0 is not ranked).
    var order: [SettingsPriority] = SettingsPriority.allCases
    var weights: [SettingsPriority: Double] = [.reading: 45, .findingDocuments: 30, .dates: 15, .names: 0]
    var preference: SettingsPreference = .bestMeasured
    var straightenReadingCopy = true
    var staysOnMac = true
    var startingPoint: SettingsStartingPoint?
    /// The keys this interview will write (`SettingsKey.rawValue`).
    var answered: Set<String> = []
    /// The answered keys whose value a starting point filled and the user has not changed since.
    var filled: Set<String> = []

    /// Start from what the layers resolve to now; `own` is the layer the interview writes (the collection's or the
    /// project's), whose values count as already answered.
    init(resolver: SettingsResolver? = nil, own: SettingsLayer? = nil) {
        guard let r = resolver else { return }
        batchCeilingUSD = r.resolve(.batchCeilingUSD).value.double ?? batchCeilingUSD
        hours = r.resolve(.hours).value.double ?? hours
        checkingMinutes = r.resolve(.checkingMinutes).value.double ?? checkingMinutes
        preference = r.resolve(.preference).value.string.flatMap(SettingsPreference.init(rawValue:)) ?? preference
        straightenReadingCopy = r.resolve(.straightenReadingCopy).value.bool ?? straightenReadingCopy
        staysOnMac = r.resolve(.staysOnMac).value.bool ?? staysOnMac
        // The mix group is read from the one layer that answered the mix.
        let mix = r.resolve(.mix)
        func group(_ key: SettingsKey) -> SettingsValue? {
            let v = r.resolve(key)
            return mix.layer == nil || (v.layer == mix.layer && v.layerName == mix.layerName) ? v.value : nil
        }
        languages = group(.languages)?.strings ?? []
        (periodFrom, periodTo) = Self.parsePeriod(group(.period)?.string ?? "")
        let ranked = (r.resolve(.priorities).value.strings ?? []).compactMap(SettingsPriority.init(rawValue:))
        let w = r.resolve(.weights)
        let stored = w.layer == r.resolve(.priorities).layer ? w.value.numbers ?? [:] : [:]
        order = ranked + SettingsPriority.allCases.filter { !ranked.contains($0) }
        weights = Dictionary(uniqueKeysWithValues: order.enumerated().map { i, p in
            (p, ranked.contains(p) ? stored[p.rawValue] ?? (i < SettingsSolver.weights.count ? SettingsSolver.weights[i] : 0) : 0)
        })
        for s in group(.scripts)?.strings ?? [] {
            let parts = s.split(separator: ":", maxSplits: 1)
            guard let script = CollectionScript(rawValue: String(parts[0])) else { continue }
            if script.isLatinForm { if script != .latin { latinForms.insert(script) } }
            else { scriptShares[script] = parts.count > 1 ? Double(parts[1]) ?? 0 : 0 }
        }
        if mix.layer != nil, let n = mix.value.numbers {
            // Undo what `mixAndStrata` did, so answering again and saving unchanged writes the same mix: the hands
            // and prints that went to a public set come back as handwriting and print, and every kind is put back on
            // the Latin pages' scale.
            let strata = group(.strata)?.numbers ?? [:]
            let nonLatin = min(99.999, scriptShares.values.reduce(0) { $0 + max(0, $1) })
            let unscale = 100 / (100 - nonLatin)
            measuredShares = n.filter { Self.measuredKinds.contains($0.key) }.mapValues { $0 * unscale }
            let hands = ["L5", "L6", "L7"].reduce(0) { $0 + (strata[$1] ?? 0) }
            if hands > 0 { measuredShares["handwritten", default: 0] += hands * unscale }
            if let print = strata["L8"], print > 0 { measuredShares["printed", default: 0] += print * unscale }
            unmeasuredShares = n.filter { Self.unmeasuredKinds.contains($0.key) }.mapValues { $0 * unscale }
            if case .measured(let date, let sample)? = mix.source {
                measurement = KindMeasurement(sample: sample, counts: [:], unsure: 0, unknown: 0, date: date)
            } else if mix.layer == own?.kind {
                correctedMix = true
            }
            if mix.layer != own?.kind {
                mixInheritedFrom = mix.layer == .project ? "the project “\(mix.layerName ?? "")”" : "your general settings"
            }
        }
        if let own {
            answered = Set(Self.keys.map(\.rawValue).filter { own.entries[$0] != nil })
            if Self.mixGroup.contains(where: { own.entries[$0.rawValue] != nil }) { answered.insert(SettingsKey.mix.rawValue) }
        }
    }

    mutating func take(_ m: KindMeasurement) {
        measurement = m
        measuredShares = m.shares
        correctedMix = false
        touch(.mix)
    }

    /// The order fills the default weights by position (45, 30, 15, then 10 when names are ranked); a weight the user
    /// typed is kept until the order changes again.
    mutating func move(_ p: SettingsPriority, by offset: Int) {
        guard let i = order.firstIndex(of: p) else { return }
        let j = max(0, min(order.count - 1, i + offset))
        guard i != j else { return }
        let ranked = order.filter { (weights[$0] ?? 0) > 0 }.count
        order.remove(at: i)
        order.insert(p, at: j)
        for (k, q) in order.enumerated() {
            weights[q] = k < max(ranked, 1) && k < SettingsSolver.weights.count ? SettingsSolver.weights[k] : 0
        }
        touch(.priorities)
    }

    /// A starting point fills only the limits it means: its ceiling only when it spends ("A few dollars, overnight"),
    /// so the others keep the ceiling the layers give; and from a collection it can keep pages on the Mac but never
    /// silently let them leave (that switch is the user's own).
    mutating func fill(_ point: SettingsStartingPoint) {
        var keys: [SettingsKey] = [.hours, .preference]
        if point.moneyHabit == .perBatch {
            batchCeilingUSD = point.batchCeilingUSD
            keys.append(.batchCeilingUSD)
        }
        if point.staysOnMac {
            staysOnMac = true
            keys.append(.staysOnMac)
        }
        hours = point.hours
        preference = point.preference
        startingPoint = point
        filled = Set(keys.map(\.rawValue))
        answered.formUnion(filled)
    }

    /// The user answered `key`: it is written, and is theirs rather than a starting point's.
    mutating func touch(_ key: SettingsKey) {
        answered.insert(key.rawValue)
        filled.remove(key.rawValue)
    }

    func isAnswered(_ key: SettingsKey) -> Bool { answered.contains(key.rawValue) }

    static func unmeasuredLabel(_ kind: String) -> String {
        switch kind {
        case "clippings": return "Newspaper clippings"
        case "newspapers": return "Whole newspaper pages"
        case "registers": return "Registers and ledgers"
        case "mixed": return "Typed pages with handwriting on them"
        default: return kind
        }
    }

    static func priorityLabel(_ p: SettingsPriority) -> String {
        switch p {
        case .reading: return "Reading the text"
        case .findingDocuments: return "Finding where each document begins"
        case .dates: return "Dates"
        case .names: return "Names of people and places"
        }
    }

    /// A starting point cannot change the general spending habit from a collection; say so when the two disagree, so
    /// a filled ceiling is never silently without effect.
    static func moneyNote(point: SettingsStartingPoint?, habit: MoneyHabit) -> String? {
        guard let point else { return nil }
        switch (point.moneyHabit, habit) {
        case (.perBatch, .none):
            return "Your general settings spend nothing, so this collection's $\(Int(point.batchCeilingUSD)) limit has no effect until Spending is changed there."
        case (.noCeiling, .none), (.noCeiling, .perBatch), (.noCeiling, .perMonth):
            return "“No limit” is a general setting: this collection keeps the spending limit your general settings give."
        default:
            return nil
        }
    }

    static func parsePeriod(_ s: String) -> (Int?, Int?) {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return (Int(s.trimmingCharacters(in: .whitespaces)), nil) }
        return (parts[0], parts[1])
    }

    var periodText: String {
        switch (periodFrom, periodTo) {
        case let (a?, b?): return "\(min(a, b))-\(max(a, b))"
        case let (a?, nil): return "\(a)-"
        case let (nil, b?): return "-\(b)"
        default: return ""
        }
    }

    /// The middle of the period, which decides the public test set a hand or a print is judged on.
    var periodMiddle: Double? {
        switch (periodFrom, periodTo) {
        case let (a?, b?): return Double(a + b) / 2
        case let (a?, nil): return Double(a)
        case let (nil, b?): return Double(b)
        default: return nil
        }
    }

    /// The mix and the public strata the solver reads, both on one scale of 100 (`SettingsAnswers.mix`/`strata`).
    ///
    /// The measured kinds share what the unmeasured kinds leave. Pages in a non-Latin script move to that script's
    /// public set. Of the Latin pages, handwriting moves to the period's and language's own set where the bench has one
    /// (L5 Dutch, Spanish or Portuguese hands 1600-1850, L6 German hands 1500-1900 or Kurrent, L7 charters before
    /// 1600), and print to L8 when it is Fraktur or from before 1700; everything else keeps its kind, read by the
    /// owner's measured pages. Registers keep their name here and are read as forms (the public set L4 is ledgers,
    /// forms and tables).
    func mixAndStrata() -> (mix: [String: Double], strata: [String: Double]) {
        // Unmeasured kinds given as more than 100% in all are read as shares of the whole.
        let given = Self.unmeasuredKinds.reduce(0) { $0 + max(0, unmeasuredShares[$1] ?? 0) }
        let uScale = given > 100 ? 100 / given : 1
        let unmeasured = given * uScale
        let measuredTotal = measuredShares.values.reduce(0) { $0 + max(0, $1) }
        var kinds: [String: Double] = [:]
        if measuredTotal > 0 {
            let room = max(0, 100 - min(100, unmeasured))
            for (k, v) in measuredShares where v > 0 { kinds[k] = room * v / measuredTotal }
        }
        for k in Self.unmeasuredKinds {
            let v = max(0, unmeasuredShares[k] ?? 0) * uScale
            guard v > 0 else { continue }
            kinds[k, default: 0] += v
        }
        var strata: [String: Double] = [:]
        let nonLatin = min(100, scriptShares.values.reduce(0) { $0 + max(0, $1) })
        if nonLatin > 0 {
            kinds = kinds.mapValues { $0 * (100 - nonLatin) / 100 }
            for (s, v) in scriptShares where v > 0 {
                if let id = s.stratum { strata[id, default: 0] += 100 * v / max(100, nonLatin) }
            }
        }
        let mid = periodMiddle
        let langs = Set(languages)
        var hands: [String] = []
        if let mid, mid < 1600 { hands.append("L7") }
        if let mid, (1600...1850).contains(mid), !langs.isDisjoint(with: ["nl", "es", "pt"]) { hands.append("L5") }
        if latinForms.contains(.kurrent) || (langs.contains("de") && mid.map { (1500...1900).contains($0) } == true) {
            hands.append("L6")
        }
        if let h = kinds["handwritten"], h > 0, !hands.isEmpty {
            kinds["handwritten"] = nil
            for id in hands { strata[id, default: 0] += h / Double(hands.count) }
        }
        if let p = kinds["printed"], p > 0, latinForms.contains(.fraktur) || (mid.map { $0 < 1700 } == true) {
            kinds["printed"] = nil
            strata["L8", default: 0] += p
        }
        return (kinds.filter { $0.value > 0.0001 }, strata.filter { $0.value > 0.0001 })
    }

    var scriptsValue: [String] {
        var out = latinForms.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue)
        for (s, v) in scriptShares.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !s.isLatinForm && v > 0 {
            out.append("\(s.rawValue):\(String(format: "%g", v))")
        }
        return out
    }

    /// Write what this interview answered into a project's or a collection's layer, and remove the rest, so it is
    /// read live from above. The mix is "measured from N photos" while it is the classifier's, and the user's once a
    /// share was corrected, an unmeasured kind given, or a script's share set.
    func apply(to layer: inout SettingsLayer, now: Date = Date()) {
        func source(_ key: SettingsKey) -> SettingsSource {
            if let p = startingPoint, filled.contains(key.rawValue) { return .startingPoint(p.name, now) }
            return .setByUser(now)
        }
        func put(_ key: SettingsKey, _ value: SettingsValue) {
            if isAnswered(key) { layer.set(key, value, source: source(key)) } else { layer.reset(key) }
        }
        let (mix, strata) = mixAndStrata()
        let groupAnswered = [SettingsKey.mix, .scripts, .period, .languages].contains(where: isAnswered)
        if groupAnswered {
            // The whole group goes into this layer, empty values included, so nothing in it is read from above.
            let given = correctedMix || unmeasuredShares.values.contains { $0 > 0 } || scriptShares.values.contains { $0 > 0 }
                || mixInheritedFrom != nil
            let mixSource: SettingsSource
            if let m = measurement, !given { mixSource = .measured(m.date, sample: m.sample) } else { mixSource = .setByUser(now) }
            if mix.isEmpty && strata.isEmpty {
                // Nothing measured or given anywhere: the built-in mix, not an empty one.
                layer.reset(.mix); layer.reset(.strata)
            } else {
                layer.set(.mix, .numbers(mix), source: mixSource)
                layer.set(.strata, .numbers(strata), source: mixSource)
            }
            layer.set(.scripts, .strings(scriptsValue), source: .setByUser(now))
            layer.set(.period, .string(periodText), source: .setByUser(now))
            layer.set(.languages, .strings(languages), source: .setByUser(now))
        } else {
            for key in Self.mixGroup { layer.reset(key) }
        }
        put(.batchCeilingUSD, .double(max(0, batchCeilingUSD)))
        put(.hours, .double(max(1, hours)))
        put(.checkingMinutes, .double(max(0, checkingMinutes)))
        if isAnswered(.priorities) {
            let ranked = order.filter { (weights[$0] ?? 0) > 0 }
                .sorted { (weights[$0] ?? 0) > (weights[$1] ?? 0) }
            layer.set(.priorities, .strings(ranked.map(\.rawValue)), source: source(.priorities))
            layer.set(.weights, .numbers(Dictionary(uniqueKeysWithValues: ranked.map { ($0.rawValue, weights[$0] ?? 0) })),
                      source: source(.priorities))
        } else {
            layer.reset(.priorities); layer.reset(.weights)
        }
        put(.preference, .string(preference.rawValue))
        put(.straightenReadingCopy, .bool(straightenReadingCopy))
        put(.staysOnMac, .bool(staysOnMac))
    }
}
