import ArchiveCore
import Foundation

// MARK: - Improve OCR: the readers ranked for one kind of page (W44.reocr-processor)

/// The readers the Improve OCR dialog offers for one kind of page, best measured first, from the same rule table, pair
/// matrix and feasibility checks the settings solver uses (`execution-plans/reocr/00-plan.md` §4; W46.settings-solver).
/// Pure: the caller reads the Keychain and the settings layers once, outside any view body, and passes the resources.
///
/// Only routes the app can run are rows. A cluster reading is an export and import, never one click, so those routes
/// are listed apart. A row that needs a key the user has not set stays a row, its Run disabled by `readiness`. A
/// measured figure the table lacks reads "not measured", never zero, and an unknown price stays unknown.
struct ReOCRRanking: Sendable {
    /// Where a row's figure comes from: the stage rule for that kind (`13-stage-rules/04-reading.md` §3).
    struct Metric: Sendable, Equatable {
        /// The rule table's figure key: `typewritten`, `printed`, `hands16`, `public:L4`, or `overall` as the fallback.
        let key: String
        /// The pair matrix's set and group for ties, nil where it holds none.
        let pairSet: String?
        let pairGroup: String?
        /// "strict NES on the owner's 50 typewritten pages" as the dialog says it.
        let label: String
        /// True when the kind itself is not measured and rows are ranked on the overall figure instead.
        let isFallback: Bool
    }

    enum Readiness: Sendable, Equatable {
        case ready
        /// Run is disabled; the reason is the solver's ("needs a Gemini key", "this batch stays on the Mac").
        case needsSetup(String)
    }

    /// Each row against the reference: the best measured row that can run now (the solver judges a tie against the
    /// best usable route only), else the best measured row.
    enum Tie: Sendable, Equatable {
        case reference
        /// Inside the pair's rerun floor of the reference, with the paired gap when the matrix has one.
        case tied(OCRPairMatrixGapText?)
        /// Measured better than the reference beyond the floor: a row that cannot run now.
        case ahead(OCRPairMatrixGapText?)
        case behind(OCRPairMatrixGapText?)
        case notMeasured
    }

    struct Row: Sendable, Identifiable {
        let id: String
        let name: String
        /// `provider|model` for a hosted route, nil for Apple Vision on this Mac.
        let appRoute: String?
        let provider: LLMProvider
        let modelID: String
        /// NES 0-100 on `metric`; nil is "not measured".
        let figure: Double?
        /// "50" or "16 (0 failed)" as the table gives it; nil when the table gives no sample.
        let sample: String?
        let caveats: [String]
        /// USD per 1,000 image pages at the list price; 0 on this Mac; nil when the table has no price.
        let usdPer1000: Double?
        /// This selection's cost; nil when the price is unknown.
        let estimateUSD: Double?
        let readiness: Readiness
        var tie: Tie
        var isCurrent: Bool
    }

    struct LeftOut: Sendable, Equatable {
        let id: String
        let name: String
        let reason: String
    }

    let kind: OCRPageKind
    let pages: Int
    let metric: Metric
    let rows: [Row]
    /// Cluster readings for this kind: an export/import action, never a Run.
    let institutional: [LeftOut]
    /// Measured routes the dialog does not offer, each with its reason (not in the app, a stage rule).
    let leftOut: [LeftOut]
    /// The file's current reader as its header names it, when no row matches it: "Gemini · Gemini 2.5 Flash".
    let currentUnmatched: String?
    /// The row the solver's rule would pick: of the ready rows tied with the reference, the cheaper, then the better
    /// measured. nil when no measured row can run. A suggestion, never a promise that this page will read better.
    let suggestedID: String?

    // MARK: Building

