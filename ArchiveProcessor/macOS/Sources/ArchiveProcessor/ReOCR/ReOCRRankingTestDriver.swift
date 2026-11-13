#if DEBUG // a test driver, compiled out of Release
import ArchiveCore
import Foundation

/// Headless, $0 self-test of the Improve OCR ranked readers (W44.reocr-processor), gated by `REOCR_RANKING_TEST=1`
/// (does nothing in normal use). No model call, no network, no Keychain read, no window, never the corpus. Run by
/// `scripts/test-reocr-ranking.sh`.
///
/// What has to be true:
///   1. Each kind ranks on its own figure from the bundled rule table, best first; only routes the app runs are rows,
///      cluster routes are listed apart, and stage rules keep their routes out with the rule named.
///   2. Changing the kind re-ranks the list.
///   3. Readiness, price and the selection's estimate follow the resources; unknown stays unknown.
///   4. Ties come from the pair matrix, else the solver's floors; a route with no figure is "not measured", last.
///   5. The current reader is marked from the header's display strings, or named apart when no row matches.
///   6. A selection groups by settled kind; an unsure classifier call is no kind.
@MainActor
enum ReOCRRankingTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["REOCR_RANKING_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    static func run() {
        defer { finish() }
        guard let table = SettingsRouteTable.bundled, table.problems().isEmpty else {
            check("0 bundled settings-routes.json decodes and is fit", false)
            return
        }
        let pairs: OCRPairMatrix? = Bundle.main.url(forResource: OCRPairMatrix.resourceName, withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(OCRPairMatrix.self, from: $0) }
        check("0 bundled pair matrix decodes", pairs != nil)
        let models = OCRCascade.candidates + LLMModel.appleVisionModels
        var keyed = SettingsResources(macMemoryGB: 16)
        keyed.keys = ["gemini", "openrouter", "openai", "mistral", "anthropic"]

        let reading = table.stage("reading")
        func route(_ id: String) -> SettingsRouteTable.Route? { reading?.route(id) }

        func rank(_ kind: OCRPageKind, pages: Int = 10, resources: SettingsResources = keyed, staysOnMac: Bool = false,
                  current: PDFReaderProvenance? = nil, in t: SettingsRouteTable = table) -> ReOCRRanking {
            ReOCRRanking.rank(kind: kind, pages: pages, table: t, pairs: pairs, resources: resources,
                              staysOnMac: staysOnMac, current: current)
        }

        // 1. Each kind's own figure, best first, app routes only.
        for kind in OCRPageKind.allCases {
            let r = rank(kind)
            let figures = r.rows.compactMap(\.figure)
            check("1 \(kind.rawValue): rows best first", figures == figures.sorted(by: >), "\(figures)")
            check("1 \(kind.rawValue): every row runs in the app",
                  r.rows.allSatisfy { route($0.id).flatMap { ReOCRRanking.executable($0, builtInModels: models) } != nil })
            check("1 \(kind.rawValue): no cascade and no cluster route is a row",
                  r.rows.allSatisfy { row in route(row.id).map { $0.stages == nil && $0.family != .cluster } ?? false })
            check("1 \(kind.rawValue): cluster readings listed apart",
                  !r.institutional.isEmpty && r.institutional.allSatisfy { route($0.id)?.family == .cluster })
            check("1 \(kind.rawValue): apple-fm-27 left out by its rule",
                  r.leftOut.contains { $0.id == "apple-fm-27" && $0.reason.contains("no-apple-fm") })
            check("1 \(kind.rawValue): unoffered app-less routes left out with a reason",
                  r.leftOut.contains { $0.reason == "not in the app yet" })
        }
        let typed = rank(.typewritten)
        eq("1 typewritten ranks on the typewritten figure", typed.metric.key, "typewritten")
        if let first = typed.rows.first, let r = route(first.id) {
            eq("1 typewritten best row's figure is its table figure", first.figure, r.figure("typewritten"))
            eq("1 typewritten sample is the table's n", first.sample, "50")
            eq("1 with every key the best row is the reference", first.tie, .reference)
        } else {
            check("1 typewritten has rows", false)
        }
        check("1 Apple Vision is a typewritten row", typed.rows.contains { $0.id == "apple-vision" })
        let hand = rank(.handwritten)
        eq("1 handwriting ranks on the 16 hands", hand.metric.key, "hands16")
        check("1 handwriting leaves Apple Vision out (owner call 4)",
              !hand.rows.contains { $0.id == "apple-vision" }
              && hand.leftOut.contains { $0.id == "apple-vision" && $0.reason.contains("owner call 4") })
        check("1 a hands sample names its failures", hand.rows.first?.sample?.contains("failed") == true,
              hand.rows.first?.sample ?? "nil")
        let forms = rank(.forms)
        check("1 forms with no app route measured on L4 fall back to the overall figure, labelled",
              forms.metric.isFallback && forms.metric.key == "overall:answered"
              && forms.metric.label.hasPrefix("not measured on forms"), forms.metric.label)
        if let q = forms.rows.first(where: { $0.id == "qwen3.8-flash" }) {
            eq("1 the forms fallback ranks on the solver's answered overall figure", q.figure, route(q.id)?.figure("overall"))
        } else {
            check("1 qwen3.8-flash is a forms row", false)
        }
        eq("1 with no second reader the fallback is strict",
           ReOCRRanking.rank(kind: .forms, pages: 1, table: table, pairs: pairs, resources: keyed, staysOnMac: false,
                             readingFallback: false).metric.key, "overall:strict")

        // 2. A kind change re-ranks.
        check("2 typewritten and handwritten rank differently",
              typed.rows.map(\.id) != hand.rows.map(\.id), "\(typed.rows.map(\.id))")
        check("2 printed ranks on its own figure", rank(.printed).metric.key == "printed")

        // 3. Readiness, price, estimate.
        let bare = rank(.typewritten, pages: 250, resources: SettingsResources(macMemoryGB: 16))
        check("3 with no keys Apple Vision alone is ready",
              bare.rows.filter { $0.readiness == .ready }.map(\.id) == ["apple-vision"],
              "\(bare.rows.filter { $0.readiness == .ready }.map(\.id))")
        if let g = bare.rows.first(where: { $0.id == "gemini3.8-flash" }) {
            eq("3 a Gemini row without its key needs setup", g.readiness, .needsSetup("needs a Gemini key"))
            eq("3 price per 1,000 is the table's list price", g.usdPer1000, table.stage("reading")?.route(g.id)?.listUSDPer1000)
            check("3 the estimate is per page × pages",
                  abs((g.estimateUSD ?? -1) - (g.usdPer1000 ?? 0) * 0.25) < 1e-9, "\(String(describing: g.estimateUSD))")
        } else {
            check("3 gemini3.8-flash is a row", false)
        }
        if let v = bare.rows.first(where: { $0.id == "apple-vision" }) {
            eq("3 Apple Vision costs nothing", v.estimateUSD, 0)
        } else {
            check("3 Apple Vision is a row", false)
        }
        eq("3 with no keys the reference is the best ready row, Apple Vision",
           bare.rows.first { $0.tie == .reference }?.id, "apple-vision")
        check("3 rows measured above an unready reference are ahead or tied",
              bare.rows.prefix { $0.id != "apple-vision" }.allSatisfy {
                  if case .ahead = $0.tie { return true }
                  if case .tied = $0.tie { return true }
                  return $0.figure == nil
              })
        eq("3 with no keys the suggestion is Apple Vision", bare.suggestedID, "apple-vision")
        // The table reaches Gemini routes through OpenRouter too, but the app runs them with a Gemini key.
        var orOnly = SettingsResources(macMemoryGB: 16)
        orOnly.keys = ["openrouter"]
        let or = rank(.typewritten, resources: orOnly)
        check("3 an OpenRouter key alone readies only OpenRouter rows and Apple Vision",
              or.rows.allSatisfy { ($0.readiness == .ready) == ($0.provider == .openrouter || $0.provider == .appleVision) },
              "\(or.rows.map { "\($0.id) \($0.readiness)" })")
        if let g = or.rows.first(where: { $0.provider == .gemini }) {
            eq("3 a Gemini row with only an OpenRouter key needs a Gemini key", g.readiness, .needsSetup("needs a Gemini key"))
        } else {
            check("3 a Gemini row exists", false)
        }
        let mac = rank(.typewritten, staysOnMac: true)
        check("3 a batch that stays on the Mac disables every hosted row",
              mac.rows.allSatisfy { $0.provider == .appleVision ? $0.readiness == .ready
                  : $0.readiness == .needsSetup("this batch stays on the Mac") })
        check("3 keyed rows are ready", typed.rows.allSatisfy { $0.readiness == .ready },
              "\(typed.rows.filter { $0.readiness != .ready }.map { "\($0.id) \($0.readiness)" })")

        // 4. Ties and the suggestion.
        if let sid = typed.suggestedID, let srow = typed.rows.first(where: { $0.id == sid }),
           let refRow = typed.rows.first(where: { $0.tie == .reference }) {
            let tiedOrRef: (ReOCRRanking.Row) -> Bool = { r in
                if r.tie == .reference { return true }
                if case .tied = r.tie { return true }
                return false
            }
            check("4 the suggestion is tied with the reference", tiedOrRef(srow))
            check("4 the suggestion is the cheapest tied ready row",
                  typed.rows.filter { tiedOrRef($0) && $0.readiness == .ready }
                      .allSatisfy { ($0.usdPer1000 ?? .infinity) >= (srow.usdPer1000 ?? .infinity) })
            check("4 the suggestion costs no more than the reference",
                  (srow.usdPer1000 ?? .infinity) <= (refRow.usdPer1000 ?? .infinity))
        } else {
            check("4 typewritten has a suggestion", false)
        }
        let tiedFromMatrix = typed.rows.contains { if case .tied(let g?) = $0.tie { return g.underFloor } else { return false } }
        let behindFromMatrix = typed.rows.contains { if case .behind(let g?) = $0.tie { return !g.underFloor } else { return false } }
        check("4 some typewritten row ties the leader on the pair matrix", tiedFromMatrix)
        check("4 some typewritten row is behind the leader on the pair matrix", behindFromMatrix)
        if let synthetic = syntheticTable() {
            let s = ReOCRRanking.rank(kind: .typewritten, pages: 4, table: synthetic, pairs: nil, resources: keyed,
                                      staysOnMac: false)
            eq("4 synthetic: order, unmeasured last", s.rows.map(\.id), ["a", "b", "c", "d"])
            if s.rows.count == 4 {
                eq("4 synthetic: within the hosted floor is a tie", s.rows[1].tie, .tied(nil))
                eq("4 synthetic: beyond the floor is behind", s.rows[2].tie, .behind(nil))
                eq("4 synthetic: no figure is not measured", s.rows[3].tie, .notMeasured)
                eq("4 synthetic: no price is unknown, not zero", s.rows[3].usdPer1000, nil)
                eq("4 synthetic: no price, no estimate", s.rows[3].estimateUSD, nil)
                eq("4 synthetic: the cheaper tied row is suggested", s.suggestedID, "b")
            }
            check("4 synthetic: a model the app lacks is left out",
                  s.leftOut.contains { $0.id == "x" && $0.reason == "not in the app yet" })
            check("4 synthetic: an unoffered route is left out with its condition",
                  s.leftOut.contains { $0.id == "y" && $0.reason.hasPrefix("not offered") })
        } else {
            check("4 synthetic table decodes", false)
        }

        // 5. The current reader.
        if let g = models.first(where: { $0.provider == .gemini && $0.id == "gemini-3.8-flash" }) {
            let cur = rank(.typewritten, current: PDFReaderProvenance(provider: "Gemini", model: g.displayName,
                                                                      processingDate: "1 January 2026"))
            eq("5 the header's reader is marked", cur.rows.filter(\.isCurrent).map(\.id), ["gemini3.8-flash"])
            eq("5 a matched reader is not named apart", cur.currentUnmatched, nil)
        } else {
            check("5 gemini-3.8-flash is a built-in model", false)
        }
        let old = rank(.typewritten, current: PDFReaderProvenance(provider: "Gemini", model: "Gemini 1.0 Ultra",
                                                                  processingDate: "1 January 2024"))
        check("5 an old reader marks no row", !old.rows.contains(where: \.isCurrent))
        eq("5 and is named apart", old.currentUnmatched, "Gemini · Gemini 1.0 Ultra")
        let vision = rank(.printed, current: PDFReaderProvenance(provider: "Apple Vision", model: "macOS Vision",
                                                                 processingDate: "1 January 2026"))
        eq("5 Apple Vision is marked from its header", vision.rows.filter(\.isCurrent).map(\.id), ["apple-vision"])

        // 6. Grouping.
        let pages = [
            ReOCRPageChoice(fileID: "f1", pairIndex: 0, kind: .handwritten, origin: .header),
            ReOCRPageChoice(fileID: "f1", pairIndex: 1, kind: .typewritten, origin: .classifier, confidence: 0.95),
            ReOCRPageChoice(fileID: "f2", pairIndex: 0, kind: .typewritten, origin: .classifier, confidence: 0.5),
            ReOCRPageChoice(fileID: "f3", pairIndex: 0, kind: nil, origin: nil),
            ReOCRPageChoice(fileID: "f4", pairIndex: 0, kind: .forms, origin: .person),
        ]
        let groups = ReOCRGrouping.groups(pages)
        eq("6 groups in the dialog's order", groups.map(\.kind), [.handwritten, .typewritten, .forms, nil])
        eq("6 an unsure classifier call joins the pages with no kind",
           groups.last?.pages.map(\.fileID), ["f2", "f3"])
    }

    /// A small table for the cases the bundled one does not hold: a route with no figure or price, one the app
    /// lacks, one not offered.
    private static func syntheticTable() -> SettingsRouteTable? {
        func route(_ id: String, _ app: String?, _ figure: Double?, _ price: Double?, conditions: [String] = []) -> String {
            let figures = figure.map { "{\"typewritten\": {\"value\": \($0), \"n\": 50}}" } ?? "{}"
            let cost = price.map { "{\"usd_1000_list\": \($0)}" } ?? "null"
            let appRoute = app.map { "\"\($0)\"" } ?? "null"
            let cond = conditions.map { "\"\($0)\"" }.joined(separator: ",")
            return """
            {"id": "\(id)", "name": "Route \(id)", "family": "cloud", "app_route": \(appRoute), "status": "shipped",
             "needs": {"key": ["gemini"]}, "figures": \(figures), "cost": \(cost), "conditions": [\(cond)]}
            """
        }
        let json = """
        {"version": 1, "built": "test", "stages": [{"id": "reading", "name": "Reading", "unit": "page", "choice": true,
         "kinds": ["typewritten"], "routes": [
          \(route("c", "gemini|gemini-3.1-pro", 90.0, 20)),
          \(route("a", "gemini|gemini-3.8-flash", 95.0, 3)),
          \(route("d", "gemini|gemini-3.5-flash", nil, nil)),
          \(route("b", "gemini|gemini-3.5-flash-lite", 94.7, 1)),
          \(route("x", "gemini|no-such-model", 99.0, 1)),
          \(route("y", "gemini|gemini-3.1-flash-lite", 99.0, 1, conditions: ["not offered: a measured loss"]))
         ]}]}
        """
        return try? SettingsRouteTable.decode(Data(json.utf8))
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["REOCR_RANKING_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}

#endif
