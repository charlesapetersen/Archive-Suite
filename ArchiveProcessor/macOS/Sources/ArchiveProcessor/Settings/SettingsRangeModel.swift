import Foundation

// MARK: - The range view (W46.settings-range-view)

/// One stage's chart on the settings sheet's range tab (`12-settings-design.md` §3.4): across, what 1,000 pages or
/// documents cost at list price on a log scale, with a band at the left for free routes; up, the figure for the
/// user's own mix, on the basis the stage card compares on (`SettingsSheetModel.comparable`). One mark per route,
/// shaped by family: filled when usable, hollow when not (the tooltip says why), faded when usable but outside the
/// limits. A dashed line joins the routes nothing beats on both counts; a red one marks what is left of the ceiling
/// for this stage once the other stages are paid. Clicking a mark or a table row chooses it, as the card's override.
/// Built with no view, so the self-test reads exactly what the tab draws.
struct SettingsRangeChart: Identifiable {
    enum State: Equatable {
        case usable, outsideLimits, unusable
    }

    struct Point: Identifiable {
        let id: String
        let name: String
        let family: SettingsRouteTable.Family
        let familyWord: String
        /// Dollars per 1,000 units at list price; 0 is the free band.
        let x: Double
        /// The stage's figure on its card's basis, in the axis's units (names in senders right per 100).
        let y: Double
        let state: State
        /// What the tooltip says: the figure, the price, and why it is hollow or faded.
        let tooltip: String
        /// Part of what the sheet now picks for this stage.
        let picked: Bool
        /// The card's main pick, named beside its mark.
        let lead: Bool
        let onFrontier: Bool
        /// Clicking it sets the card's override (or clears it, for the app's own pick).
        let choosable: Bool
    }

    struct Row: Identifiable {
        let id: String
        let name: String
        let familyWord: String
        /// The per-kind figures in words.
        let figures: String
        /// The public test pages' figure, where the route was run on them.
        let publicFigure: String?
        let listPrice: String
        let batchCost: String
        let time: String
        /// "You can use this", or why not.
        let canUse: String
        let state: State
        let picked: Bool
        /// Picked for some of the batch only (a kind or a step), beside the card's main pick.
        let pickedPart: Bool
        /// The app's own pick on a Custom card: choosing it is the way back.
        let appPick: Bool
        let choosable: Bool
    }

    /// Where several routes chosen together sit (the free pick: Apple Vision and a hand reader).
    struct Together {
        let x: Double
        let y: Double
        let text: String
    }

    /// An after-training point (note 12): shown only when the fine-tuning answer allows it, with its condition.
    struct KitPoint: Identifiable {
        let id: String
        let name: String
        /// What was measured, in words; nil when nothing was.
        let measured: String?
        let condition: String
        /// Where it sits on this chart, when it was measured on the chart's own figure; nil keeps it in the list only.
        let y: Double?
        let caveats: [String]
    }

    let id: String
    let title: String
    /// The axis's words ("characters right in 100 on your mix of pages").
    let yLabel: String
    /// The price axis's words.
    let xLabel: String
    /// "pages" or "documents".
    let unit: String
    let points: [Point]
    let together: Together?
    /// Routes in the table but off the chart (a figure of 0 would flatten it: by hand, no names).
    let offChart: [String]
    /// What is left of the ceiling for this stage, per 1,000 units; nil with no ceiling.
    let ceilingPer1000: Double?
    let ceilingText: String?
    let caption: String
    let rows: [Row]
    let kit: [KitPoint]
    /// The routes the card's pick runs, named.
    let pickName: String
    /// The app's own pick for the stage, so clicking it is the way back.
    let appPickID: String?

    var frontier: [Point] { points.filter(\.onFrontier).sorted { ($0.x, $0.y) < ($1.x, $1.y) } }
}

extension SettingsSheetModel {
    static func ranges(table: SettingsRouteTable, solution s: SettingsSolution, app: SettingsSolution,
                       answers a: SettingsAnswers, cards: [Card], words: Words) -> [SettingsRangeChart] {
        cards.compactMap { card in
            table.stage(card.id).map { range($0, card: card, solution: s, app: app, answers: a, words: words) }
        }
    }

