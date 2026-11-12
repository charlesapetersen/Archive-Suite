import Foundation

// MARK: - The settings sheet, shape A (W46.settings-sheet)

/// What the settings sheet shows, built from the rule table, the solver and the resolved layers, with no view and no
/// Keychain read, so the self-test reads exactly what the sheet draws (`12-settings-design.md` §3.3; the stage notes'
/// wording in `13-stage-rules`). Every figure comes from `settings-routes.json` with its sample and its truth; the
/// words around it are the sheet's, written for a reader who knows nothing of the bench.
struct SettingsSheetModel {
    /// What the app runs now, read by the caller outside any view body.
    struct Running: Sendable {
        /// The reading route's id in the table (`apple-vision`, or a row whose `app_route` is the run's
        /// `provider|model`); nil when the table has no row for it.
        var readingRouteID: String?
        var readingName: String
        var segmentation: SegmentationApproach
    }

    struct Limit: Identifiable {
        let id: String
        let label: String
        let value: String
        let source: String
    }

    struct Total: Identifiable {
        let id: String
        let label: String
        let value: String
        let detail: String?
    }

    struct PartRow: Identifiable {
        let id: String
        let label: String
        /// The route reading this part, or nil when none does.
        let routeName: String?
        let figure: String
        let sample: String?
        /// A label the stage note asks for ("conditional on the truth", "ranks nothing yet", "unmeasured").
        let label2: String?
        let warning: Bool
    }

    struct Better: Identifiable {
        let id: String
        let name: String
        let gain: String
        let reason: String
    }

    struct Alternative: Identifiable {
        let id: String
        let name: String
        let family: String
        let figure: String
        let cost: String
    }

    struct Option: Identifiable {
        let id: String
        let name: String
        /// Why it cannot be chosen; nil when it can.
        let blocked: String?
    }

    struct Card: Identifiable {
        let id: String
        let title: String
        let about: String
        let weight: String
        let routeID: String?
        let routeName: String
        let family: String
        let isCustom: Bool
        /// A layer holds an override for this card, even one naming a route the table no longer has.
        let hasOverride: Bool
        /// Why the card shows what it shows, in words.
        let why: String
        /// The solver's own sentence, naming its evidence row.
        let evidence: String
        let parts: [PartRow]
        let cost: String
        let time: String
        let memory: String
        let labels: [String]
        let caveats: [String]
        let better: [Better]
        let alternatives: [Alternative]
        let options: [Option]
        /// The app's own pick when the card is Custom, for the way back.
        let appPick: String?
        /// What Process Files runs now, when it is not the card's route.
        let runsNow: String?
        /// The run setting the card's route can be applied to, when it is not the one in use.
        let apply: Apply?
        let sources: [String]
    }

    enum Apply: Equatable {
        case segmentation(SegmentationApproach)
        case reading(appRoute: String)
        case appleVision
    }

    struct RuleRow: Identifiable {
        let id: String
        let text: String
        let source: String?
    }

    struct SwitchRow: Identifiable {
        let id: String
        let key: SettingsKey
        let label: String
        let isOn: Bool
        let source: String
        /// Said when the run does not yet follow the switch.
        let note: String?
    }

    struct RuleStage: Identifiable {
        let id: String
        let title: String
        let text: String
        let switches: [SwitchRow]
        let rules: [RuleRow]
        let source: String?
    }

    let table: SettingsRouteTable
    let answers: SettingsAnswers
    let resources: SettingsResources
    let solution: SettingsSolution
    /// The solution with no override, for the way back and for what a Custom card gives up.
    let appSolution: SettingsSolution
    let limits: [Limit]
    let totals: [Total]
    let toRelax: [String]
    let cards: [Card]
    let ruleStages: [RuleStage]

    /// The stage cards' override keys, one per card.
    static func overrideKey(_ stage: String) -> SettingsKey { .override(stage: stage, part: "all") }

    static let cardStages = SettingsSolver.stageOrder
    /// The no-choice stages the rules tab shows (`13-stage-rules` notes 01, 02, 03, 05, 06, 11).
    static let ruleStageIDs = ["reading-copy", "ocr-input", "layout", "placement", "marks", "capture"]

    init(table: SettingsRouteTable, pairs: OCRPairMatrix?, resolver: SettingsResolver, macMemoryGB: Double,
         pages: Int, spentThisMonthUSD: Double = 0, running: Running) {
        self.table = table
        let resources = resolver.resources(macMemoryGB: macMemoryGB)
        let base = resolver.answers(pages: pages, spentThisMonthUSD: spentThisMonthUSD)
        var answers = base
        var custom: [String: String] = [:]
        var held = Set<String>()
        for stage in Self.cardStages {
            guard let id = resolver.resolve(Self.overrideKey(stage)).value.string, !id.isEmpty else { continue }
            held.insert(stage)   // even a route the table no longer has, so the way back can clear it
            if table.stage(stage)?.route(id) != nil {
                answers.onlyRoutes[stage] = [id]
                custom[stage] = id
            }
        }
        self.answers = answers
        self.resources = resources
        let solution = SettingsSolver(table: table, pairs: pairs, resources: resources, answers: answers).solve()
        let appSolution = custom.isEmpty ? solution
            : SettingsSolver(table: table, pairs: pairs, resources: resources, answers: base).solve()
        self.solution = solution
        self.appSolution = appSolution

        let words = Words(table: table, answers: answers, resources: resources)
        limits = Self.limits(resolver, answers: answers, words: words)
        totals = Self.totals(solution, answers: answers, words: words)
        toRelax = Self.relax(solution, answers: answers, words: words)
        cards = Self.cardStages.compactMap { stage in
            table.stage(stage).map {
                Self.card($0, solution: solution, app: appSolution, custom: custom[stage], held: held.contains(stage),
                          answers: answers, running: running, words: words)
            }
        }
        ruleStages = Self.ruleStageIDs.compactMap { id in table.stage(id).map { Self.ruleStage($0, resolver: resolver) } }
    }