    /// The ranked readers for `pages` image pages of `kind`. `current` is the page's reader from its header
    /// (display strings only: they mark a row, they never choose a route). `staysOnMac` is the batch's switch.
    static func rank(kind: OCRPageKind, pages: Int, table: SettingsRouteTable, pairs: OCRPairMatrix?,
                     resources: SettingsResources, staysOnMac: Bool, readingFallback: Bool = true,
                     current: PDFReaderProvenance? = nil,
                     builtInModels: [LLMModel] = OCRCascade.candidates + LLMModel.appleVisionModels) -> ReOCRRanking {
        let metric = metric(for: kind, table: table, readingFallback: readingFallback, builtInModels: builtInModels)
        var answers = SettingsAnswers()
        answers.pages = max(1, pages)
        answers.staysOnMac = staysOnMac
        answers.readingFallback = readingFallback
        let solver = SettingsSolver(table: table, pairs: pairs, resources: resources, answers: answers)
        let stage = table.stage("reading")
        var rows: [Row] = []
        var institutional: [LeftOut] = []
        var leftOut: [LeftOut] = []
        for r in stage?.routes ?? [] where !r.afterTraining {
            if r.stages != nil { continue }   // a cascade is a batch route, not one reader for these pages
            if let rule = ruleExclusion(r, kind: kind) {
                leftOut.append(LeftOut(id: r.id, name: r.name, reason: rule))
                continue
            }
            if !r.offered {
                let c = r.conditions.first { $0.hasPrefix("not offered") || $0.hasPrefix("never offered") } ?? "not offered"
                leftOut.append(LeftOut(id: r.id, name: r.name, reason: c))
                continue
            }
            guard let (provider, model) = executable(r, builtInModels: builtInModels) else {
                if r.family == .cluster {
                    institutional.append(LeftOut(id: r.id, name: r.name, reason: "an institutional computing run: export the "
                                                 + "pages, run them there and import the text"))
                } else {
                    leftOut.append(LeftOut(id: r.id, name: r.name, reason: "not in the app yet"))
                }
                continue
            }
            let blockers = readiness(r, provider: provider, solver: solver, resources: resources)
            let per: Double? = r.family == .mac ? 0 : r.listUSDPer1000
            rows.append(Row(id: r.id, name: r.name, appRoute: r.appRoute, provider: provider, modelID: model.id,
                            figure: figure(r, metric), sample: sample(r, metric), caveats: r.caveats,
                            usdPer1000: per, estimateUSD: per.map { $0 * Double(pages) / 1000 },
                            readiness: blockers.first.map(Readiness.needsSetup) ?? .ready,
                            tie: .notMeasured, isCurrent: false))
        }
        // Best measured first; equal figures cheaper first; not measured last, by name.
        rows.sort { a, b in
            switch (a.figure, b.figure) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let pa = a.usdPer1000 ?? .infinity, pb = b.usdPer1000 ?? .infinity
                return pa != pb ? pa < pb : a.name < b.name
            }
        }
        let measured = rows.indices.filter { rows[$0].figure != nil }
        let ref = measured.first { rows[$0].readiness == .ready } ?? measured.first
        var suggested: String?
        if let ref, let refFigure = rows[ref].figure {
            let lead = rows[ref]
            rows[ref].tie = .reference
            for i in measured where i != ref {
                rows[i].tie = tie(rows[i], rows[i].figure!, lead, refFigure, metric: metric, pairs: pairs, kind: kind)
            }
            if lead.readiness == .ready {
                let pool = [ref] + measured.filter { i in
                    guard i != ref, rows[i].readiness == .ready, case .tied = rows[i].tie else { return false }
                    return true
                }
                suggested = pool.min { a, b in
                    let pa = rows[a].usdPer1000 ?? .infinity, pb = rows[b].usdPer1000 ?? .infinity
                    return pa != pb ? pa < pb : rows[a].figure! > rows[b].figure!
                }.map { rows[$0].id }
            }
        }
        var unmatched: String?
        if let current {
            if let i = rows.firstIndex(where: { matches($0, current, builtInModels: builtInModels) }) {
                rows[i].isCurrent = true
            } else {
                unmatched = "\(current.provider) · \(current.model)"
            }
        }
        return ReOCRRanking(kind: kind, pages: pages, metric: metric, rows: rows, institutional: institutional,
                            leftOut: leftOut, currentUnmatched: unmatched, suggestedID: suggested)
    }

    /// The figure each kind is ranked on. Handwriting ranks on the 16 re-adjudicated hands (rule
    /// hands-ranked-on-hands16); forms on the public set's L4 where measured, else the overall figure, labelled.
    static func metric(for kind: OCRPageKind, table: SettingsRouteTable, readingFallback: Bool = true,
                       builtInModels: [LLMModel] = OCRCascade.candidates + LLMModel.appleVisionModels) -> Metric {
        switch kind {
        case .typewritten:
            return Metric(key: "typewritten", pairSet: "owner96", pairGroup: "typewritten",
                          label: "strict NES on the owner's typewritten pages", isFallback: false)
        case .printed:
            return Metric(key: "printed", pairSet: "owner96", pairGroup: "printed",
                          label: "strict NES on the owner's printed pages", isFallback: false)
        case .handwritten:
            return Metric(key: "hands16", pairSet: "owner96", pairGroup: "hands16",
                          label: "NES on the owner's 16 handwritten pages", isFallback: false)
        case .forms:
            let strata = table.stage("reading")?.kindStrata["forms"] ?? ["L4"]
            let stratum = strata.first ?? "L4"
            let measured = table.stage("reading")?.routes.contains { r in
                executable(r, builtInModels: builtInModels) != nil
                    && r.publicStrict(stratum) != nil
            } ?? false
            if measured {
                return Metric(key: "public:\(stratum)", pairSet: "public895", pairGroup: stratum,
                              label: "strict NES on the public set's forms and tables (\(stratum))", isFallback: false)
            }
            // The solver's overall score: answered when a failed page goes on to a second reader, else strict.
            let score = readingFallback ? "answered" : "strict"
            return Metric(key: "overall:\(score)", pairSet: "owner96", pairGroup: "all",
                          label: "not measured on forms: ranked by \(score) NES on all the owner's pages", isFallback: true)
        }
    }

    // MARK: Pieces

    /// The provider and built-in model a route runs as in this app, or nil when the app cannot run it. Built-in
    /// models only: a custom model reusing an id is not the model that was measured.
    static func executable(_ r: SettingsRouteTable.Route, builtInModels: [LLMModel]) -> (LLMProvider, LLMModel)? {
        if r.id == "apple-vision" {
            return builtInModels.first { $0.provider == .appleVision }.map { (.appleVision, $0) }
        }
        guard let ar = r.appRoute else { return nil }
        let parts = ar.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let provider = LLMProvider.allCases.first(where: { $0.rawValue.lowercased() == parts[0] }),
              let model = builtInModels.first(where: { $0.provider == provider && $0.id == parts[1] })
        else { return nil }
        return (provider, model)
    }

    /// A stage rule that keeps a route out for this kind.
    static func ruleExclusion(_ r: SettingsRouteTable.Route, kind: OCRPageKind) -> String? {
        if r.id == "apple-fm-27" { return "the stage rule no-apple-fm" }
        if kind == .handwritten, r.id == "apple-vision" {
            return "handwriting is not read with Apple Vision (owner call 4)"
        }
        return nil
    }

    static func figure(_ r: SettingsRouteTable.Route, _ m: Metric) -> Double? {
        if m.key.hasPrefix("public:") { return r.publicStrict(String(m.key.dropFirst("public:".count))) }
        if m.key == "overall:answered" { return r.figure("overall") }
        if m.key == "overall:strict" { return r.strict("overall") }
        return r.figure(m.key)
    }

    static func sample(_ r: SettingsRouteTable.Route, _ m: Metric) -> String? {
        if m.key.hasPrefix("public:") {
            let s = String(m.key.dropFirst("public:".count))
            if case .string(let n)? = r.figures["public"]?[s]?.array?.last { return n }
            return nil
        }
        guard let f = r.figures[m.key.hasPrefix("overall:") ? "overall" : m.key] else { return nil }
        let n: String?
        switch f["n"] {
        case .number(let x)?: n = String(Int(x))
        case .string(let s)?: n = s
        default: n = nil
        }
        if let failed = f["failed"]?.double, let n { return "\(n) (\(Int(failed)) failed)" }
        return n
    }

    static func tie(_ row: Row, _ f: Double, _ lead: Row, _ leadFigure: Double, metric: Metric,
                    pairs: OCRPairMatrix?, kind: OCRPageKind) -> Tie {
        if let set = metric.pairSet, let group = metric.pairGroup,
           let g = pairs?.gap(set, group, row.id, lead.id, score: "strict") {
            let text = OCRPairMatrixGapText(g)
            return g.underFloor ? .tied(text) : (g.delta > 0 ? .ahead(text) : .behind(text))
        }
        // No per-page scores for this pair: the solver's floors alone (0 between two routes on this Mac).
        let bothMac = row.provider == .appleVision && lead.provider == .appleVision
        let floor = bothMac ? 0 : (kind == .handwritten ? SettingsSolver.readingHandsFloor : SettingsSolver.readingHostedFloor)
        if abs(leadFigure - f) < floor { return .tied(nil) }
        return f > leadFigure ? .ahead(nil) : .behind(nil)
    }

    /// Why the row cannot run now. The solver's checks (the batch stays on the Mac, a family not to send pages to),
    /// except access: the table lets any one of several keys reach a route (Gemini through OpenRouter too), but the app
    /// runs the row with its own provider, so that provider's key is the one it needs.
    static func readiness(_ r: SettingsRouteTable.Route, provider: LLMProvider, solver: SettingsSolver,
                          resources: SettingsResources) -> [String] {
        // The access line is "needs a Gemini or OpenRouter key", "needs the ChatGPT plan" or "needs a cluster";
        // memory and download lines stay.
        var out = solver.blockers(r, stage: "reading").filter {
            !$0.hasPrefix("needs ") || $0 == "needs a download" || $0.contains(" GB")
        }
        if provider != .appleVision, out.isEmpty {
            let key = provider.rawValue.lowercased()
            if !resources.keys.contains(key) { out.append("needs a \(SettingsSolver.keyName(key)) key") }
        }
        return out
    }

    /// Marks the row the header names. Display strings only, matched against built-in models' names.
    static func matches(_ row: Row, _ current: PDFReaderProvenance, builtInModels: [LLMModel]) -> Bool {
        guard row.provider.rawValue.caseInsensitiveCompare(current.provider) == .orderedSame else { return false }
        if row.provider == .appleVision { return true }
        return builtInModels.contains { $0.provider == row.provider && $0.id == row.modelID
            && $0.displayName.caseInsensitiveCompare(current.model) == .orderedSame }
    }
}