    private static func range(_ stage: SettingsRouteTable.Stage, card: Card, solution s: SettingsSolution,
                              app: SettingsSolution, answers a: SettingsAnswers, words: Words) -> SettingsRangeChart {
        let solver = SettingsSolver(table: words.table, pairs: nil, resources: words.resources, answers: a)
        let cmp = Self.comparable(stage.id, s, words: words)
        let scale = stage.id == "entities" ? 100.0 : 1.0
        let units = stage.unit == "documents" ? Double(a.documentCount) : Double(a.pages)
        let unitWord = stage.unit == "documents" ? "documents" : "pages"

        // What the other stages spend and take, from the sheet's own picks: the room this stage has.
        var others = SettingsSolver.SolveState(ceiling: a.ceilingUSD ?? .infinity, hours: a.hours)
        for p in s.picks where p.stage != stage.id {
            guard let r = p.route else { continue }
            others.add(.init(route: r, value: 0, usdPer1000: 0, usd: p.usd, hours: p.hours, bucket: solver.bucket(r),
                             blockers: []))
        }
        let room = a.ceilingUSD.map { $0 - others.usd }
        let left = room.map { max(0, $0) }
        let leftPer1000 = left.map { $0 / units * 1000 }

        let stagePicks = s.picks.filter { $0.stage == stage.id && $0.flag == nil && $0.route != nil }
        let picked = Set(stagePicks.compactMap(\.routeID))
        let leadPart = ["dating": "step 1", "entities": "correspondence-typed"][stage.id] ?? "all"
        let appPick = app.pick(stage.id, leadPart)?.routeID
        let namesUnranked = stage.id == "entities" && !a.priorities.contains(.names)
        let choosableIDs = Set(card.options.filter { $0.blocked == nil }.map(\.id))
        // Overnight, reading pays the batch price where a route has one (`SettingsSolver.usdPer1000`), so the chart
        // places it there and says so.
        let overnight = stage.id == "reading" && a.hours >= 24
            && stage.routes.contains { $0.batchUSDPer1000 != nil && solver.usdPer1000($0, stage: stage.id) > 0 }

        /// What this user would pay per 1,000 units: 0 on this Mac, by hand, or through a plan or cluster they have.
        func paid(_ r: SettingsRouteTable.Route) -> Double { solver.usdPer1000(r, stage: stage.id) }
        func priceText(_ r: SettingsRouteTable.Route, _ x: Double) -> String {
            let acc = solver.access(r)
            let plan = r.needs.plan.map { $0 == "claude" ? "Claude" : "ChatGPT" }.joined(separator: " and ")
            switch r.family {
            case .mac, .manual, .kit: return "free"
            default: break
            }
            if acc.viaPlan { return "no money: it uses your \(plan) plan" }
            if acc.viaCluster { return "no money: it runs on your cluster" }
            if x > 0 {
                let batch = overnight && r.batchUSDPer1000 != nil && x == r.batchUSDPer1000
                return String(format: "$%.2f per 1,000 \(unitWord)", x) + (batch ? " at the overnight batch price" : "")
                    + (r.family == .plan && !plan.isEmpty ? " with a key, or no money if you have the \(plan) plan" : "")
            }
            if stage.id == "entities" && r.family == .cloud {
                return "no extra money: the names come in the same request that finds each document's date"
            }
            if r.family == .plan && !plan.isEmpty { return "no money if you have the \(plan) plan" }
            if r.family == .cluster { return "no money if you have a cluster of your own" }
            return "no price listed"
        }

        struct Built {
            let route: SettingsRouteTable.Route
            let y: Double?
            let x: Double
            let state: SettingsRangeChart.State
            let why: String?
            let ownHours: Double
        }
        let built: [Built] = stage.routes.filter { !$0.afterTraining }.map { r in
            let v = cmp.of(r)
            let c = solver.cand(r, stage: stage.id, value: v ?? 0, units: units)
            var blockers = app.blockers(stage.id, r.id)
            if namesUnranked && r.family == .mac && blockers.isEmpty {
                blockers = ["on this Mac names are looked for only when you put names among what matters most (in "
                            + "“Questions about this material” in Settings)"]
            }
            if !r.offered && blockers.isEmpty, let cond = r.conditions.first { blockers = [cond] }
            let state: SettingsRangeChart.State
            var why: String?
            // A route breaks a limit by what it adds: its own cost against the room left, or hours that push the
            // batch past the limit. When the other steps already break one, a route that adds nothing does not.
            let after = others.adding(c)
            let costBreaks = room.map { c.usd > max(0, $0) + 1e-9 } ?? false
            let hoursBreak = after.wall > a.hours + 1e-9 && after.wall > others.wall + 1e-9
            if !blockers.isEmpty {
                state = .unusable
                why = Words.uniqueStrings(blockers.map { $0.hasPrefix("on this Mac names") ? $0 : words.reason($0) })
                    .joined(separator: "; ")
            } else if costBreaks {
                state = .outsideLimits
                why = (room ?? 0) <= 0
                    ? "it would cost about \(words.money(c.usd)) for this batch, and the other steps already use all of "
                        + "your most to spend"
                    : "it would cost about \(words.money(c.usd)) for this batch, more than the \(words.money(left ?? 0)) "
                        + "left of your most to spend once the other steps are paid"
            } else if hoursBreak {
                state = .outsideLimits
                why = "with it the whole batch would take about \(words.hours(after.wall)), longer than your "
                    + "\(words.hours(a.hours))"
            } else {
                state = .usable
            }
            return Built(route: r, y: v.map { $0 * scale }, x: paid(r), state: state, why: why, ownHours: c.hours)
        }

        // On the chart: everything with a figure, except a 0 that is not a measurement (by hand, no names).
        let charted = built.filter { b in
            guard let y = b.y else { return false }
            return !(y == 0 && (b.route.family == .manual || b.route.id == "none"))
        }
        let offChart = built.filter { b in !charted.contains { $0.route.id == b.route.id } }
            .map { words.display(stage.id, $0.route) }
        // The undominated choices within the limits: nothing else within them is both as cheap and as good.
        let within = charted.filter { $0.state == .usable }
        func dominated(_ p: Built) -> Bool {
            within.contains { q in
                q.route.id != p.route.id && q.x <= p.x + 1e-12 && q.y! >= p.y! - 1e-12
                    && (q.x < p.x - 1e-12 || q.y! > p.y! + 1e-12)
            }
        }
        let custom = card.isCustom
        let several = picked.count > 1
        let figureWord: (Double) -> String = { y in words.figure(stage.id, y / scale) }
        let points = charted.map { b in
            let name = words.display(stage.id, b.route)
            // The family, unless the name already says where it runs.
            var tip = (name.contains("(") ? name : "\(name) (\(words.family(b.route.family)))") + ": \(figureWord(b.y!))"
                + (stage.id == "reading" ? " on your mix of pages" : "") + "; \(priceText(b.route, b.x))."
            let part = picked.contains(b.route.id) && (b.route.id != card.routeID || several)
            if part { tip += " Chosen for part of this step." }
            if let w = b.why {
                tip += (b.state == .unusable ? " Cannot be used here: "
                        : part ? " Used for all of it, it would be outside your limits: " : " Outside your limits: ") + w + "."
            }
            if picked.contains(b.route.id) && !part { tip += " Now chosen." }
            if custom && b.route.id == appPick { tip += " The app's own pick: choosing it goes back to it." }
            return SettingsRangeChart.Point(
                id: b.route.id, name: name, family: b.route.family, familyWord: words.family(b.route.family),
                x: b.x, y: b.y!, state: b.state, tooltip: tip, picked: picked.contains(b.route.id),
                lead: b.route.id == card.routeID,
                onFrontier: b.state == .usable && !dominated(b),
                choosable: choosableIDs.contains(b.route.id) && b.route.id != card.routeID)
        }

        // The full table: every route, usable first, then by figure (a route without the chart's figure last).
        let rows = built
            .sorted { ($0.state == .unusable ? 1 : 0, -($0.y ?? -1)) < ($1.state == .unusable ? 1 : 0, -($1.y ?? -1)) }
            .map { b -> SettingsRangeChart.Row in
                let r = b.route
                let name = words.display(stage.id, r)
                let batch = b.x * units / 1000
                let part = picked.contains(r.id) && (r.id != card.routeID || several)
                let choosable = choosableIDs.contains(r.id) && r.id != card.routeID
                return SettingsRangeChart.Row(
                    id: r.id, name: name,
                    familyWord: r.id == "none" ? "nothing runs" : name.contains("(") ? ""
                        : words.family(r.family).replacingOccurrences(of: " (shared research computers)", with: ""),
                    figures: Self.rangeFigures(stage, r, y: b.y.map { $0 / scale }, words: words),
                    publicFigure: stage.id == "reading" ? Self.rangePublic(r, picks: s.picks, answers: a, words: words) : nil,
                    listPrice: priceText(r, b.x),
                    batchCost: priceText(r, b.x) == "no price listed" ? "its cost for this batch is not known"
                        : batch < 0.005 ? "nothing to pay for this batch" : "about \(words.money(batch)) for this batch",
                    time: r.family == .manual ? "only your own checking time"
                        : b.ownHours <= 0 ? "its time not measured" : "about \(words.hours(b.ownHours)) for this step alone"
                            + (r.time?["measured"] == .bool(true) ? "" : " (an estimate)"),
                    canUse: b.state == .usable
                        ? (choosable || picked.contains(r.id) || (custom && r.id == appPick) ? "you can use this"
                            : "shown for comparison: it is not offered as the choice for this whole step")
                        : b.state == .outsideLimits
                            ? (part ? "for all of this step, outside your limits: " : "outside your limits: ") + (b.why ?? "")
                        : "cannot be used here: \(b.why ?? "")",
                    state: b.state, picked: picked.contains(r.id), pickedPart: part,
                    appPick: custom && r.id == appPick,
                    choosable: choosable)
            }

        // Several routes chosen together (a reader per kind, a program per dating step): where they sit together.
        var together: SettingsRangeChart.Together?
        if picked.count > 1, let base = cmp.base {
            let usd = s.picks.filter { $0.stage == stage.id }.reduce(0) { $0 + $1.usd }
            var text = "Your choices together: \(figureWord(base * scale))"
                + (stage.id == "reading" ? " on your mix of pages" : "")
                + (usd < 0.005 ? ", free." : String(format: ", about $%.2f per 1,000 \(unitWord).", usd / units * 1000))
            if let top = points.filter({ $0.state == .usable }).max(by: { $0.y < $1.y }), top.y > base * scale + 1e-9 {
                let gap = top.y - base * scale
                text += gap < Self.tieFloor(stage.id) * scale
                    ? String(format: " \(top.name) alone scores %.1f higher, which is within what the measurements can tell "
                             + "apart, so the app counts it as a tie and keeps its choice by its own rule.", gap)
                    : String(format: " \(top.name) alone scores %.1f higher; “Use for all of this step” on its row would use it "
                             + "for every page.", gap)
            }
            together = .init(x: max(0, usd) / units * 1000, y: base * scale, text: text)
        }

        let kit = Self.rangeKit(stage.id, solution: s, answers: a, base: cmp.base, words: words)

        let ceilingText: String? = leftPer1000.map { per in
            if a.ceilingUSD == 0 { return "Red line: you chose to spend nothing, so only free choices fit." }
            return per <= 0
                ? "Red line: nothing is left of your most to spend for this step once the other steps are paid, so only "
                    + "free choices fit."
                : "Red line: what is left of your most to spend for this step once the other steps are paid, about "
                    + "\(words.money(left ?? 0)) for this batch, or " + String(format: "$%.2f", per) + " per 1,000 \(unitWord)."
        }
        let yLabel: String = {
            switch stage.id {
            case "reading": return "characters right in 100, on your mix of pages"
            case "segmentation": return "% of pages in the right document, before you check"
            case "dating": return "% exact year, where the year is not in the text"
            default: return "senders right in 100 letters"
            }
        }()
        let xLabel = overnight ? "per 1,000 \(unitWord) you pay: the overnight batch price where there is one"
            : "per 1,000 \(unitWord) you pay, at list price"
        let caption = "Each mark is one choice. Across: what 1,000 \(unitWord) cost you, at the "
            + (overnight ? "overnight batch price where a service has one, else the list price" : "list price")
            + ", on a scale where each step multiplies the price; choices that cost you nothing (this Mac, a plan or "
            + "cluster you have) sit in the green band at the left, spread out only so they can be told apart; a plan you do "
            + "not have sits at its price with a key, or in the band when it has none. Up: "
            + "\(yLabel). Filled marks you can use; hollow ones you cannot use here (point at one to see why); faded ones you "
            + "can use but they break your limits (the most to spend, the red line, or your time: \(words.hours(a.hours)) for "
            + "the whole batch). A ring marks what is chosen now. The dashed line joins the choices "
            + "within your limits that no other choice within them beats on both price and figure. Click a mark, or a "
            + "row below, to choose it. “This batch” is the \(SettingsSheetModel.count(Int(units), String(unitWord.dropLast()))) "
            + "the figures are for" + (stage.unit == "documents" ? " (about 3 pages each)" : "") + "."
        return SettingsRangeChart(
            id: stage.id, title: words.stageTitle(stage.id), yLabel: yLabel, xLabel: xLabel, unit: unitWord,
            points: points, together: together, offChart: offChart, ceilingPer1000: leftPer1000,
            ceilingText: ceilingText, caption: caption, rows: rows, kit: kit, pickName: card.routeName, appPickID: appPick)
    }