    // MARK: Limits and totals

    private static func limits(_ r: SettingsResolver, answers a: SettingsAnswers, words: Words) -> [Limit] {
        let habit = r.resolve(.moneyHabit)
        let ceilingSource: ResolvedSetting = (habit.value.string == MoneyHabit.none.rawValue) ? habit : r.resolve(.batchCeilingUSD)
        let ceiling: String = {
            guard let c = a.ceilingUSD else { return "No ceiling" }
            return c == 0 ? "Nothing: free choices only" : String(format: "$%.2f", c)
        }()
        let weights = SettingsSolver.stageOrder.map { s -> String in
            let w = SettingsSolver(table: words.table, pairs: nil, resources: words.resources, answers: a).weight(s)
            return "\(words.stageWord(s)) \(Int(w.rounded()))"
        }.joined(separator: ", ")
        return [
            Limit(id: "ceiling", label: "Most to spend on this batch", value: ceiling, source: ceilingSource.sourceText),
            Limit(id: "hours", label: "How long it may run", value: SettingsKey.hours.describe(.double(a.hours)),
                  source: r.resolve(.hours).sourceText),
            Limit(id: "preference", label: "When two choices are close",
                  value: SettingsKey.preference.describe(.string(a.preference.rawValue)),
                  source: r.resolve(.preference).sourceText),
            Limit(id: "priorities", label: "What matters most",
                  value: a.priorities.isEmpty ? "nothing ranked"
                    : a.priorities.map(\.label).joined(separator: ", then ") + " (counts out of 100: \(weights))",
                  source: r.resolve(.priorities).sourceText),
            Limit(id: "staysOnMac", label: "Pages stay on this Mac", value: a.staysOnMac ? "Yes" : "No",
                  source: r.resolve(.staysOnMac).sourceText),
        ]
    }

    private static func totals(_ s: SettingsSolution, answers a: SettingsAnswers, words: Words) -> [Total] {
        let planInUse = s.picks.contains { p in
            guard let r = p.route, p.flag == nil else { return false }
            return r.family == .plan && SettingsSolver(table: words.table, pairs: nil, resources: words.resources,
                                                       answers: a).access(r).viaPlan
        }
        var out = [
            Total(id: "money", label: "Money for this batch", value: words.money(s.usd),
                  detail: "\(Self.count(a.pages, "page")), at list prices"),
            Total(id: "time", label: "It takes about", value: words.hours(s.hours),
                  detail: s.hours > a.hours + 1e-9 ? "more than the \(words.hours(a.hours)) allowed" : "within the \(words.hours(a.hours)) allowed"),
        ]
        if let w = s.weightedAccuracy {
            out.append(Total(id: "accuracy", label: "Overall accuracy", value: String(format: "%.0f of 100", w),
                             detail: "reading, finding documents, dates and names together, each counted as much as you said it matters"))
        }
        out.append(Total(id: "plan", label: "Your subscription plan", value: planInUse ? "In use" : "Not used",
                         detail: planInUse ? "its allowance is used, not money" : nil))
        return out
    }

    private static func relax(_ s: SettingsSolution, answers a: SettingsAnswers, words: Words) -> [String] {
        var out: [String] = []
        if s.hours > a.hours + 1e-9 {
            out.append("Nothing fits in \(words.hours(a.hours)): allow about \(words.hours(s.hours)) and the cheapest usable choices will finish.")
        }
        if let c = a.ceilingUSD, s.usd > c + 1e-9 {
            out.append("The cheapest usable choices cost \(words.money(s.usd)), over your \(words.money(c)).")
        }
        // One line a route: the batch's reader is also listed under each kind it reads.
        var seen = Set<String>()
        for p in s.picks {
            for b in p.better where b.isLimit && seen.insert("\(p.stage)|\(b.id)").inserted {
                out.append("\(words.limitPhrase(b.reason)) to let \(words.name(p.stage, b.id)) "
                           + "\(words.verb(p.stage)) \(words.partObject(p.stage, p.part)).")
            }
        }
        return out
    }

    // MARK: Cards