/// A pair-matrix gap as the dialog prints it, kept apart from the matrix type so rows stay `Equatable`.
struct OCRPairMatrixGapText: Sendable, Equatable {
    let citation: String
    let delta: Double
    let underFloor: Bool

    init(_ g: OCRPairMatrix.Gap) {
        citation = g.citation
        delta = g.delta
        underFloor = g.underFloor
    }
}

// MARK: - Grouping a selection by kind

/// One image page the dialog would re-read: its file, its pair, and its kind with where the kind came from.
struct ReOCRPageChoice: Sendable, Equatable, Hashable {
    enum KindOrigin: String, Sendable, Codable {
        /// The text page's `Kind:` header line.
        case header
        /// The classifier on the image page, provisional until the person accepts it.
        case classifier
        /// The person's choice in the dialog.
        case person
    }

    let fileID: String
    let pairIndex: Int
    var kind: OCRPageKind?
    var origin: KindOrigin?
    /// The classifier's confidence, when it told the kind.
    var confidence: Double?

    /// A classifier call below the routing threshold is not a kind: the page needs the person's choice.
    var settledKind: OCRPageKind? {
        guard let kind else { return nil }
        if origin == .classifier, (confidence ?? 0) < PageKindRouting.minimumConfidence { return nil }
        return kind
    }
}

enum ReOCRGrouping {
    /// The selection's pages by kind, in the dialog's order; pages with no settled kind come last under nil.
    static func groups(_ pages: [ReOCRPageChoice]) -> [(kind: OCRPageKind?, pages: [ReOCRPageChoice])] {
        let order: [OCRPageKind?] = OCRPageKind.allCases.map { Optional($0) } + [nil]
        let byKind = Dictionary(grouping: pages) { $0.settledKind }
        return order.compactMap { k in byKind[k].map { (kind: k, pages: $0) } }
    }
}