    /// A route's figures in the table, in words: reading per kind, the others on the card's figure.
    private static func rangeFigures(_ stage: SettingsRouteTable.Stage, _ r: SettingsRouteTable.Route, y: Double?,
                                     words: Words) -> String {
        guard let y else {
            if stage.id == "dating", let v = r.figure("unprinted_122_doc_year") {
                return String(format: "%.0f%% exact year on documents whose year is not printed, from the page image; "
                              + "measured on a different, harder set of documents, so not comparable with the chart", v)
            }
            if stage.id == "reading" {
                let kinds = [("typewritten", "typewritten"), ("printed", "printed"), ("hands16", "handwritten")]
                    .compactMap { k, w in r.figure(k).map { String(format: "\(w) %.1f", $0) } }
                if !kinds.isEmpty { return kinds.joined(separator: ", ") + " (characters right in 100; not measured on every kind)" }
            }
            return "not measured on this step's figure"
        }
        switch stage.id {
        case "reading":
            var parts = [String(format: "%.1f on your mix of pages", y)]
            for (k, word) in [("typewritten", "typewritten"), ("printed", "printed"), ("hands16", "handwritten")] {
                if let v = r.figure(k) { parts.append(String(format: "\(word) %.1f", v)) }
            }
            return parts.joined(separator: ", ") + " (characters right in 100)"
        case "segmentation":
            if r.family == .manual { return "nothing is proposed: you check every place yourself" }
            var t = words.figure("segmentation", y) + " before you check"
            if let after = r.figure("test-boxes.after_checking") { t += String(format: ", %.0f%% after checking", after) }
            return t
        case "dating":
            if r.id == "none" { return "no dates" }
            var t = words.figure("dating", y) + " where the year is not in the text"
            if let inText = r.figure("in_text") { t += String(format: ", %.0f%% where it is", inText) }
            return t
        default:
            return r.id == "none" ? "no names found" : words.figure("entities", y)
        }
    }