    private static func card(_ stage: SettingsRouteTable.Stage, solution s: SettingsSolution, app: SettingsSolution,
                             custom: String?, held: Bool, answers a: SettingsAnswers, running: Running,
                             words: Words) -> Card {
        let picks = s.picks.filter { $0.stage == stage.id }
        let leadPart = ["dating": "step 1", "entities": "correspondence-typed"][stage.id] ?? "all"
        let lead = picks.first { $0.part == leadPart } ?? picks.first
        let route = lead?.route
        let solver = SettingsSolver(table: words.table, pairs: nil, resources: words.resources, answers: a)
        let weight = solver.weight(stage.id)
        let rank = a.priorities.firstIndex { $0.stage == stage.id }
        let weightText = rank.map { "\(Self.ordinal($0 + 1)) in what matters most; counts \(Int(weight.rounded())) of 100" }
            ?? "not ranked; counts nothing toward the overall figure"

        let usd = picks.reduce(0) { $0 + $1.usd }
        let hours = picks.reduce(0) { $0 + $1.hours }
        let usedRoutes = Self.unique(picks.compactMap { $0.flag == nil ? $0.route : nil })
        let familyText = usedRoutes.isEmpty || route?.id == "none" ? "nothing runs"
            : Self.unique(usedRoutes.map { words.family($0.family) }).joined(separator: " and ")

        var labels: [String] = []
        for r in usedRoutes where r.id.contains("3.8") && r.caveats.contains(where: { $0.contains("3.7") }) {
            labels.append("\(r.name): these figures were measured with Gemini 3.7 Flash, the model before it, and are "
                          + "labelled as 3.7's; Gemini 3.8 was not run on this.")
        }
        if stage.id == "segmentation" {
            labels.append("The figure assumes about 20 seconds to check each boundary; nobody has timed it yet.")
        }
        if stage.id == "entities", let p = lead, !p.shown {
            labels.append("Names are not among what matters most for this collection, so they are not shown"
                          + (p.route.map { $0.family != .mac && $0.id != "none" } == true
                             ? "; the cloud reader still finds them with its tagging call, at no extra cost." : "."))
        }

        let parts = Self.parts(stage, picks: picks, answers: a, words: words)
        // The solver ranks segmentation on the no-checking figure, so a gain is read against that, not the shown one.
        let base = stage.id == "segmentation" ? route.flatMap(solver.segmentationFigure) : lead?.figure
        let better = (lead?.better ?? []).map { b in
            Better(id: b.id, name: words.name(stage.id, b.id),
                   gain: base.map { words.gain(stage.id, b.figure - $0) } ?? words.figure(stage.id, b.figure),
                   reason: b.isLimit ? words.limitPhrase(b.reason).lowercased() : words.reason(b.reason))
        }
        let blocked = s.blocked[stage.id] ?? [:]
        let appBlocked = app.blocked[stage.id] ?? [:]
        let pickFigure = route.flatMap { words.mainFigure(stage, $0, solver: solver) }
        let alternatives = stage.routes
            .filter { !$0.afterTraining && $0.offered && $0.id != route?.id && appBlocked[$0.id] == nil }
            .compactMap { r -> (SettingsRouteTable.Route, Double)? in words.mainFigure(stage, r, solver: solver).map { (r, $0) } }
            .sorted { abs($0.1 - (pickFigure ?? 0)) < abs($1.1 - (pickFigure ?? 0)) }
            .prefix(3)
            .map { r, v in
                Alternative(id: r.id, name: r.name, family: r.id == "none" ? "nothing runs" : words.family(r.family),
                            figure: r.id == "none" ? "no names found"
                                : r.family == .manual ? "you check every boundary yourself" : words.figure(stage.id, v),
                            cost: words.per1000(solver.usdPer1000(r, stage: stage.id), unit: stage.unit))
            }
        // Names on this Mac run only when names are ranked (owner call 11), which the solver applies by leaving them out.
        let namesUnranked = stage.id == "entities" && !a.priorities.contains(.names)
        let options = stage.routes.filter { !$0.afterTraining && $0.offered && words.mainFigure(stage, $0, solver: solver) != nil }
            .map { r in
                Option(id: r.id, name: r.name,
                       blocked: appBlocked[r.id]?.first.map(words.reason)
                        ?? (namesUnranked && r.family == .mac ? "on this Mac names are found only when they are among what matters most" : nil))
            }
            .sorted { ($0.blocked == nil ? 0 : 1, $0.name) < ($1.blocked == nil ? 0 : 1, $1.name) }
        _ = blocked

        var why = lead.map { words.why($0) } ?? "Nothing in this stage runs here."
        var appPick: String?
        if let custom {
            let appLead = app.picks.first { $0.stage == stage.id && $0.part == leadPart }
            let pickName = appLead?.route.map { $0.name } ?? "nothing"
            appPick = pickName
            why = "You chose \(words.name(stage.id, custom)) here. The app's own pick is \(pickName)."
            // "No names" runs as asked even though its pick carries the "none" flag.
            if lead?.routeID != custom || (lead?.flag != nil && custom != "none") {
                why += " Your choice cannot run here: \(appBlocked[custom]?.first.map(words.reason) ?? "it has no figure for this batch")."
            }
        }

        // What Process Files runs, where the sheet's pick can be applied to it.
        var runsNow: String?
        var apply: Apply?
        switch stage.id {
        case "segmentation":
            if let r = route, lead?.flag == nil {
                if let approach = r.appRoute.flatMap(SegmentationApproach.init(appRoute:)) {
                    if approach != running.segmentation {
                        runsNow = "Process Files now uses \(running.segmentation.sheetLabel)."
                        apply = .segmentation(approach)
                    }
                } else {
                    runsNow = "The Processor cannot run this one yet; Process Files uses \(running.segmentation.sheetLabel)."
                }
            }
        case "reading":
            if let r = route, lead?.flag == nil, r.id != running.readingRouteID {
                if r.id == "apple-vision" {
                    runsNow = "The Processor reads with \(running.readingName) now."
                    apply = .appleVision
                } else if let ar = r.appRoute, ar.contains("|") {
                    runsNow = "The Processor reads with \(running.readingName) now."
                    apply = .reading(appRoute: ar)
                } else {
                    runsNow = "The Processor cannot run this reader yet; it reads with \(running.readingName)."
                }
            }
        default: break
        }

        var sources = [String]()
        if let n = stage.note { sources.append(n) }
        for r in usedRoutes {
            for f in Self.sourceFiles(r) where !sources.contains(f) { sources.append(f) }
        }

        return Card(
            id: stage.id, title: words.stageTitle(stage.id), about: words.stageAbout(stage.id), weight: weightText,
            routeID: route?.id, routeName: route?.name ?? "Nothing", family: familyText, isCustom: custom != nil,
            hasOverride: held,
            why: why, evidence: lead?.reason ?? "", parts: parts,
            cost: words.cost(usd, routes: usedRoutes, stage: stage, solver: solver, answers: a),
            time: words.time(hours, routes: usedRoutes, stage: stage),
            memory: words.memory(usedRoutes),
            labels: labels, caveats: Self.unique(usedRoutes.flatMap(\.caveats)),
            better: better, alternatives: Array(alternatives), options: options, appPick: appPick,
            runsNow: runsNow, apply: apply, sources: sources)
    }

