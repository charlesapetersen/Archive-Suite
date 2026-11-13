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
        /// The gain it is listed by, largest first.
        let order: Double
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
    /// Said above the totals when a card's pick is not what Process Files runs.
    let notInUse: String?
    let cards: [Card]
    /// The range tab: one chart per card stage (W46.settings-range-view).
    let ranges: [SettingsRangeChart]
    let ruleStages: [RuleStage]

    /// The stage cards' override keys, one per card.
    static func overrideKey(_ stage: String) -> SettingsKey { .override(stage: stage, part: "all") }

    static let cardStages = SettingsSolver.stageOrder
    /// The no-choice stages the rules tab shows (`13-stage-rules` notes 01, 02, 03, 05, 06, 11).
    static let ruleStageIDs = ["reading-copy", "ocr-input", "layout", "placement", "marks", "capture"]

    init(table: SettingsRouteTable, pairs: OCRPairMatrix?, resolver: SettingsResolver, macMemoryGB: Double,
         pages: Int, month: SettingsMonthSpend = .init(), running: Running) {
        self.table = table
        let resources = resolver.resources(macMemoryGB: macMemoryGB)
        let base = resolver.answers(pages: pages, spentThisMonthUSD: month.usd)
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
        limits = Self.limits(resolver, answers: answers, month: month, words: words)
        totals = Self.totals(solution, answers: answers, words: words)
        toRelax = Self.relax(solution, answers: answers, words: words)
        cards = Self.cardStages.compactMap { stage in
            table.stage(stage).map {
                Self.card($0, solution: solution, app: appSolution, custom: custom[stage], held: held.contains(stage),
                          answers: answers, running: running, words: words)
            }
        }
        ranges = Self.ranges(table: table, solution: solution, app: appSolution, answers: answers, cards: cards, words: words)
        let off = cards.filter { $0.apply != nil || $0.runsNow != nil }.map { $0.title.lowercased() }
        notInUse = off.isEmpty ? nil
            : "These totals assume every pick is switched on. Process Files does not use the app's picks yet for "
                + off.joined(separator: " and ") + "; each card below says what it uses now, and its button switches it on."
        ruleStages = Self.ruleStageIDs.compactMap { id in table.stage(id).map { Self.ruleStage($0, resolver: resolver) } }
    }

    // MARK: Limits and totals

    /// A value's source in the sheet's words; the built-in default reads as a setting name otherwise.
    static func sourceWords(_ r: ResolvedSetting) -> String {
        r.layer == nil ? "set by the app (its default)" : r.sourceText
    }

    private static func limits(_ r: SettingsResolver, answers a: SettingsAnswers, month: SettingsMonthSpend,
                               words: Words) -> [Limit] {
        let habit = r.resolve(.moneyHabit)
        let perMonth = habit.value.string == MoneyHabit.perMonth.rawValue
        let ceilingSource: ResolvedSetting = (habit.value.string == MoneyHabit.none.rawValue) ? habit : r.resolve(.batchCeilingUSD)
        let ceiling: String = {
            guard let c = a.ceilingUSD else { return "No ceiling" }
            return c == 0 ? "Nothing: free choices only" : String(format: "$%.2f", c)
        }()
        let solver = SettingsSolver(table: words.table, pairs: nil, resources: words.resources, answers: a)
        let weights = SettingsSolver.stageOrder.filter { solver.weight($0) > 0 }
            .map { "\(words.stageWord($0)) \(Int(solver.weight($0).rounded()))" }.joined(separator: ", ")
        let unweighted = SettingsSolver.stageOrder.filter { solver.weight($0) <= 0 }.map(words.stageWord)
        // W46.settings-ledger: under a monthly limit the batch gets what is left of the month, and the month's spending
        // is shown beside it.
        let monthCeiling = r.resolve(.monthCeilingUSD)
        let batchCap = r.resolve(.batchCeilingUSD)
        let ceilingWords = perMonth
            ? "what is left of the month's limit" + (batchCap.layer == nil ? "" : ", and no more than "
                + String(format: "$%.2f", max(0, batchCap.value.double ?? 0)) + " a batch (" + Self.sourceWords(batchCap) + ")")
            : Self.sourceWords(ceilingSource)
        var out = [
            Limit(id: "ceiling", label: "Most to spend on this batch", value: ceiling, source: ceilingWords),
        ]
        if perMonth {
            let limit = monthCeiling.value.double.map { $0.isFinite ? max(0, $0) : 0 } ?? 0
            out.append(Limit(id: "month", label: "Spent this month",
                             value: month.summary(of: limit),
                             source: "the app's record of what each finished batch cost at list prices; the limit "
                                + Self.sourceWords(monthCeiling)))
        }
        return out + [
            Limit(id: "hours", label: "How long it may run", value: SettingsKey.hours.describe(.double(a.hours)),
                  source: Self.sourceWords(r.resolve(.hours))),
            Limit(id: "preference", label: "When two choices are close",
                  value: [.bestMeasured: "the one that scored higher wins (not the cheaper or faster one)",
                          .cheapestWithinPoint: "the cheaper wins, if within a point",
                          .fastestWithinPoint: "the faster wins, if within a point"][a.preference] ?? "",
                  source: Self.sourceWords(r.resolve(.preference))),
            Limit(id: "priorities", label: "What matters most",
                  value: a.priorities.isEmpty ? "nothing ranked"
                    : a.priorities.map(\.label).joined(separator: ", then ") + " (how much each counts: \(weights)"
                        + (unweighted.isEmpty ? ")" : "; \(unweighted.joined(separator: " and ")) not counted)"),
                  source: Self.sourceWords(r.resolve(.priorities))),
            Limit(id: "staysOnMac", label: "Pages stay on this Mac", value: a.staysOnMac ? "Yes" : "No",
                  source: Self.sourceWords(r.resolve(.staysOnMac))),
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
            Total(id: "time", label: "Machine time", value: "about " + words.hours(s.hours),
                  detail: (s.hours > a.hours + 1e-9 ? "more than the \(words.hours(a.hours)) allowed" : "within the \(words.hours(a.hours)) allowed")
                    + (s.picks.contains { $0.flag == nil && [.cloud, .plan].contains($0.route?.family) }
                        ? "; steps on this Mac run one after another, online ones alongside them" : "")
                    + (Self.checkingHours(s, answers: a).map { "; plus about \(words.hours($0)) of your own checking, not counted in the time allowed" } ?? "")),
        ]
        if let w = s.weightedAccuracy {
            let unread = s.picks.contains { $0.stage == "reading" && $0.flag != nil && $0.part != "all" }
            let byHand = s.pick("segmentation", "all")?.route?.family == .manual
            let solver = SettingsSolver(table: words.table, pairs: nil, resources: words.resources, answers: a)
            let after = s.picks.map { p -> SettingsPick in
                guard p.stage == "segmentation", let r = p.route, let v = r.figure("test-boxes.after_checking") else { return p }
                return SettingsPick(stage: p.stage, part: p.part, route: p.route, figure: v, flag: p.flag, reason: p.reason,
                                    gap: p.gap, better: p.better, fallbackRouteID: p.fallbackRouteID, shown: p.shown,
                                    usd: p.usd, hours: p.hours)
            }
            let wAfter = solver.weightedAccuracy(after)
            out.append(Total(id: "accuracy", label: "Overall accuracy, before your checking",
                             value: String(format: "%.0f of 100", w),
                             detail: (wAfter.map { String(format: "%.0f of 100 after you check every place it asks; ", $0) } ?? "")
                                + "reading, finding documents, dates and names together, each counted as much as you said it matters"
                                + (unread ? "; pages your reading choice cannot read count as 0" : "")
                                + (byHand ? "; finding documents by hand counts as 0 before your checking" : "")))
        }
        out.append(Total(id: "plan", label: "Your subscription plan", value: planInUse ? "In use" : "Not used",
                         detail: planInUse ? "its allowance is used, not money" : nil))
        return out
    }

    /// The user's own time checking boundaries for this batch, at the 20 s a place the design assumes.
    static func checkingHours(_ s: SettingsSolution, answers a: SettingsAnswers) -> Double? {
        guard let per100 = s.pick("segmentation", "all")?.route?.figure("test-boxes.checks_per_100"), per100 > 0 else { return nil }
        return per100 * Double(a.pages) / 100 * 20 / 3600
    }

    private static func relax(_ s: SettingsSolution, answers a: SettingsAnswers, words: Words) -> [String] {
        var out: [String] = []
        if s.hours > a.hours + 1e-9 {
            out.append("Nothing fits in \(words.hours(a.hours)): allow about \(words.hours(s.hours)) and the cheapest usable choices will finish.")
        }
        if let c = a.ceilingUSD, s.usd > c + 1e-9 {
            out.append("The cheapest usable choices cost \(words.money(s.usd)), over your \(words.money(c)).")
        }
        // One line a route (the batch's reader is also listed under each kind it reads), and none for a route whose gain
        // is a tie: spending on a tie buys nothing the measurements can show.
        var seen = Set<String>()
        for p in s.picks {
            let cmp = Self.comparable(p.stage, s, words: words)
            for b in p.better where b.isLimit && seen.insert("\(p.stage)|\(b.id)").inserted {
                guard let r = words.table.stage(p.stage)?.route(b.id), let v = cmp.of(r), let base = cmp.base,
                      v - base >= Self.tieFloor(p.stage) else { continue }
                let change = b.reason.hasPrefix("raise the ceiling by ")
                    ? "Spending " + b.reason.dropFirst("raise the ceiling by ".count) + " more"
                    : b.reason.hasPrefix("allow about ") ? "Allowing about " + b.reason.dropFirst("allow about ".count) : words.limitPhrase(b.reason)
                out.append("\(change) would let \(words.name(p.stage, b.id)) \(words.verb(p.stage)) "
                           + "\(words.partObject(p.stage, p.part)): \(words.gain(p.stage, v - base)).")
            }
        }
        return out
    }

    // MARK: Comparable figures

    /// The figure a stage's pick and every other route are compared on, on one basis: reading on the user's own mix of
    /// typewritten, printed and handwritten pages (a kind the pick does not read counts as 0), the others on the
    /// solver's own figure.
    static func comparable(_ stage: String, _ s: SettingsSolution, words: Words) -> (base: Double?, of: (SettingsRouteTable.Route) -> Double?) {
        guard let st = words.table.stage(stage) else { return (nil, { _ in nil }) }
        let picks = s.picks.filter { $0.stage == stage }
        switch stage {
        case "reading":
            let kinds = ["typewritten", "printed", "handwritten"].filter { (words.answers.mix[$0] ?? 0) > 0 }
            let total = kinds.reduce(0) { $0 + (words.answers.mix[$1] ?? 0) }
            let base: Double? = total > 0
                ? kinds.reduce(0) { acc, k in
                    acc + (words.answers.mix[k] ?? 0) / total * (picks.first { $0.part == k }.flatMap { $0.flag == nil ? $0.figure : 0 } ?? 0)
                }
                : picks.first { $0.part == "all" }?.figure
            return (base, { words.mixAverage($0) })
        case "segmentation":
            return (picks.first?.route.flatMap { words.mainFigure(st, $0, solver: nil) }, { words.mainFigure(st, $0, solver: nil) })
        default:
            let lead = picks.first { $0.part == (stage == "dating" ? "step 1" : "correspondence-typed") }
            return (lead.flatMap { $0.flag == nil || $0.route?.id == "none" ? ($0.figure ?? 0) : nil },
                    { words.mainFigure(st, $0, solver: nil) })
        }
    }

    /// The margin under which two figures count as a tie, as the solver reads it (`SettingsSolver`).
    static func tieFloor(_ stage: String) -> Double {
        switch stage {
        case "reading": return SettingsSolver.readingHostedFloor
        case "segmentation": return SettingsSolver.segmentationTie
        case "dating": return SettingsSolver.datingTie
        default: return SettingsSolver.entitiesTie
        }
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
            labels.append("\(words.display(stage.id, r)): these are Gemini 3.7's figures, measured on the earlier Gemini "
                          + "3.7 Flash with the same instructions; Gemini 3.8 itself has not been tested on this yet.")
        }
        if stage.id == "dating" || stage.id == "entities", route?.id != "none" {
            labels.append("These figures were measured on text read by the programs used in the tests, not by "
                          + "your reading choice above; with a reading program that makes more mistakes, results may be lower.")
            if s.picks.contains(where: { $0.stage == "reading" && $0.part == "handwritten" && $0.flag != nil }) {
                labels.append(stage.id == "dating"
                    ? "Handwritten pages your reading choice cannot read get no date from their text: the year in the text "
                        + "comes from the text your reading choice produces, and only the page-image step looks at the page "
                        + "itself. The figures include handwritten documents, so expect fewer."
                    : "Handwritten pages your reading choice cannot read get no names: the program here works from the "
                        + "text your reading choice produces and does not look at the page again. The figures include "
                        + "handwritten letters, so expect fewer.")
            }
        }
        // W46.seg-g2-offsets: a segmentation figure is one test run; where three were measured, the card gives the range.
        // On the 3.8 card the runs are Gemini 3.7's (owner, 2026-11-06 call 8: no 3.8 offsets run), and it says so.
        if stage.id == "segmentation", let r = route, let rg = r.figures["test-boxes.offset_range"],
           let lo = rg["low"]?.double, let hi = rg["high"]?.double {
            let lent = r.id.contains("3.8") && r.caveats.contains { $0.contains("3.7") }
            labels.append("\(words.display(stage.id, r)): in three test runs " + (lent ? "of Gemini 3.7 Flash " : "")
                          + "that started the groups of pages at "
                          + String(format: "different places, %.1f%% to %.1f%% of pages were in the right document; ", lo, hi)
                          + (lent ? "the figure shown is one of those runs, also Gemini 3.7's, and Gemini 3.8 has had a single run."
                              : "the figure shown is one of those runs."))
        }
        // W46.seg-review-rule (note 07 §3; owner's calls 3 and 7, 2026-11-06): a trained Qwen student reads the
        // user's material zero-shot, carries the manuscript warning, and on this Mac can be checked against an online
        // model so that only the gaps where the two disagree are put to the user.
        if stage.id == "segmentation", let r = route, r.id.hasPrefix("seg-qwen") {
            labels.append("\(words.display(stage.id, r)): zero-shot on your material. It was trained on one owner's "
                          + "archives and has never seen yours, so the owner's figures are not a forecast for your collection.")
            if r.kindRules.contains(where: { $0.hasPrefix("manuscripts: warning") }),
               let m = r.figure("manuscripts-public") ?? stage.route("seg-qwen3.5-2b-8bit")?.figure("manuscripts-public") {
                // Every online route measured there (seg-lincoln-cloud.md: 86.2-90.4%), shipped or lent its figures.
                let online = stage.routes.filter { [.cloud, .plan].contains($0.family) }
                    .compactMap { $0.figure("manuscripts-public") }
                let span = online.min().map { lo in
                    let hi = online.max() ?? lo
                    return hi - lo < 0.5 ? String(format: "%.0f%%", lo) : String(format: "%.0f to %.0f%%", lo, hi)
                }
                labels.append(String(format: "On handwritten manuscripts (a published set of 19th-century letters) it put "
                                     + "%.1f%% of pages in the right document", m)
                              + (span.map { ", against \($0) for the online models" } ?? "")
                              + ": for handwritten material, choose an online model where you can.")
            }
            if r.family == .mac {
                labels.append("On its own its doubts are no guide, so it asks you to check most places. With an online "
                              + "model's key it can be checked against that model (Process Files, Segmentation, \"Check it "
                              + "against\"): it keeps its own boundaries and you check only the places where the two disagree.")
            }
        }
        if stage.id == "entities", let p = lead, !p.shown {
            labels.append("Names are not among what matters most for this collection, so they are not looked for.")
        }

        let handsUnread = s.picks.contains { $0.stage == "reading" && $0.part == "handwritten" && $0.flag != nil }
        let parts = Self.parts(stage, picks: picks, answers: a, words: words, cmpBase: Self.comparable(stage.id, s, words: words).base,
                               handsUnread: handsUnread)
        let blocked = s.blocked[stage.id] ?? [:]
        let appBlocked = app.blocked[stage.id] ?? [:]
        // Every figure the card compares is on one basis (`comparable`): segmentation's no-checking figure, reading on
        // the user's own mix of pages.
        let cmp = Self.comparable(stage.id, s, words: words)
        let base = cmp.base
        let better = (lead?.better ?? []).compactMap { b -> Better? in
            let v = stage.route(b.id).flatMap(cmp.of) ?? b.figure
            let gain = base.map { v - $0 }
            if let gain, gain <= 0 { return nil }   // not better on the user's own mix
            let tie = gain.map { $0 < Self.tieFloor(stage.id) } ?? false
            return Better(id: b.id, name: words.name(stage.id, b.id), order: gain ?? v,
                          gain: stage.id == "segmentation" && base == 0
                            ? String(format: "about %.0f%% of pages in the right document before you check (by hand: none)", v)
                            : stage.id == "entities" && base == 0
                            ? String(format: "about %.0f senders right in 100", v * 100)
                            : gain.map { words.gain(stage.id, $0) } ?? words.figure(stage.id, v),
                          reason: (tie ? "within the margin of error, so no real gain; " : "")
                            + (b.isLimit ? words.limitPhrase(b.reason).lowercased()
                                : b.reason == "not in this comparison"
                                    ? (appBlocked[b.id]?.first.map(words.reason)
                                        ?? (app.pick(stage.id, leadPart)?.routeID == b.id ? "this is the app's pick; you replaced it"
                                            : app.pick(stage.id, leadPart)?.better.first { $0.id == b.id }.map {
                                                $0.isLimit ? words.limitPhrase($0.reason).lowercased() : words.reason($0.reason)
                                            } ?? words.reason(b.reason)))
                                    : words.reason(b.reason)))
        }
        .sorted { $0.order > $1.order }
        // A route on this Mac kept out only by its memory is named even when four others outrank it, so a user with a
        // small Mac sees what a bigger one would do.
        var betterAll = better
        if let base, !betterAll.contains(where: { stage.route($0.id)?.family == .mac }),
           let m = stage.routes.filter({ r in
               r.family == .mac && !r.afterTraining && r.offered
                   && (appBlocked[r.id] ?? []).contains { $0.contains("GB") }
                   && (appBlocked[r.id] ?? []).allSatisfy { $0.contains("GB") || $0.contains("download") }
           }).compactMap({ r in cmp.of(r).map { (r, $0) } }).filter({ $0.1 > base }).max(by: { $0.1 < $1.1 }) {
            betterAll.append(Better(id: m.0.id, name: words.display(stage.id, m.0), order: m.1 - base,
                                    gain: stage.id == "segmentation" && base == 0
                                        ? String(format: "about %.0f%% of pages in the right document before you check (by hand: none)", m.1)
                                        : stage.id == "entities" && base == 0
                                        ? String(format: "about %.0f senders right in 100", m.1 * 100)
                                        : words.gain(stage.id, m.1 - base),
                                    reason: (appBlocked[m.0.id] ?? []).first { $0.contains("GB") }.map(words.reason) ?? "needs a bigger Mac"))
        }
        let pickFigure = base
        let used = Set(usedRoutes.map(\.id))
        let alternatives = stage.routes
            .filter { !$0.afterTraining && $0.offered && !used.contains($0.id) && $0.id != route?.id && appBlocked[$0.id] == nil }
            .compactMap { r -> (SettingsRouteTable.Route, Double)? in cmp.of(r).map { (r, $0) } }
            .sorted { abs($0.1 - (pickFigure ?? 0)) < abs($1.1 - (pickFigure ?? 0)) }
            .prefix(3)
            .map { r, v in
                let tie = pickFigure.map { abs(v - $0) < Self.tieFloor(stage.id) } ?? false
                let units = stage.unit == "documents" ? Double(a.documentCount) : Double(a.pages)
                let pace = r.family == .mac ? r.secondsPerUnit.map { sec -> String in
                    let h = sec * units / 3600
                    return "about \(words.hours(h)) for this batch" + (h > a.hours ? ", longer than your \(words.hours(a.hours))" : "")
                } : nil
                return Alternative(
                    id: r.id, name: words.display(stage.id, r), family: r.id == "none" ? "nothing runs" : words.family(r.family),
                    figure: r.id == "none" ? "no names found"
                        : r.family == .manual ? "nothing is proposed"
                        : words.figure(stage.id, v) + (stage.id == "reading" ? " on your mix of pages"
                            : stage.id == "dating" ? " where the year is not in the text" : "")
                            + (tie ? " (a tie with the pick on this figure)" : ""),
                    cost: words.per1000(solver.usdPer1000(r, stage: stage.id), unit: stage.unit) + (pace.map { ", \($0)" } ?? "")
                        // What a cheaper segmentation route costs in checking, beside its price (W46.seg-text-tier-app).
                        + (stage.id == "segmentation" && r.family != .manual
                            ? r.figure("test-boxes.checks_per_100").map { String(format: ", about %.0f boundaries to check in 100 pages", $0) } ?? ""
                            : ""))
            }
        // Names run only when names are ranked, on every route (rule ent-run), which the solver applies by leaving them out.
        let namesUnranked = stage.id == "entities" && !a.priorities.contains(.names)
        let options = stage.routes.filter { !$0.afterTraining && $0.offered && words.mainFigure(stage, $0, solver: solver) != nil }
            .map { r in
                Option(id: r.id, name: words.display(stage.id, r),
                       blocked: appBlocked[r.id]?.first.map(words.reason)
                        ?? (namesUnranked && r.id != "none" ? "names are found only when they are among what matters most" : nil))
            }
            .sorted { ($0.blocked == nil ? 0 : 1, $0.name) < ($1.blocked == nil ? 0 : 1, $1.name) }
        _ = blocked

        let hands = picks.first { $0.part == "handwritten" }
        var why = lead.map {
            words.why($0, handsName: hands?.flag == nil && hands?.route?.id != route?.id ? hands?.route.map { words.display(stage.id, $0) } : nil,
                      handsUnread: hands?.flag != nil)
        } ?? "Nothing in this stage runs here."
        if stage.id == "segmentation", route?.family == .manual {
            why = "Nothing that proposes where documents begin can run here, so you check every place yourself."
        }
        var appPick: String?
        if let custom {
            let appLead = app.picks.first { $0.stage == stage.id && $0.part == leadPart }
            let pickName = appLead?.route.map { words.display(stage.id, $0) } ?? "nothing"
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
                        runsNow = "Not switched on yet: Process Files now uses \(running.segmentation.sheetLabel). "
                            + "“Use this in Process Files” switches it on."
                        apply = .segmentation(approach)
                    }
                } else {
                    runsNow = "The Processor cannot run this one yet; Process Files uses \(running.segmentation.sheetLabel)."
                }
            }
        case "reading":
            if let r = route, lead?.flag == nil, r.id != running.readingRouteID {
                if r.id == "apple-vision" {
                    runsNow = "Not switched on yet: Process Files now reads with \(running.readingName). “Read with this” switches it on."
                    apply = .appleVision
                } else if let ar = r.appRoute, ar.contains("|") {
                    runsNow = "Not switched on yet: Process Files now reads with \(running.readingName). “Read with this” switches it on."
                    apply = .reading(appRoute: ar)
                } else {
                    runsNow = "The Processor cannot run this reading program yet; Process Files reads with \(running.readingName)."
                }
            }
        default: break
        }

        var sources = [String]()
        if let n = stage.note { sources.append(n) }
        for r in usedRoutes {
            for f in Self.sourceFiles(r) where !sources.contains(f) { sources.append(f) }
        }

        // A pick that is several readers names each with what it reads (the free pick: Vision for typed and printed
        // pages, a downloaded reader for handwriting).
        var routeName = route.map { words.display(stage.id, $0) } ?? "Nothing"
        if stage.id == "dating" {
            let named = picks.filter { $0.flag == nil && $0.route != nil }
            let what = ["step 1": "the year in the text", "step 2": "the page image", "step 4": "the folder estimate"]
            let byRoute = Dictionary(grouping: named) { $0.route!.id }
            if byRoute.count > 1 {
                // "The year in the text: Gemini 3.8 Flash; the page image: Qwen3-VL 8B on this Mac; …", each program's
                // short name (before its first comma).
                let joined = named.compactMap { p -> String? in
                    guard let w = what[p.part], let r = p.route else { return nil }
                    let d = words.display(stage.id, r)
                    return w + ": " + (d.hasPrefix("Apple Vision's text") ? d : d.components(separatedBy: ",")[0])
                }.joined(separator: "; ")
                routeName = joined.prefix(1).uppercased() + joined.dropFirst()
            }
        }
        if stage.id == "reading" {
            let byRoute = Dictionary(grouping: picks.filter { $0.part != "all" && $0.flag == nil && $0.route != nil }) { $0.route!.id }
            if byRoute.count > 1 {
                routeName = byRoute.values
                    .sorted { ($0.first?.route?.id == route?.id ? 0 : 1) < ($1.first?.route?.id == route?.id ? 0 : 1) }
                    .map { ps in
                        "\(words.display(stage.id, ps[0].route!)) for "
                            + ps.map { words.readingPart($0.part).lowercased() }.joined(separator: " and ")
                    }.joined(separator: "; ")
            }
        }
        return Card(
            id: stage.id, title: words.stageTitle(stage.id), about: words.stageAbout(stage.id), weight: weightText,
            routeID: route?.id, routeName: routeName, family: familyText, isCustom: custom != nil,
            hasOverride: held,
            why: why, evidence: lead?.reason ?? "", parts: parts,
            cost: words.cost(usd, routes: usedRoutes, stage: stage, solver: solver, answers: a),
            time: words.time(hours, routes: usedRoutes, stage: stage),
            memory: words.memory(usedRoutes),
            labels: labels, caveats: Self.unique(usedRoutes.flatMap(\.caveats)),
            better: betterAll, alternatives: Array(alternatives), options: options, appPick: appPick,
            runsNow: runsNow, apply: apply, sources: sources)
    }

    private static func parts(_ stage: SettingsRouteTable.Stage, picks: [SettingsPick], answers a: SettingsAnswers,
                              words: Words, cmpBase: Double?, handsUnread: Bool = false) -> [PartRow] {
        func name(_ r: SettingsRouteTable.Route?) -> String? { r.map { words.display(stage.id, $0) } }
        switch stage.id {
        case "reading":
            let main = picks.first { $0.part == "all" }
            var rows: [PartRow] = []
            // The pick on the user's own mix of pages: the figure "better" and the alternatives are read against.
            if let v = cmpBase {
                let unread = picks.contains { $0.part != "all" && $0.flag != nil }
                // Shares of the whole mix, so the kinds shown and the rest add to 100.
                let whole = max(1e-9, a.mix.values.filter { $0 > 0 }.reduce(0, +))
                let mix = ["typewritten", "printed", "handwritten"].compactMap { k -> String? in
                    guard let x = a.mix[k], x > 0 else { return nil }
                    return String(format: "%.0f%% \(k)", x / whole * 100)
                }.joined(separator: ", ")
                    + {
                        let rest = a.mix.filter { !["typewritten", "printed", "handwritten"].contains($0.key) && $0.value > 0 }
                            .sorted { $0.value > $1.value }
                            .map { k in String(format: "%.0f%% ", k.value / whole * 100) + (CollectionInterviewAnswers.measuredKinds.contains(k.key)
                                ? PageKind.label(k.key).lowercased() : CollectionInterviewAnswers.unmeasuredLabel(k.key).lowercased()) }
                        return rest.isEmpty ? "" : ", " + rest.joined(separator: ", ")
                    }()
                rows.append(PartRow(id: "all", label: "On your mix of pages", routeName: nil,
                                    figure: words.figure("reading", v),
                                    sample: mix.isEmpty ? "on 96 test pages whose text was checked by hand"
                                        : "\(mix), from the figures below",
                                    label2: unread ? "pages your reading choice cannot read count as 0" : nil, warning: false))
            }
            rows += picks.filter { $0.part != "all" }.map { p in
                let isHands = p.part == "handwritten"
                return PartRow(
                    id: p.part, label: words.readingPart(p.part), routeName: p.flag == nil ? name(p.route) : nil,
                    figure: p.flag.map { words.flag($0, part: p.part) } ?? p.figure.map { words.figure("reading", $0) } ?? "not read",
                    sample: p.flag == nil ? p.route.flatMap { words.readingSample($0, part: p.part) } : nil,
                    label2: isHands && p.flag == nil
                        ? "conditional on the truth: the correct text of these pages was first drafted by AI models (Claude and Gemini), so every figure here may read a little high, and Claude's and Gemini's own figures most of all"
                        : nil,
                    warning: p.flag != nil)
            }
            for kind in CollectionInterviewAnswers.unmeasuredKinds where (a.mix[kind] ?? 0) > 0
                && stage.kindStrata[kind] == nil && kind != "registers" {
                rows.append(PartRow(id: kind, label: CollectionInterviewAnswers.unmeasuredLabel(kind),
                                    routeName: name(main?.route), figure: "unmeasured",
                                    sample: nil, label2: "no reading program was measured on this kind of page; the main one reads it",
                                    warning: false))
            }
            return rows
        case "segmentation":
            guard let p = picks.first else { return [] }
            guard let r = p.route else {
                return [PartRow(id: "all", label: "All pages", routeName: nil, figure: words.flag(p.flag ?? ""),
                                sample: nil, label2: nil, warning: true)]
            }
            let before = a.checkingMinutes > 0
                ? "With the \(SettingsSolver.num(a.checkingMinutes)) minutes you will spend checking" : "Before you check anything"
            let per100 = r.figure("test-boxes.checks_per_100")
            var rows = [PartRow(id: "all", label: before, routeName: name(r),
                                figure: r.family == .manual ? "nothing is proposed: you check every place yourself"
                                    : p.figure.map { String(format: "%.0f%% of pages in the right document", $0) } ?? "no figure",
                                sample: r.family == .manual ? nil : "on two test boxes of typed letters, 363 pages checked by hand",
                                label2: r.family == .manual ? nil : "the boxes below are separate tests: on other material it varies",
                                warning: false)]
            if let per100 {
                let places = per100 * Double(a.pages) / 100
                rows.append(PartRow(id: "checks", label: "Places it asks you to check (a place is the gap between two pages, where a new document may start)", routeName: nil,
                                    figure: r.family == .manual ? String(format: "every place between two document pages (about %.0f in every 100 pages; the rest are next to box or folder labels, which need no check)", per100)
                                        : String(format: "about %.0f in every 100 pages", per100)
                                            + (stage.route("manual")?.figure("test-boxes.checks_per_100").map {
                                                String(format: " (by hand with no model: about %.0f; places next to box or folder labels need no check)", $0)
                                            } ?? ""),
                                    sample: nil, label2: nil, warning: false))
                rows.append(PartRow(id: "checking", label: "Your own checking time", routeName: nil,
                                    figure: "about \(SettingsSheetModel.count(Int(places.rounded()), "place")), roughly "
                                        + words.hours(places * 20 / 3600),
                                    sample: "at about 20 seconds a place, a guess nobody has timed yet; not in the times above",
                                    label2: nil, warning: false))
            }
            if let after = r.figure("test-boxes.after_checking") {
                let hidden = r.figure("test-boxes.unflagged_per_500")
                rows.append(PartRow(id: "after", label: "After you check them all", routeName: nil,
                                    figure: String(format: "%.0f%% of pages in the right document", after),
                                    sample: nil,
                                    label2: after < 99.95 && r.family != .manual
                                        ? "places the model is sure of are not shown to you, and a few of them are wrong"
                                            + (hidden.map { String(format: " (about %.0f in every 500 pages)", $0) } ?? "")
                                            + "; to be fully certain, check every place yourself"
                                        : nil,
                                    warning: false))
            }
            let boxes: [(String, String)] = [("letters", "A box of typed and handwritten letters"), ("magazine", "A magazine, articles within issues"),
                                             ("clippings-mixed", "Clippings mixed with other papers"),
                                             ("manuscripts-public", "Handwritten letters (a published test collection)"),
                                             ("typed-gov-public", "Typed government files (a published test collection)")]
            let measuredElsewhere = { (key: String) in
                stage.routes.contains { $0.figures[key] != nil || $0.figures["\(key).gap_acc"] != nil }
            }
            for (key, label) in boxes {
                let v = r.figure(key) ?? r.figure("\(key).gap_acc") ?? r.figure("\(key).owner_weighted")
                guard let v else {
                    if r.family != .manual, ["letters", "manuscripts-public"].contains(key), measuredElsewhere(key) {
                        rows.append(PartRow(id: key, label: label, routeName: nil, figure: "not measured for this model",
                                            sample: nil, label2: nil, warning: false))
                    }
                    continue
                }
                let pagesFigure = r.figures[key] != nil
                let n = (r.figures[key] ?? r.figures["\(key).gap_acc"] ?? r.figures["\(key).owner_weighted"])?["n"]?.double
                let ranks = key != "magazine" || r.id == "gemini3.8-flash"
                rows.append(PartRow(id: key, label: label, routeName: nil,
                                    figure: String(format: "%.0f%%", v)
                                        + (pagesFigure ? " of pages in the right document"
                                            : " of the places between pages judged right (a new document or not; a different measure from the rows above)"),
                                    sample: n.map { "on \(Int($0)) \(pagesFigure ? "pages" : "places between pages"), before checking" },
                                    label2: ranks ? nil : "ranks nothing yet: not used to choose, because this model was not told that each magazine article is a document of its own",
                                    warning: false))
            }
            return rows
        case "dating":
            var rows: [PartRow] = []
            let first = picks.first { $0.part == "step 1" }?.route?.id
            for p in picks {
                let label = ["step 1": "When the year is written in the text",
                             "step 2": "When the text has no year-like number at all: the page image is searched (a stamp, a handwritten date)",
                             "step 4": "When no year is found anywhere: estimated from the folder or nearby documents"][p.part] ?? p.part
                guard let r = p.route, p.flag == nil else {
                    rows.append(PartRow(id: p.part, label: label, routeName: nil, figure: words.flag(p.flag ?? ""),
                                        sample: nil, label2: nil, warning: false))
                    continue
                }
                func row(_ id: String, _ label: String, _ key: String, _ sample: String, _ note: String? = nil) {
                    guard let v = r.figure(key) else { return }
                    let n = r.figures[key]?["n"]?.double
                    rows.append(PartRow(id: id, label: label, routeName: name(r),
                                        figure: String(format: "%.0f%% get the exact year", v),
                                        sample: n.map { "on \(Int($0)) \(sample)" }, label2: note, warning: false))
                }
                switch p.part {
                case "step 1":
                    row("step 1", label, "in_text", "documents whose year is in the text")
                    row("step 1b", "When the year is not written out in the text: inferred from other clues (people, events, a weekday)", "not_in_text",
                        "test documents whose year is not in their text")
                case "step 2":
                    row("step 2", label, "unprinted_122_doc_year",
                        "other test documents, with no year anywhere in their text")
                case "step 4":
                    rows.append(PartRow(id: "step 4", label: label, routeName: r.id == first ? nil : name(r),
                                        figure: r.id == first ? "done by the program above; not measured on its own"
                                            : "not measured on its own",
                                        sample: nil, label2: "always marked Date Uncertain", warning: false))
                default: break
                }
            }
            return rows
        case "entities":
            var extra: [PartRow] = []
            if let p = picks.first(where: { $0.part == "correspondence-typed" }), p.flag == nil, let r = p.route {
                for (key, label) in [("recipient", "the recipient"), ("place_city", "the sending place (its city)")] {
                    guard let v = r.figure(key) else { continue }
                    extra.append(PartRow(id: key, label: "Letters: \(label)", routeName: nil,
                                         figure: String(format: "finds \(label) right about %.0f times in 100", v * 100),
                                         sample: r.figures[key]?["n"]?.double.map { "on \(Int($0)) letters" }, label2: nil, warning: false))
                }
            }
            // One row for all letters when handwriting was not measured apart and is read.
            let typed = picks.first { $0.part == "correspondence-typed" }
            let hand = picks.first { $0.part == "correspondence-handwritten" }
            let merged = !handsUnread && typed?.flag == nil && hand?.flag == nil && typed?.route?.id == hand?.route?.id
                && typed?.route?.figure("handwritten_or_mixed") == nil
            let senders = picks.compactMap { p -> PartRow? in
                if merged && p.part == "correspondence-handwritten" { return nil }
                let label = merged && p.part == "correspondence-typed" ? "All letters, typed and handwritten"
                    : ["correspondence-typed": "Typed letters", "correspondence-handwritten": "Handwritten letters",
                       "non-correspondence": "Everything that is not a letter"][p.part] ?? p.part
                if p.part == "correspondence-handwritten", handsUnread, p.flag == nil {
                    return PartRow(id: p.part, label: label, routeName: nil,
                                   figure: "none found: your reading choice cannot read handwriting",
                                   sample: nil, label2: nil, warning: true)
                }
                let r = p.route
                // Handwriting apart only where the bench scored it apart; else the figure is all 138 letters together.
                let hands = p.part == "correspondence-handwritten" ? r?.figure("handwritten_or_mixed") : nil
                let figure = hands ?? p.figure
                let n = (hands != nil ? r?.figures["handwritten_or_mixed"] : r?.figures["sender"])?["n"]?.double
                return PartRow(id: p.part, label: label, routeName: p.flag == nil ? name(r) : nil,
                               figure: p.flag == "none" ? (p.part == "non-correspondence" ? "not looked for: names are found in letters only" : "not looked for")
                                   : figure.map { String(format: "finds the sender right about %.0f times in 100", $0 * 100) } ?? "no figure",
                               sample: p.flag == nil ? n.map {
                                   p.part == "correspondence-handwritten" && hands == nil
                                       ? "on \(Int($0)) letters, typed and handwritten together; not measured apart"
                                       : "on \(Int($0)) letters, typed and handwritten together"
                               } : nil,
                               label2: nil, warning: false)
            }
            return senders + extra
        default:
            return []
        }
    }

    // MARK: Rules

    private static func ruleStage(_ stage: SettingsRouteTable.Stage, resolver: SettingsResolver) -> RuleStage {
        let switches: [SwitchRow] = stage.rules.compactMap { rule in
            guard let sw = rule.switchSetting, let key = Self.switchKey(sw.id) else { return nil }
            let resolved = resolver.resolve(key)
            return SwitchRow(id: sw.id, key: key, label: Self.switchLabel(key) ?? sw.label, isOn: resolved.value.bool ?? sw.defaultValue,
                             source: Self.sourceWords(resolved), note: Self.switchPending.contains(key) ? Self.pendingNote : nil)
        }
        return RuleStage(id: stage.id, title: Words.ruleTitle(stage.id), text: Words.ruleText(stage.id),
                         switches: switches,
                         rules: stage.rules.map { RuleRow(id: $0.id, text: $0.text, source: $0.source) },
                         source: stage.note)
    }

    /// Switches the run does not read yet: the new page output (W42.int-s5) applies them.
    static let switchPending: Set<SettingsKey> = [.straightenReadingCopy, .placeHandOnImage]
    static let pendingNote = "Saved, but not used yet: it takes effect in a later version of the Processor."

    static func switchLabel(_ key: SettingsKey) -> String? {
        switch key {
        case .straightenReadingCopy: return "Straighten sloping pages"
        case .placeHandOnImage: return "Put handwritten text on the page image (a page where the fit is unsure gets a separate text page)"
        case .dateImageEveryDocument:
            return "Search the page image on every document, not only those whose text has no year: finds stamp dates "
                + "(kept beside the document's own date); about $1.93 more per 1,000 documents"
        default: return nil
        }
    }

    /// The layered setting a table switch is stored in.
    static func switchKey(_ id: String) -> SettingsKey? {
        switch id {
        case "reading_copy.straighten": return .straightenReadingCopy
        case "place.hand_on_image": return .placeHandOnImage
        case "dating.image_every_document": return .dateImageEveryDocument
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
            return "Each reading program's accuracy on 96 test pages whose text was checked by hand (typewritten, printed, "
                + "handwritten) and, where it was run, on published test pages of the same kind. Figures closer than the "
                + "measurements can tell apart count as ties. The checked text was first drafted with Claude and "
                + "Gemini, so close figures for those two are provisional."
        case "segmentation":
            return "Pages are grouped into documents by a model reading seven pages at a time. The figure is pages in "
                + "exactly the right document, measured on boxes of real papers checked by hand; it is not a forecast for your "
                + "collection. Places the model is unsure of are shown to you to check, and checking every one is "
                + "always possible."
        case "dating":
            return "The year each document was written: from its text first, then from the page image where the text "
                + "has none, then from its folder or its neighbours. A year that is estimated is always marked Date "
                + "Uncertain, and no year is written without the words it came from."
        case "entities":
            return "Who sent each letter, to whom, and from where. Each name is shown with the words it was read from, or "
                + "marked inferred. Looked for only when names are among what matters most. With an online reading program it is one more request a letter; on this Mac it needs a downloaded "
                + "model and typed pages."
        default: return ""
        }
    }

    static func ruleTitle(_ s: String) -> String {
        ["reading-copy": "The copy you read: turning and straightening",
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
            return "Pages are turned upright before reading. Once a page's text has been read, the copy you see is turned "
                + "level if its lines slope by 1 degree or more, unless you switch straightening off; nothing is cropped or cut, and marks stay. Curved "
                + "pages are not flattened, and nothing is cropped or evened out on the page you see."
        case "ocr-input":
            return "Pages are read from the image as captured. No cleaning, conversion to black and white, or removal of "
                + "marks is applied to the image a reading program reads: none of these helped any program tested."
        case "layout":
            return "Newspapers and other dense multi-column pages are read in regions, column by column. Everything else "
                + "is read as a whole page. Handwriting, registers and ledgers are never split into regions."
        case "placement":
            return "On typed and printed pages the text is laid over the page image line by line, so you can select and "
                + "search it where it sits; this is free. On handwritten pages the lines are found on the page and the "
                + "text is fitted to them; a page where the fit is unsure, or where the program cannot say where each line is, "
                + "gets a separate text page instead."
        case "marks":
            return "Finding and listing marks (stamps, signatures, handwritten notes) is not offered yet. Your page images are never altered to "
                + "hide them, and the page's text includes them where the reading program can read them."
        case "capture":
            return "The capture app photographs each page at the camera's full quality with the flash off, keeps the original "
                + "JPEG untouched, and tells you when the frame is likely to read badly. Hold the phone still, avoid "
                + "reflections, keep the page edges and only that page in the frame. The Mac sends the reading programs a copy "
                + "2,048 pixels on its long side; larger copies read no better in the tests."
        default: return ""
        }
    }

    func family(_ f: SettingsRouteTable.Family) -> String {
        switch f {
        case .mac: return "this Mac"
        case .cloud: return "a paid service"
        case .plan: return "a subscription plan"
        case .cluster: return "a computing cluster (shared research computers)"
        case .manual: return "by hand"
        case .kit: return "trained on your material"
        }
    }

    func name(_ stage: String, _ id: String) -> String {
        table.stage(stage)?.route(id).map { display(stage, $0) } ?? id
    }

    /// A route's name in the sheet's words: the table's name for a reader or a segmenter, with the bench's
    /// precision tags and "your" dropped; a plain description for the dating and names pipelines.
    func display(_ stage: String, _ r: SettingsRouteTable.Route) -> String {
        let plain: [String: String] = [
            "vision-2b-chooser-t3": "Apple Vision's text, with a small model on this Mac choosing the year",
            "vision-rules-t3": "Apple Vision's text and fixed rules (built in)",
            "mlx-date-2b-8bit": "A small dating model on this Mac, reading the year by itself",
            "mix-claude-chatgpt": "Claude and ChatGPT together, comparing their answers",
            "gemini3.8-flash-oneshot": "Gemini 3.8 Flash, working from each document's text for its date and names",
            "gemini3.7-flash-oneshot-vision": "Gemini 3.7 Flash (Stanford gateway), working from each document's text for its date and names",
            "gemini3.7-flash-trace-neigh": "Gemini 3.7 Flash (Stanford gateway), quoting its evidence and nearby dates",
            "gemini3.7-flash-route": "Gemini 3.7 Flash (Stanford gateway): reads the text, looks at the page when no year is written, and checks a guess against nearby documents",
            "gemini3.7-flash-image": "Gemini 3.7 Flash (Stanford gateway), looking at the page image",
            "qwen3.6-27b-image": "Qwen3.6 27B on a computing cluster, looking at the page image",
            "qwen3-vl-8b-image-mac": "Qwen3-VL 8B on this Mac, looking at the page image",
            "qwen3.6-27b-trace-neigh-vision": "Qwen3.6 27B on a computing cluster, quoting its evidence",
            "gemini-entity-feature": "Gemini, with a request of its own for names",
            "gemini-tagging-place": "Gemini, working from each document's text for its date and names",
            "gemini-entity8k": "Gemini, with a longer request of its own for names",
            "qwen3.6-27b": stage == "entities" ? "Qwen3.6 27B (a computing cluster or OpenRouter)" : r.name,
            "qwen3-vl-8b-mac": "Qwen3-VL 8B on this Mac",
            "qwen3.5-4b-mac": "Qwen3.5 4B on this Mac",
            "nltagger": "Apple's built-in name finder",
            "gliner2.5-base-spans-rule": "GLiNER, a small name finder",
            "manual": "No model: you check every place yourself",
            "seg-qwen3.5-2b-8bit": "Qwen3.5 2B, trained for this task by the app's makers, on this Mac (no key)",
            "seg-qwen3.5-2b-bf16-cluster": "Qwen3.5 2B, trained for this task by the app's makers, on a computing cluster",
            "seg-qwen3.5-4b-cluster": "Qwen3.5 4B, trained for this task by the app's makers, on a computing cluster",
        ]
        if r.id == "none" { return stage == "dating" ? "No dating" : "No names" }
        if let p = plain[r.id], stage == "dating" || stage == "entities" || ["manual", "mix-claude-chatgpt", "seg-qwen3.5-2b-8bit", "seg-qwen3.5-2b-bf16-cluster",
                                                                                     "seg-qwen3.5-4b-cluster"].contains(r.id) {
            return p
        }
        var n = r.name
        for (a, b) in [(" medium on blla lines", ""), (" bf16", ""), (" 8-bit", ""), (" 4-bit", ""), (" fp8", ""), (", hosted fp8", ""),
                       (" (Mac CPU)", " (on this Mac)"), (" (Mac)", ""), ("(your Claude plan)", "(a Claude subscription)"),
                       ("(your cluster)", "(on a computing cluster)"), ("(your cluster or OpenRouter)", "(a computing cluster or OpenRouter)")] {
            n = n.replacingOccurrences(of: a, with: b)
        }
        return n
    }

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
            return r.figures[part]?["n"]?.double.map { "on \(Int($0)) \(part) test pages" }
        case "handwritten":
            return r.figures["hands16"]?["n"]?.double.map { "on \(Int($0)) handwritten test pages" }
        default:
            if case .string(let s)? = r.figures["public"]?[part]?.array?.last, let n = s.split(separator: "/").last {
                return "on \(n) public test pages, whose text was checked independently"
            }
            return nil
        }
    }

    /// A reader's figure on the user's own mix of typewritten, printed and handwritten pages; its average over the
    /// 96 pages when the mix holds none of the three or the reader lacks a kind's figure.
    func mixAverage(_ r: SettingsRouteTable.Route) -> Double? {
        let kinds = ["typewritten", "printed", "handwritten"].filter { (answers.mix[$0] ?? 0) > 0 }
        let total = kinds.reduce(0) { $0 + (answers.mix[$1] ?? 0) }
        let overall = answers.readingFallback ? r.figure("overall") : r.strict("overall")
        guard total > 0 else { return overall }
        var sum = 0.0
        for k in kinds {
            // Apple Vision never reads handwriting (owner call 4): its handwritten pages count as 0, as a flagged kind does.
            if k == "handwritten" && r.id == "apple-vision" { continue }
            guard let v = k == "handwritten" ? (r.figure("hands16") ?? r.figure(k)) : r.figure(k) else { return overall }
            sum += v * (answers.mix[k] ?? 0) / total
        }
        return sum
    }

    func pace(_ seconds: Double, unit: String = "pages") -> String {
        let one = unit == "documents" ? "a document" : "a page"
        if seconds < 1 { return "under a second \(one)" }
        if seconds < 1.5 { return "about a second \(one)" }
        return String(format: "about %.0f seconds \(one)", seconds)
    }

    func mainFigure(_ stage: SettingsRouteTable.Stage, _ r: SettingsRouteTable.Route, solver: SettingsSolver?) -> Double? {
        switch stage.id {
        case "reading": return answers.readingFallback ? r.figure("overall") : r.strict("overall")
        case "segmentation": return r.figure("test-boxes") ?? (r.family == .manual ? 0 : nil)   // the solver's own figure
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
            return d < 0.05 ? "less than 0.1 more characters right in 100 on your mix of pages"
                : String(format: "%.1f more characters right in 100 on your mix of pages", d)
        case "segmentation": return String(format: "%.0f more pages in every 100 in the right document", d)
        case "dating": return String(format: "%.0f more exact years in every 100 documents whose year is not in the text", d)
        case "entities": return String(format: "%.0f more senders right in 100", d * 100)
            .replacingOccurrences(of: "more senders right", with: "more senders right")
        default: return SettingsSolver.num(d)
        }
    }

    func flag(_ f: String, part: String = "") -> String {
        if f == "needs a download or a key", part == "handwritten" {
            return "not read: this choice cannot read handwriting; a downloaded reading program or a key would"
        }
        switch f {
        case "needs a download or a key": return "not read here: it needs a downloaded reading program or a key"
        case "no figure": return "no figure for this kind"
        case "no reader": return "no reading program can run here"
        case "none": return "not run"
        default:
            let g = f.replacingOccurrences(of: "no image pass; the document goes on to step 4",
                                           with: "no program looks at the page image here; such documents go on to the folder estimate below")
                .replacingOccurrences(of: "goes on to step 4", with: "goes on to the folder estimate below")
            return g.prefix(1).uppercased() + g.dropFirst()
        }
    }

    /// The solver's blocker and limit phrases, in the sheet's words.
    func reason(_ r: String) -> String {
        if r == "not in this comparison" { return "you chose another option for this step" }
        if r == "this batch stays on the Mac" {
            return "it sends pages off this Mac, online or to a cluster, and you chose to keep them on this Mac"
        }
        if r == "ties the pick and costs more or is slower" { return "no better within the bench's margin of error, and costs more or is slower" }
        if r.hasPrefix("waits for: ") { return "not ready in the app yet" }
        if r.hasPrefix("not offered by the app") { return "the app does not offer it yet" }
        if r.hasPrefix("never offered") { return "kept only as a measured comparison, not offered" }
        if r.hasPrefix("not offered") { return "not offered" }
        if r.hasPrefix("useful as a disagreement partner") { return "only useful beside another model, not on its own" }
        if r == "not in the app yet" { return "the Processor cannot run it yet" }
        if let m = r.range(of: #"^needs about (\d+) GB of memory \([\d.]+ GB measured\)$"#, options: .regularExpression) {
            let gb = r[m].split(separator: " ")[2]
            return "needs about \(gb) GB of memory while it works; this Mac has \(Int(resources.macMemoryGB.rounded())) GB"
        }
        if r.hasPrefix("needs ") {
            return r.replacingOccurrences(of: #"\ba ([AEIOU])"#, with: "an $1", options: .regularExpression)
        }
        // A file the bench names is for the notes, not the sheet's words.
        return r.replacingOccurrences(of: #"\s*\([^)]*\.md[^)]*\)"#, with: "", options: .regularExpression)
    }

    func limitPhrase(_ r: String) -> String {
        if r.hasPrefix("raise the ceiling by ") {
            let by = String(r.dropFirst("raise the ceiling by ".count))
            let to = Double(by.dropFirst()).flatMap { x in answers.ceilingUSD.map { money($0 + x) } }
            return "Raise the most to spend by \(by)" + (to.map { ", to \($0)" } ?? "")
                + " (the less important steps would then have to be free)"
        }
        if r.hasPrefix("allow about ") { return "Allow about " + r.dropFirst("allow about ".count) }
        return r.prefix(1).uppercased() + r.dropFirst()
    }

    func why(_ p: SettingsPick, handsName: String? = nil, handsUnread: Bool = false) -> String {
        let r = p.reason
        if p.flag != nil, p.route == nil { return "Nothing can run this here." }
        if r.contains("free default") {
            let head = "The app's free default, set by its makers rather than by the “higher wins” rule: Apple Vision is "
                + "built into macOS and reads a typed or printed page in under a second; nothing is spent and no page "
                + "leaves this Mac. "
            if let hands = handsName {
                return head + "\(hands), a free download that stays on this Mac, reads the handwriting and takes most of the "
                    + "memory and time. The free programs listed below score slightly higher on your mix of pages; any "
                    + "can be chosen with “Use instead…”."
            }
            return head + (handsUnread
                ? "Handwritten pages are not read: the programs that read them need a key, or more memory than this Mac has."
                : "The free programs listed below score slightly higher on your mix of pages; any can be chosen with "
                    + "“Use instead…”.")
        }
        if r.contains("no route fits the ceiling and the hours") {
            return "Nothing fits both your spending and your time, so the cheapest choice that can run is used."
        }
        if r.contains("a measured cascade") { return "Two readers together, the second taking the pages the first fails, read better than any one alone." }
        if r.contains(" ties ") {
            let tail = r.contains("cheaper") ? "cheaper."
                : r.contains("faster") ? "faster."
                : r.contains("carry checked evidence") ? "its years come with the words they were read from."
                : r.contains("better where the year is in the text") ? "it does better where the year is written in the text."
                : "better on the stage's other measures."
            return (r.contains("better where the year is in the text")
                ? "Where the year is not written, it ties the best choice this collection can use (within the measurements' margin of error), and "
                : "As good as the best choice this collection can use, within the measurements' margin of error, and ") + tail
        }
        if r.contains("is the best route") {
            return p.route.map { r in r.id.contains("3.8") && r.caveats.contains { $0.contains("3.7") } } == true
                ? "The best choice this collection can use (its figures are Gemini 3.7's; see below)."
                : "The best measured choice this collection can use."
        }
        if r.contains("No names") { return "Names are not looked for in this batch." }
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
        let units = stage.unit == "documents"
            ? (a.documents == nil ? "about \(SettingsSheetModel.count(a.documentCount, "document")) (about 3 pages each)"
               : SettingsSheetModel.count(a.documentCount, "document"))
            : SettingsSheetModel.count(a.pages, "page")
        if usd >= 0.005 {
            let paid = routes.map { solver.usdPer1000($0, stage: stage.id) }.filter { $0 > 0 }
            let per = Self.uniqueStrings(paid.map { per1000($0, unit: stage.unit) })
            // The rate is worth saying only when it is not the same figure again.
            let same = stage.unit == "pages" && a.pages == 1000 && per.count == 1
            return "\(money(usd)) for \(units)" + (per.isEmpty || same ? "" : " (\(per.joined(separator: "; ")))")
        }
        if routes.contains(where: { $0.family == .plan }) { return "no money: it uses your plan's allowance" }
        if routes.contains(where: { $0.family == .cluster }) { return "no money: it runs on your cluster" }
        if routes.contains(where: { $0.family == .cloud }) && stage.id == "entities" {
            return "no extra money: the names come in the same request that finds each document's date"
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
        if routes.allSatisfy({ $0.family == .manual }) { return "only your own checking time" }
        let place = routes.contains { $0.family == .mac } ? "on this Mac" : routes.contains { $0.family == .cluster } ? "on your cluster" : "waiting on the service"
        let span = h < 1.0 / 60 ? hours(h) : "about \(hours(h))"
        return "\(span) \(place)" + (estimated ? " (an estimate, not timed)" : "")
            + (stage.id == "segmentation" ? ", not counting your checking" : "")
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
        if mac.allSatisfy({ !$0.needsDownload }) { return "little: nothing to download" }
        return "not measured yet"
    }
}

extension SettingsSheetModel {
    typealias Words = SettingsSheetWords
}

extension SegmentationApproach {
    /// The approach in the sheet's words.
    var sheetLabel: String {
        switch self {
        case .manual: return "no model (you check every place yourself)"
        case .claude: return "Claude Sonnet 5.5"
        case .gemini: return "Gemini 3.8 Flash"
        case .openai: return "ChatGPT"
        case .mix: return "Claude and ChatGPT together"
        case .glm: return "GLM-5.3 Flash"
        case .local: return "the trained model on this Mac"
        case .geminiText: return "Gemini 3.8 Flash on the text alone"
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