    /// The public test pages' strict figure for the strata this batch reads (handwriting's pooled figure when the mix
    /// holds handwriting), where the route was run on them.
    private static func rangePublic(_ r: SettingsRouteTable.Route, picks: [SettingsPick], answers a: SettingsAnswers,
                                    words: Words) -> String? {
        var parts: [String] = []
        if (a.mix["handwritten"] ?? 0) > 0, let v = r.publicStrict("L1-L3") {
            parts.append(String(format: "handwriting %.1f", v))
        }
        let strata = picks.filter { $0.stage == "reading" && !["all", "typewritten", "printed", "handwritten"].contains($0.part) }
            .map(\.part)
        for st in strata {
            if let v = r.publicStrict(st) { parts.append(words.readingPart(st).lowercased() + String(format: " %.1f", v)) }
        }
        return parts.isEmpty ? nil : "on other published test pages, whose text was checked independently: "
            + parts.joined(separator: ", ")
    }

    /// The kit's after-training points for this chart (note 12 §3, `13-profile-tests.md` F), with each condition.
    private static func rangeKit(_ stage: String, solution s: SettingsSolution, answers a: SettingsAnswers,
                                 base: Double?, words: Words) -> [SettingsRangeChart.KitPoint] {
        let home = ["kit-hands-ppocrv6-ft": "reading", "kit-seg-lora-mac": "segmentation",
                    "kit-seg-student-tags": "segmentation", "seg-2b-lora-k200": "segmentation"]
        guard let kit = words.table.stage("training-kit") else { return [] }
        // The handwriting fine-tune improves one reader; where another reads the handwriting it is not shown (F).
        return s.afterTraining.filter { home[$0.id] == stage && !$0.reason.hasPrefix("shown only where") }.compactMap { p in
            guard let r = kit.route(p.id) else { return nil }
            var measured: String?
            var y: Double?
            switch p.id {
            case "kit-hands-ppocrv6-ft":
                if let g = r.figure("handwritten-one-hand-160-lines") {
                    let n = r.figures["handwritten-one-hand-160-lines"]?["n"]?.double.map { " (\(Int($0)) test pages)" } ?? ""
                    measured = String(format: "about %.1f more characters right in 100 on one person's handwriting, after "
                                      + "160 corrected lines", g) + n + "; fewer lines gain less"
                    // On the reading chart: the gain, on the handwritten share of the user's mix.
                    let kinds = ["typewritten", "printed", "handwritten"]
                    let total = kinds.reduce(0) { $0 + (a.mix[$1] ?? 0) }
                    if p.shown, let base, total > 0 { y = base + g * (a.mix["handwritten"] ?? 0) / total }
                }
            case "kit-seg-student-tags":
                if let v = r.figure("owner-heldout-box-sasha") {
                    let n = r.figures["owner-heldout-box-sasha"]?["n"]?.double.map { Int($0) } ?? 0
                    measured = String(format: "%.0f%% of the places where a document begins or goes on found right, on a "
                                      + "box of real papers it never saw (%d places; a count of places, not of pages as in the "
                                      + "table)", v, n)
                }
            case "seg-2b-lora-k200":
                if let v = r.figure("manuscripts-public.next_box") {
                    let f = r.figures["manuscripts-public.next_box"]
                    let n = f?["n"]?.double.map { Int($0) } ?? 0
                    var before = ""
                    if case .string(let m)? = f?["metric"],
                       let range = m.range(of: #"corpus 2B ([\d.]+)%"#, options: .regularExpression) {
                        let num = m[range].split(separator: " ").last.map { String($0.dropLast()) } ?? ""
                        if let b = Double(num) {
                            before = String(format: ", against %.0f%% for the app's own document finder on that same box, a "
                                            + "different box from the test boxes in the table", b)
                        }
                    }
                    measured = String(format: "%.0f%% of pages in the right document on the next box of the same "
                                      + "papers%@ (%d pages)", v, before, n)
                }
            default: break
            }
            return SettingsRangeChart.KitPoint(id: p.id, name: Self.kitName(p.id, r), measured: measured,
                                               condition: Self.kitCondition(p.reason), y: y, caveats: r.caveats)
        }
    }