    private static func parts(_ stage: SettingsRouteTable.Stage, picks: [SettingsPick], answers a: SettingsAnswers,
                              words: Words) -> [PartRow] {
        switch stage.id {
        case "reading":
            var rows: [PartRow] = picks.filter { $0.part != "all" }.map { p in
                let isHands = p.part == "handwritten"
                let sample = p.route.flatMap { words.readingSample($0, part: p.part) }
                return PartRow(
                    id: p.part, label: words.readingPart(p.part), routeName: p.flag == nil ? p.route?.name : nil,
                    figure: p.flag.map(words.flag) ?? p.figure.map { words.figure("reading", $0) } ?? "not read",
                    sample: sample,
                    label2: isHands && p.flag == nil
                        ? "conditional on the truth: the handwriting truth was drafted with Claude and Gemini models, so this is agreement with that draft more than proof"
                        : nil,
                    warning: p.flag != nil)
            }
            let main = picks.first { $0.part == "all" }
            if rows.isEmpty, let main {
                rows.append(PartRow(id: "all", label: "All pages", routeName: main.route?.name,
                                    figure: main.figure.map { words.figure("reading", $0) } ?? words.flag(main.flag ?? ""),
                                    sample: "on the owner's 96 test pages", label2: nil, warning: main.flag != nil))
            }
            for kind in CollectionInterviewAnswers.unmeasuredKinds where (a.mix[kind] ?? 0) > 0
                && stage.kindStrata[kind] == nil && kind != "registers" {
                rows.append(PartRow(id: kind, label: CollectionInterviewAnswers.unmeasuredLabel(kind),
                                    routeName: main?.route?.name, figure: "unmeasured",
                                    sample: nil, label2: "no reader was measured on this kind; the batch's reader reads it",
                                    warning: false))
            }
            return rows
        case "segmentation":
            guard let p = picks.first else { return [] }
            guard let r = p.route else {
                return [PartRow(id: "all", label: "All pages", routeName: nil, figure: words.flag(p.flag ?? ""),
                                sample: nil, label2: nil, warning: true)]
            }
            var rows = [PartRow(id: "all", label: "Your pages, with your checking time", routeName: r.name,
                                figure: p.figure.map { String(format: "%.0f%% of pages in the right document", $0) } ?? "no figure",
                                sample: "measured on 363 pages of two boxes the owner checked", label2: nil, warning: false)]
            if let per100 = r.figure("test-boxes.checks_per_100") {
                rows.append(PartRow(id: "checks", label: "Boundaries to check", routeName: nil,
                                    figure: String(format: "about %.0f in every 100 pages", per100),
                                    sample: nil, label2: nil, warning: false))
            }
            if let after = r.figure("test-boxes.after_checking") {
                rows.append(PartRow(id: "after", label: "After you check them all", routeName: nil,
                                    figure: String(format: "%.0f%% of pages in the right document", after),
                                    sample: nil, label2: nil, warning: false))
            }
            let boxes: [(String, String)] = [("letters", "Letters"), ("magazine", "A magazine, articles within issues"),
                                             ("clippings-mixed", "Clippings mixed with other papers"),
                                             ("manuscripts-public", "Handwritten letters (public)"),
                                             ("typed-gov-public", "Typed government files (public)")]
            for (key, label) in boxes {
                let v = r.figure(key) ?? r.figure("\(key).gap_acc") ?? r.figure("\(key).owner_weighted")
                guard let v else { continue }
                let n = (r.figures[key] ?? r.figures["\(key).gap_acc"] ?? r.figures["\(key).owner_weighted"])?["n"]?.double
                let ranks = key != "magazine" || r.id == "gemini3.8-flash"
                rows.append(PartRow(id: key, label: label, routeName: nil,
                                    figure: String(format: "%.0f%%", v) + (r.figures[key] == nil ? " of boundaries right" : " of pages right"),
                                    sample: n.map { "on \(Int($0)) \(r.figures[key] == nil ? "boundaries" : "pages")" },
                                    label2: ranks ? nil : "ranks nothing yet: this model's instructions do not yet say that an article inside an issue is its own document",
                                    warning: false))
            }
            return rows
        case "dating":
            var rows: [PartRow] = []
            for p in picks {
                guard let r = p.route, p.flag == nil else {
                    let label = ["step 1": "Year written in the text", "step 2": "Year only on the page image",
                                 "step 4": "No year found"][p.part] ?? p.part
                    rows.append(PartRow(id: p.part, label: label, routeName: nil, figure: words.flag(p.flag ?? ""),
                                        sample: nil, label2: nil, warning: false))
                    continue
                }
                func row(_ id: String, _ label: String, _ key: String, _ sample: String, _ note: String? = nil) {
                    guard let v = r.figure(key) else { return }
                    let n = r.figures[key]?["n"]?.double
                    rows.append(PartRow(id: id, label: label, routeName: r.name,
                                        figure: String(format: "%.0f%% get the exact year", v),
                                        sample: n.map { "on \(Int($0)) \(sample)" }, label2: note, warning: false))
                }
                switch p.part {
                case "step 1":
                    row("step 1", "Year written in the text", "in_text", "documents whose year is in the text")
                    row("step 1b", "Year not in the text", "not_in_text", "documents whose year is not in the text")
                case "step 2":
                    row("step 2", "Year only on the page image", "unprinted_122_doc_year",
                        "documents whose text holds no year")
                case "step 4":
                    row("step 4", "No year found: estimated from its folder or neighbours", "not_in_text",
                        "documents whose year is not in the text", "always marked Date Uncertain")
                default: break
                }
            }
            return rows
        case "entities":
            return picks.map { p in
                let label = ["correspondence-typed": "Typed letters", "correspondence-handwritten": "Handwritten letters",
                             "non-correspondence": "Everything that is not a letter"][p.part] ?? p.part
                let n = p.route?.figures["sender"]?["n"]?.double
                return PartRow(id: p.part, label: label, routeName: p.flag == nil ? p.route?.name : nil,
                               figure: p.flag == "none" ? (p.part == "non-correspondence" ? "unmeasured, not run" : "not run")
                                   : p.figure.map { String(format: "finds the sender right about %.0f times in 100", $0 * 100) } ?? "no figure",
                               sample: p.flag == nil ? n.map { "on \(Int($0)) letters" } : nil,
                               label2: nil, warning: false)
            }
        default:
            return []
        }
    }