    static func kitName(_ id: String, _ r: SettingsRouteTable.Route) -> String {
        [
            "kit-hands-ppocrv6-ft": "kraken PP-OCRv6 trained on lines you corrected in one person's hand, on this Mac",
            "kit-seg-lora-mac": "The document finder trained on this Mac",
            "kit-seg-student-tags": "A document finder trained on your collection's own tags or folders, on a computing cluster",
            "seg-2b-lora-k200": "The app's document finder adapted to your papers, on a computing cluster",
        ][id] ?? r.name
    }

    /// The solver's kit reasons (`SettingsSolver.kitPoints`) in the sheet's words.
    static func kitCondition(_ r: String) -> String {
        if r.hasPrefix("shown only where the handwriting reader is kraken") {
            return "Shown only when handwriting is read by kraken PP-OCRv6 on this Mac, the reader it improves."
        }
        if let m = r.range(of: #"^needs 80 corrected lines of one hand \((\d+) so far"#, options: .regularExpression) {
            let n = r[m].split(separator: "(").last?.split(separator: " ").first ?? "0"
            return "Appears once you have corrected 80 lines written by one person (\(n) so far); 160 is the aim."
        }
        if r.hasPrefix("after training on") {
            return "Can be trained now from your corrected lines; it is used only after it passes a check on pages it "
                + "never saw."
        }
        if r.hasPrefix("not offered: not measured to fit") {
            return "Not offered: training it on a Mac has not been shown to fit in memory."
        }
        if r.hasPrefix("shown when the collection has tags") {
            return "Shown when this collection already has tags, or one folder per document, to learn from."
        }
        if r == "needs the Mac build step" {
            return "Not usable yet: a version of the trained model that runs on this Mac has still to be built."
        }
        if r.hasPrefix("after training on the collection's own tags") {
            return "Can be trained from this collection's own tags; it is used only after it passes a check on pages it "
                + "never saw."
        }
        if let m = r.range(of: #"^needs 200 corrected gaps of one material \((\d+) so far"#, options: .regularExpression) {
            let n = r[m].split(separator: "(").last?.split(separator: " ").first ?? "0"
            return "Appears once you have corrected 200 places where documents begin, in one kind of papers (\(n) so far)."
        }
        if r.hasPrefix("the next boxes of this material") {
            return "For the next boxes of the same papers; places it is unsure of are still shown to you to check."
        }
        return r.prefix(1).uppercased() + r.dropFirst()
    }
}