    // MARK: Rules

    private static func ruleStage(_ stage: SettingsRouteTable.Stage, resolver: SettingsResolver) -> RuleStage {
        let switches: [SwitchRow] = stage.rules.compactMap { rule in
            guard let sw = rule.switchSetting, let key = Self.switchKey(sw.id) else { return nil }
            let resolved = resolver.resolve(key)
            return SwitchRow(id: sw.id, key: key, label: sw.label, isOn: resolved.value.bool ?? sw.defaultValue,
                             source: resolved.sourceText, note: Self.switchPending.contains(key) ? Self.pendingNote : nil)
        }
        return RuleStage(id: stage.id, title: Words.ruleTitle(stage.id), text: Words.ruleText(stage.id),
                         switches: switches,
                         rules: stage.rules.map { RuleRow(id: $0.id, text: $0.text, source: $0.source) },
                         source: stage.note)
    }

    /// Switches the run does not read yet: the new page output (W42.int-s5) applies them.
    static let switchPending: Set<SettingsKey> = [.straightenReadingCopy, .placeHandOnImage]
    static let pendingNote = "Saved with this collection's settings now; the Processor follows it once its new page output is built."

    /// The layered setting a table switch is stored in.
    static func switchKey(_ id: String) -> SettingsKey? {
        switch id {
        case "reading_copy.straighten": return .straightenReadingCopy
        case "place.hand_on_image": return .placeHandOnImage
        default: return nil
        }
    }

    // MARK: Helpers

    static func sourceFiles(_ r: SettingsRouteTable.Route) -> [String] {
        var out: [String] = []
        func add(_ v: JSONValue?) {
            if case .string(let f)? = v?["source"]?["file"], !out.contains(f) { out.append(f) }
        }
        for (_, f) in r.figures.sorted(by: { $0.key < $1.key }) { add(f) }
        add(r.cost)
        add(r.time)
        return out
    }

    private static func unique<T>(_ xs: [T]) -> [T] where T: Hashable {
        var seen = Set<T>()
        return xs.filter { seen.insert($0).inserted }
    }

    private static func unique(_ rs: [SettingsRouteTable.Route]) -> [SettingsRouteTable.Route] {
        var seen = Set<String>()
        return rs.filter { seen.insert($0.id).inserted }
    }

    static func count(_ n: Int, _ noun: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return "\(f.string(from: NSNumber(value: n)) ?? "\(n)") \(noun)\(n == 1 ? "" : "s")"
    }

    static func ordinal(_ n: Int) -> String {
        ["first", "second", "third", "fourth"].indices.contains(n - 1) ? ["first", "second", "third", "fourth"][n - 1] : "\(n)th"
    }
}

// MARK: - The sheet's words

/// Turns the table's ids and the solver's phrases into the sheet's words.
struct SettingsSheetWords {
    let table: SettingsRouteTable
    let answers: SettingsAnswers
    let resources: SettingsResources

    func stageWord(_ s: String) -> String {
        ["reading": "reading", "segmentation": "finding documents", "dating": "dates", "entities": "names"][s] ?? s
    }

    func stageTitle(_ s: String) -> String {
        ["reading": "Reading the text", "segmentation": "Finding where each document begins",
         "dating": "Dates", "entities": "Names"][s] ?? s
    }

    /// The stage notes' sheet texts (04 §"What the sheet shows", 07, 09), shortened where they name the bench.
    func stageAbout(_ s: String) -> String {
        switch s {
        case "reading":
            return "Each reader's accuracy on the owner's 96 test pages (typewritten, printed, handwritten) and, where it "
                + "was run, on public pages of the same kind. Figures within the bench's margin of error count as ties. "
                + "The test pages' text was drafted with Claude and Gemini models, so close figures among those "
                + "families are provisional."
        case "segmentation":
            return "Pages are grouped into documents by a model reading seven pages at a time. The figure is pages in "
                + "exactly the right document, measured on the owner's checked boxes; it is not a forecast for your "
                + "collection. Boundaries the model is unsure of are shown to you to check, and checking every one is "
                + "always possible."
        case "dating":
            return "The year each document was written: from its text first, then from the page image where the text "
                + "has none, then from its folder or its neighbours. A year that is estimated is always marked Date "
                + "Uncertain, and no year is written without the words it came from."
        case "entities":
            return "Who sent each letter, to whom, and from where. Each name is shown with the words it was read from, or "
                + "marked inferred. It comes free with the tagging call on a cloud reader; on this Mac it needs a local "
                + "model and typed pages."
        default: return ""
        }
    }

    static func ruleTitle(_ s: String) -> String {
        ["reading-copy": "The copy you read: turning, straightening, image size",
         "ocr-input": "Cleaning the image before it is read",
         "layout": "Columns and reading order",
         "placement": "Where the text sits on the page image",
         "marks": "Stamps, signatures and notes in the margin",
         "capture": "Taking photos with the phone"][s] ?? s
    }

    /// The stage notes' "Sheet text" (01, 02, 03, 05 in plain words, 06, 11).
    static func ruleText(_ s: String) -> String {
        switch s {
        case "reading-copy":
            return "Pages are turned upright before reading. A page whose lines slope by 1 degree or more is turned level "
                + "after reading, unless you switch Straighten off; nothing is cropped or cut, and marks stay. Dewarping, "
                + "cropping and shading correction are not applied to the page you see."
        case "ocr-input":
            return "Pages are read from the image as captured. No cleaning, binarising or mark removal is applied to what "
                + "a reader sees, and none helped any reader tested."
        case "layout":
            return "Newspapers and other dense multi-column pages are read in regions, column by column. Everything else "
                + "is read as a whole page. Handwriting and registers are never split into regions."
        case "placement":
            return "On typed and printed pages the text is laid over the page image line by line, so you can select and "
                + "search it where it sits; this is free. On handwritten pages the lines are found on the page and the "
                + "reading is fitted to them; a page where the fit is unsure, or whose reader joins its lines into "
                + "paragraphs, gets a separate text page instead."
        case "marks":
            return "Marks (stamps, signatures, handwritten notes): not offered yet. Your page images are never altered to "
                + "hide them, and the page reading includes them where the reader can read them."
        case "capture":
            return "The capture app photographs each page at full sensor quality with the flash off, keeps the original "
                + "JPEG untouched, and tells you when the frame is likely to read badly. Hold the phone still, avoid "
                + "reflections, keep the page edges and only that page in the frame. The Mac reads a copy sized to "
                + "2,048 pixels on the long side at JPEG quality 0.85."
        default: return ""
        }
    }

    func family(_ f: SettingsRouteTable.Family) -> String {
        switch f {
        case .mac: return "this Mac"
        case .cloud: return "a paid service"
        case .plan: return "a subscription plan"
        case .cluster: return "a computing cluster"
        case .manual: return "by hand"
        case .kit: return "trained on your material"
        }
    }

    func name(_ stage: String, _ id: String) -> String { table.stage(stage)?.route(id)?.name ?? id }

    func verb(_ stage: String) -> String {
        ["reading": "read", "segmentation": "group", "dating": "date", "entities": "find names in"][stage] ?? "handle"
    }

    func partObject(_ stage: String, _ part: String) -> String {
        switch stage {
        case "reading":
            return part == "all" ? "your pages" : readingPart(part).lowercased()
        case "segmentation": return "your pages"
        case "dating": return "your documents"
        default: return "your letters"
        }
    }

    func readingPart(_ part: String) -> String {
        switch part {
        case "all": return "All pages"
        case "typewritten": return "Typewritten pages"
        case "printed": return "Printed pages"
        case "handwritten": return "Handwritten pages"
        default:
            let label = PublicStratum.label(part)
            return label == part ? part : label.prefix(1).uppercased() + label.dropFirst()
        }
    }

    func readingSample(_ r: SettingsRouteTable.Route, part: String) -> String? {
        switch part {
        case "typewritten", "printed":
            return r.figures[part]?["n"]?.double.map { "on \(Int($0)) of the owner's test pages" }
        case "handwritten":
            return r.figures["hands16"]?["n"]?.double.map { "on \(Int($0)) of the owner's handwritten test pages" }
        default:
            if case .string(let s)? = r.figures["public"]?[part]?.array?.last, let n = s.split(separator: "/").last {
                return "on \(n) public test pages, whose text was checked independently"
            }
            return nil
        }
    }

    func mainFigure(_ stage: SettingsRouteTable.Stage, _ r: SettingsRouteTable.Route, solver: SettingsSolver) -> Double? {
        switch stage.id {
        case "reading": return answers.readingFallback ? r.figure("overall") : r.strict("overall")
        case "segmentation": return solver.segmentationFigure(r)
        case "dating": return r.figure("not_in_text")
        case "entities": return r.figure("sender") ?? (r.id == "none" ? 0 : nil)
        default: return nil
        }
    }

    func figure(_ stage: String, _ v: Double) -> String {
        switch stage {
        case "reading": return String(format: "%.1f of 100 characters right", v)
        case "segmentation": return String(format: "%.0f%% of pages in the right document", v)
        case "dating": return String(format: "%.0f%% exact year", v)
        case "entities": return String(format: "sender right %.0f in 100", v * 100)
        default: return SettingsSolver.num(v)
        }
    }

    func gain(_ stage: String, _ d: Double) -> String {
        switch stage {
        case "reading":
            return d < 0.05 ? "less than 0.1 more characters right in 100" : String(format: "%.1f more characters right in 100", d)
        case "segmentation": return String(format: "%.0f points more pages in the right document", d)
        case "dating": return String(format: "%.0f points more exact years", d)
        case "entities": return String(format: "%.0f more senders right in 100", d * 100)
        default: return SettingsSolver.num(d)
        }
    }

    func flag(_ f: String) -> String {
        switch f {
        case "needs a download or a key": return "not read here: it needs a downloaded reader or a key"
        case "no figure": return "no figure for this kind"
        case "no reader": return "no reader can run here"
        case "none": return "not run"
        default: return f.prefix(1).uppercased() + f.dropFirst()
        }
    }

    /// The solver's blocker and limit phrases, in the sheet's words.
    func reason(_ r: String) -> String {
        if r == "not in this comparison" { return "you chose another route for this stage" }
        if r == "this batch stays on the Mac" { return "this collection keeps its pages on this Mac" }
        if r == "ties the pick and costs more or is slower" { return "no better within the bench's margin of error, and costs more or is slower" }
        if r.hasPrefix("waits for: ") { return "not ready in the app yet" }
        if r.hasPrefix("not offered by the app") { return "the app does not offer it yet" }
        if r.hasPrefix("never offered") { return "kept only as a measured comparison, not offered" }
        if r.hasPrefix("not offered") { return "not offered" }
        if r.hasPrefix("useful as a disagreement partner") { return "only useful beside another model, not on its own" }
        if r == "not in the app yet" { return "the Processor cannot run it yet" }
        if r.hasPrefix("needs ") {
            return r.replacingOccurrences(of: #"\ba ([AEIOU])"#, with: "an $1", options: .regularExpression)
        }
        // A file the bench names is for the notes, not the sheet's words.
        return r.replacingOccurrences(of: #"\s*\([^)]*\.md[^)]*\)"#, with: "", options: .regularExpression)
    }

    func limitPhrase(_ r: String) -> String {
        if r.hasPrefix("raise the ceiling by ") { return "Raise the most to spend by " + r.dropFirst("raise the ceiling by ".count) }
        if r.hasPrefix("allow about ") { return "Allow about " + r.dropFirst("allow about ".count) }
        return r.prefix(1).uppercased() + r.dropFirst()
    }

    func why(_ p: SettingsPick) -> String {
        let r = p.reason
        if p.flag != nil, p.route == nil { return "Nothing can run this here." }
        if r.contains("free default") { return "The free choice on this Mac: nothing is spent and no page leaves it." }
        if r.contains("no route fits the ceiling and the hours") {
            return "Nothing fits both your spending and your time, so the cheapest choice that can run is used."
        }
        if r.contains("a measured cascade") { return "Two readers together, the second taking the pages the first fails, read better than any one alone." }
        if r.contains(" ties ") {
            let tail = r.contains("cheaper") ? "cheaper."
                : r.contains("faster") ? "faster."
                : r.contains("carry checked evidence") ? "its years come with the words they were read from."
                : r.contains("better where the year is in the text") ? "better where the year is written in the text."
                : "better on the stage's other measures."
            return "As good as the best choice this collection can use, within the bench's margin of error, and " + tail
        }
        if r.contains("is the best route") { return "The best measured choice this collection can use." }
        if r.contains("No names") { return "No names are found for this collection." }
        return "The choice the measurements support for your answers."
    }

    func money(_ x: Double) -> String { x < 0.005 ? "$0" : String(format: "$%.2f", x) }

    func per1000(_ x: Double, unit: String) -> String { x == 0 ? "free" : String(format: "$%.2f per 1,000 \(unit)", x) }

    func hours(_ h: Double) -> String {
        if h < 1.0 / 60 { return "under a minute" }
        if h < 1 { return "\(Int((h * 60).rounded())) minutes" }
        let r = (h * 10).rounded() / 10
        return r == 1 ? "1 hour" : String(format: r == r.rounded() ? "%.0f hours" : "%.1f hours", r)
    }

    func cost(_ usd: Double, routes: [SettingsRouteTable.Route], stage: SettingsRouteTable.Stage, solver: SettingsSolver,
              answers a: SettingsAnswers) -> String {
        guard !routes.isEmpty else { return "nothing" }
        let units = stage.unit == "documents" ? SettingsSheetModel.count(a.documentCount, "document")
            : SettingsSheetModel.count(a.pages, "page")
        if usd >= 0.005 {
            let paid = routes.map { solver.usdPer1000($0, stage: stage.id) }.filter { $0 > 0 }
            let per = Self.uniqueStrings(paid.map { per1000($0, unit: stage.unit) })
            return "\(money(usd)) for \(units)" + (per.isEmpty ? "" : " (\(per.joined(separator: "; ")))")
        }
        if routes.contains(where: { $0.family == .plan }) { return "no money: it uses your plan's allowance" }
        if routes.contains(where: { $0.family == .cluster }) { return "no money: it runs on your cluster" }
        if routes.contains(where: { $0.family == .cloud }) && stage.id == "entities" {
            return "no extra money: it comes with the tagging call"
        }
        return "free"
    }

    static func uniqueStrings(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }

    func time(_ h: Double, routes: [SettingsRouteTable.Route], stage: SettingsRouteTable.Stage) -> String {
        guard !routes.isEmpty else { return "none" }
        let estimated = routes.contains { $0.time?["measured"] != .bool(true) && $0.family != .manual }
        if routes.allSatisfy({ $0.family == .manual }) { return "your own checking time" }
        let place = routes.contains { $0.family == .mac } ? "on this Mac" : routes.contains { $0.family == .cluster } ? "on your cluster" : "waiting on the service"
        let span = h < 1.0 / 60 ? hours(h) : "about \(hours(h))"
        return "\(span) \(place)" + (estimated ? " (an estimate, not timed)" : "")
    }

    func memory(_ routes: [SettingsRouteTable.Route]) -> String {
        let mac = routes.filter { $0.needs.mac || $0.family == .mac }
        guard !mac.isEmpty else { return "none on this Mac" }
        let peaks = mac.compactMap(\.peakGB).filter { $0 > 0 }
        if let p = peaks.max() {
            return String(format: "about %.0f GB of this Mac's memory (%.1f GB measured, plus room to work)",
                          (p + SettingsResources.headroomGB).rounded(.up), p)
        }
        if mac.allSatisfy(\.needs.builtIn) { return "little: built into macOS" }
        return "unmeasured"
    }
}

extension SettingsSheetModel {
    typealias Words = SettingsSheetWords
}

extension SegmentationApproach {
    /// The approach in the sheet's words.
    var sheetLabel: String {
        switch self {
        case .manual: return "no model (you check every boundary)"
        case .claude: return "Claude Sonnet 5.5"
        case .gemini: return "Gemini 3.8 Flash"
        case .openai: return "ChatGPT"
        case .mix: return "Claude and ChatGPT together"
        case .glm: return "GLM-5.3 Flash"
        case .local: return "the trained model on this Mac"
        }
    }
}

// MARK: - The sheet's writes

/// What the sheet writes: a card's override and a rule switch, into the collection when there is an output folder,
/// else into the general settings; and the way back, which clears a card's override from every layer that holds it
/// (the collection, its project, the general settings), so the card is the app's pick again.
@MainActor
struct SettingsSheetWriter {
    let store: SettingsLayerStore
    let folder: URL?

    struct Outcome {
        var ok: Bool
        /// The collection's document as it now stands (unchanged when nothing was written to it).
        var doc: CollectionSettingsDocument?
    }

    func set(_ key: SettingsKey, _ value: SettingsValue, doc: CollectionSettingsDocument?, now: Date = Date()) -> Outcome {
        let source = SettingsSource.setByUser(now)
        if let folder {
            guard let written = store.updateCollection(in: folder, { _ = $0.collection.set(key, value, source: source) })
            else { return Outcome(ok: false, doc: doc) }
            return Outcome(ok: true, doc: written)
        }
        return Outcome(ok: store.setGeneral(key, value, source: source), doc: doc)
    }

    func clear(_ key: SettingsKey, doc: CollectionSettingsDocument?) -> Outcome {
        var current = doc
        var ok = true
        if let folder, current?.collection.entry(key) != nil {
            if let written = store.updateCollection(in: folder, { $0.collection.reset(key) }) { current = written } else { ok = false }
        }
        if let id = current?.projectID, store.project(id)?.entry(key) != nil {
            ok = store.updateProject(id) { $0.reset(key) } && ok
        }
        if store.general.entry(key) != nil { ok = store.resetGeneral(key) && ok }
        return Outcome(ok: ok, doc: current)
    }
}
