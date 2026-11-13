#if DEBUG // a test driver, compiled out of Release
import Foundation

/// Headless, $0 self-test of the settings solver (W46.settings-solver), gated by `SETTINGS_SOLVER_TEST=1` (does nothing
/// in normal use). No model call, no network, no Keychain read (the resources are passed in), no window. Run by
/// `scripts/test-settings-solver.sh`.
///
/// Every case of `execution-plans/processing-review/13-stage-rules/13-profile-tests.md` is a check here, named by its
/// letter; a case that waits for a figure is a SKIP naming the item it waits for. Every pick must also explain itself
/// in one sentence naming its evidence row (its route id, and a reading tie its pair entry).
@MainActor
enum SettingsSolverTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SETTINGS_SOLVER_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in run() }
    }

    private static var lines: [String] = []
    private static var failures = 0
    private static var solved: [(String, SettingsSolution)] = []

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    private static func skip(_ name: String, _ why: String) { lines.append("SKIP \(name): \(why)") }

    /// A part's route id, or its flag ("flag: needs a download or a key"); `none` for no names.
    private static func pick(_ s: SettingsSolution, _ stage: String, _ part: String = "all") -> String {
        guard let p = s.pick(stage, part) else { return "missing" }
        if p.flag == "none" { return "none" }
        if let id = p.routeID, p.flag == nil { return id }
        return "flag: \(p.flag ?? "?")"
    }

    /// Every part's route id, for comparing two profiles that must pick alike.
    private static func picks(_ s: SettingsSolution) -> [String: String] {
        Dictionary(uniqueKeysWithValues: s.picks.map { ("\($0.stage)/\($0.part)", pick(s, $0.stage, $0.part)) })
    }

    static func run() {
        defer { finish() }
        let table: SettingsRouteTable
        do { table = try SettingsRouteTable.loadBundled() } catch {
            check("0 bundled settings-routes.json decodes", false, "\(error)")
            return
        }
        check("0 settings-routes.json fit to ship", table.problems().isEmpty, table.problems().joined(separator: "; "))
        guard let pairs = OCRPairMatrix.bundled else {
            check("0 bundled ocr-pair-matrix.json decodes", false)
            return
        }
        check("0 pair matrix holds the reading pairs (\(pairs.pairs.count))", pairs.pairs.count > 1000)
        if let g = pairs.gap("owner96", "all", "qwen3.8-flash", "qwen3.6-27b", score: "answered") {
            check("0 a pair reads either way round", g.citation.hasPrefix("−0.08 [−1.62, +1.64], n 91"), g.citation)
        } else {
            check("0 the C pair is in the matrix", false)
        }

        func solve(_ name: String, _ r: SettingsResources, _ a: SettingsAnswers = SettingsAnswers()) -> SettingsSolution {
            let s = SettingsSolver(table: table, pairs: pairs, resources: r, answers: a).solve()
            solved.append((name, s))
            return s
        }
        func mac(_ gb: Double, downloads: Bool = true) -> SettingsResources {
            SettingsResources(macMemoryGB: gb, downloadsAllowed: downloads)
        }
        var noNames = SettingsAnswers()
        noNames.priorities = [.reading, .findingDocuments, .dates]

        // B1. 16 GB, no key, no plan, no cluster, downloads allowed.
        let b1 = solve("B1", mac(16))
        eq("B1 reading typewritten: Apple Vision, the free default", pick(b1, "reading", "typewritten"), "apple-vision")
        eq("B1 reading printed: Apple Vision", pick(b1, "reading", "printed"), "apple-vision")
        eq("B1 reading handwritten: LightOnOCR-3 4B offered as a download", pick(b1, "reading", "handwritten"),
           "lightonocr-3-4b-mlx8")
        eq("B1 downloads declined: handwriting flagged, never read at 60",
           pick(solve("B1-nodl", mac(16, downloads: false)), "reading", "handwritten"), "flag: needs a download or a key")
        check("B1 the free cascade waits for a Mac escalation stage",
              b1.blockers("reading", "casc-free-fail").contains { $0.hasPrefix("waits for:") })
        skip("B1 cascade casc-free-fail", "pending the cascade rows' Mac memory per tier (note 10 §8)")
        skip("B1 layout regions on newspapers only", "a rule, not a pick: the sheet's rules tab (W46.settings-sheet)")
        eq("B1 segmentation: the 2B", pick(b1, "segmentation"), "seg-qwen3.5-2b-8bit")
        eq("B1 dating step 1: the Vision 2B chooser", pick(b1, "dating", "step 1"), "vision-2b-chooser-t3")
        eq("B1 dating step 4: the Vision 2B chooser", pick(b1, "dating", "step 4"), "vision-2b-chooser-t3")
        skip("B1 dating step 2 qwen3-vl-8b-image-mac", "pending item 8.1 (08-dating.md §8)")
        eq("B1 names ranked: typed correspondence the 8B", pick(b1, "entities", "correspondence-typed"), "qwen3-vl-8b-mac")
        eq("B1 names ranked: none on handwriting from Vision text", pick(b1, "entities", "correspondence-handwritten"), "none")
        eq("B1 names: none on non-correspondence", pick(b1, "entities", "non-correspondence"), "none")
        eq("B1 names not ranked: nothing on the Mac", pick(solve("B1-nonames", mac(16), noNames), "entities",
                                                          "correspondence-typed"), "none")
        // Placement is a rule stage, so the hand route is not a pick; its memory fit is the solver's rule all the same
        // (W46.place-hands-cost: 8.51 GB measured, plus the headroom).
        if let hand = table.stage("placement")?.routes.first(where: { $0.id == "hand-blla-ctc" }) {
            let fit = { (gb: Double) in
                SettingsSolver(table: table, pairs: pairs, resources: mac(gb), answers: SettingsAnswers())
                    .blockers(hand, stage: "placement")
            }
            check("B1 hand placement fits 16 GB", fit(16).isEmpty, fit(16).joined(separator: "; "))
            check("B3 hand placement does not fit 8 GB", fit(8).contains { $0.hasPrefix("needs about 14 GB of memory") },
                  fit(8).joined(separator: "; "))
        } else {
            check("B1 the placement stage has hand-blla-ctc", false)
        }
        check("B1 kit: no row", b1.afterTraining.isEmpty)

        // B2. 32 and 64 GB pick as B1: no 27B-class Mac row exists to borrow cluster figures for.
        eq("B2 32 GB picks as B1", picks(solve("B2-32", mac(32))), picks(b1))
        eq("B2 64 GB picks as B1", picks(solve("B2-64", mac(64))), picks(b1))
        skip("B2 a 27B-class reader on a Mac", "pending W46.ocr-mac-27b, W46.date-mac-27b, W46.ent-local-shipped-prompt")

        // B3 (and router case G1). 8 GB: every stage has a free pick or manual.
        let b3 = solve("B3", mac(8))
        eq("B3 reading typewritten: Vision", pick(b3, "reading", "typewritten"), "apple-vision")
        eq("B3 reading handwritten: flagged, no download fits", pick(b3, "reading", "handwritten"),
           "flag: needs a download or a key")
        eq("B3 segmentation: manual", pick(b3, "segmentation"), "manual")
        eq("B3 dating: Vision rules", pick(b3, "dating", "step 1"), "vision-rules-t3")
        eq("B3 names: none", pick(b3, "entities", "correspondence-typed"), "none")
        check("G1 no card empty", b3.picks.allSatisfy { !$0.reason.isEmpty })

        // B4 (and G2). B1 with a Gemini key and "this batch stays on the Mac".
        var onMac = SettingsAnswers()
        onMac.staysOnMac = true
        var gemMac = mac(16)
        gemMac.keys = ["gemini"]
        let b4 = solve("B4", gemMac, onMac)
        eq("B4 picks as B1", picks(b4), picks(b1))
        check("G2 the Gemini reader is hollow: stays on the Mac",
              b4.blockers("reading", "gemini3.8-flash").contains("this batch stays on the Mac"),
              b4.blockers("reading", "gemini3.8-flash").joined(separator: "; "))
        check("G2 the Gemini segmenter is hollow: stays on the Mac",
              b4.blockers("segmentation", "gemini3.8-flash").contains("this batch stays on the Mac"))
        check("G2 the Claude plan row is hollow: stays on the Mac",
              b4.blockers("segmentation", "claude-sonnet5.5").contains("this batch stays on the Mac"))

        // A. A skipped interview is "Free, on this Mac", whatever keys are found.
        let a = solve("A", gemMac, SettingsAnswers.skippedInterview)
        eq("A reading as B1", pick(a, "reading", "handwritten"), pick(b1, "reading", "handwritten"))
        eq("A segmentation as B1", pick(a, "segmentation"), pick(b1, "segmentation"))
        eq("A dating as B1", pick(a, "dating", "step 1"), pick(b1, "dating", "step 1"))
        eq("A no names on the Mac until ranked", pick(a, "entities", "correspondence-typed"), "none")
        check("A detected key listed hollow, nothing spent", a.usd == 0
              && a.blockers("reading", "gemini3.8-flash").contains("this batch stays on the Mac"))

        // C. An OpenRouter key, Gemini models not used.
        var orKey = mac(16)
        orKey.keys = ["openrouter"]
        orKey.excludedModelFamilies = ["gemini"]
        let c = solve("C", orKey)
        eq("C reading: Qwen3.8 Flash ties Qwen3.6 27B and is cheaper", pick(c, "reading"), "qwen3.8-flash")
        check("C reading cites its pair", c.pick("reading", "all")?.gap?.citation == "−0.08 [−1.62, +1.64], n 91, owner96/all/answered",
              c.pick("reading", "all")?.gap?.citation ?? "no pair")
        eq("C its refusals go on to Qwen3.6 27B", c.pick("reading", "all")?.fallbackRouteID, "qwen3.6-27b")
        var strict = SettingsAnswers()
        strict.readingFallback = false
        // Note 04 §9 profile 2 says Qwen3.6 27B here, weighing Qwen3.8 Flash alone; Qwen3-VL 235B ties the 27B under
        // the floor on strict (+0.37 [−1.92, +2.16], n 95) and is cheaper, so the rule picks it.
        let cs = solve("C-strict", orKey, strict)
        eq("C no fallback (strict): Qwen3-VL 235B ties Qwen3.6 27B and is cheaper", pick(cs, "reading"), "qwen3-vl-235b")
        check("C strict cites its pair", cs.pick("reading", "all")?.gap?.citation == "−0.37 [−2.16, +1.92], n 95, owner96/all/strict",
              cs.pick("reading", "all")?.gap?.citation ?? "no pair")
        eq("C handwritten: Qwen3.6 27B (Mistral Large 4 ties, dearer)", pick(c, "reading", "handwritten"), "qwen3.6-27b")
        eq("C segmentation on 16 GB: the 2B ties GLM and is free", pick(c, "segmentation"), "seg-qwen3.5-2b-8bit")
        var or8 = orKey
        or8.macMemoryGB = 8
        let c8 = solve("C-8", or8)
        eq("C segmentation, the 2B out: GLM-5.3 Flash", pick(c8, "segmentation"), "glm5.3-flash")
        eq("C names, the Mac's 8B out: Qwen3.6 27B", pick(c8, "entities", "correspondence-typed"), "qwen3.6-27b")
        eq("C names on handwriting: Qwen3.6 27B", pick(c8, "entities", "correspondence-handwritten"), "qwen3.6-27b")
        skip("C dating", "pending W46.date-route-pipeline (no trace row an OpenRouter-only key reaches)")
        // A key whose routes cost more than the ceiling: Vision for typed and printed, and handwriting flagged, never
        // read by Vision (owner call 4).
        var zero = SettingsAnswers()
        zero.ceilingUSD = 0
        var gemNoDL = mac(16, downloads: false)
        gemNoDL.keys = ["gemini"]
        let z = solve("key-zero-ceiling", gemNoDL, zero)
        eq("A key at a $0 ceiling: typed pages Vision", pick(z, "reading", "typewritten"), "apple-vision")
        eq("A key at a $0 ceiling: handwriting flagged, not Vision", pick(z, "reading", "handwritten"),
           "flag: needs a download or a key")
        // Cascades the shipped cascade cannot run (a kind or disagreement trigger) are never picked.
        var orAll = mac(16)
        orAll.keys = ["openrouter"]
        let cn = solve("C-strict-gemini", orAll, strict)
        check("An unbuilt cascade is not picked", !["casc-2-vision-hands", "casc-disagree-0.5"].contains(pick(cn, "reading")),
              pick(cn, "reading"))
        check("An unbuilt cascade says what it waits for",
              cn.blockers("reading", "casc-2-vision-hands").contains { $0.hasPrefix("waits for: not built") })

        // G6. A kind with no figure for the chosen route: forms on an OpenRouter-only key.
        var forms = SettingsAnswers()
        forms.mix["forms"] = 10
        let g6 = solve("G6", orKey, forms)
        eq("G6 forms: no figure, read by the batch's reader", pick(g6, "reading", "L4"), "flag: no figure")
        eq("G6 forms keep the overall reader", g6.pick("reading", "L4")?.routeID, g6.pick("reading", "all")?.routeID)
        check("G6 the figure is never borrowed", g6.pick("reading", "L4")?.figure == nil)

        // D1. A Gemini key.
        var gem = mac(16)
        gem.keys = ["gemini"]
        let d1 = solve("D1", gem)
        eq("D1 reading: Gemini 3.8 Flash ties Gemini 3.1 Pro and is cheaper", pick(d1, "reading"), "gemini3.8-flash")
        check("D1 reading cites its pair", d1.pick("reading", "all")?.gap?.citation.contains("owner96/all/answered") == true)
        eq("D1 handwritten: Gemini 3.8 Flash", pick(d1, "reading", "handwritten"), "gemini3.8-flash")
        check("D1 no cascade beats Gemini 3.8 Flash", !pick(d1, "reading").hasPrefix("casc-"))
        eq("D1 segmentation: Gemini 3.8 Flash", pick(d1, "segmentation"), "gemini3.8-flash")
        // W46.seg-text-tier-app: the text-only tier ties it for half the price, but is the user's choice only.
        check("D1 the text-only tier is the user's choice only",
              table.stage("segmentation")?.route("gemini3.8-flash-text")?.userChoiceOnly == true)
        var textChosen = SettingsAnswers()
        textChosen.onlyRoutes["segmentation"] = ["gemini3.8-flash-text"]
        eq("D1 the text-only tier runs when the user chooses it", pick(solve("D1-text", gem, textChosen), "segmentation"),
           "gemini3.8-flash-text")
        eq("D1 names: the entity feature's own prompt", pick(d1, "entities", "correspondence-typed"),
           "gemini-entity-feature")
        check("D1 names: the tagging call's rows are history, not offered",
              !d1.blockers("entities", "gemini-tagging-place").isEmpty)
        skip("D1 dating steps 2 and 4", "pending W46.date-route-pipeline (the 3.7 rows are the gateway's)")

        // D2 (and G3). A Gemini key, ceiling $1 for 1,000 pages, 24 hours (batch prices).
        var tight = SettingsAnswers()
        tight.ceilingUSD = 1
        tight.hours = 24
        let d2 = solve("D2", gem, tight)
        eq("D2 reading: Gemini 3.5 Flash-Lite, the best that fits", pick(d2, "reading"), "gemini3.5-flash-lite")
        let short = d2.pick("reading", "all")?.better.first { $0.id == "gemini3.8-flash" }
        check("G3 the card names Gemini 3.8 Flash and the $0.61 shortfall", short?.reason.contains("$0.61") == true,
              short?.reason ?? "not listed")
        check("D2 segmentation spends nothing", ["seg-qwen3.5-2b-8bit", "manual"].contains(pick(d2, "segmentation")),
              pick(d2, "segmentation"))
        check("G3 within the ceiling", d2.usd <= 1 + 1e-9, "\(d2.usd)")
        let segShort = d2.pick("segmentation", "all")?.better.first { $0.id == "gemini3.8-flash" }
        check("G3 segmentation at its list price: Gemini 3.8 Flash $3.61 against what is left",
              segShort.map { $0.reason.hasPrefix("raise the ceiling by $") } == true, segShort?.reason ?? "not listed")

        // D3. The Claude plan only.
        var claude = mac(16)
        claude.plans = ["claude"]
        let d3 = solve("D3", claude)
        eq("D3 reading: Claude Sonnet 5.5 on the plan", pick(d3, "reading"), "claude-sonnet5.5")
        eq("D3 segmentation: Claude Sonnet 5.5", pick(d3, "segmentation"), "claude-sonnet5.5")
        eq("D3 dating: no plan row, the Mac route", pick(d3, "dating", "step 1"), "vision-2b-chooser-t3")
        eq("D3 names: no plan row, the Mac route", pick(d3, "entities", "correspondence-typed"), "qwen3-vl-8b-mac")
        check("D3 no money", d3.usd == 0, "\(d3.usd)")

        // D4. The ChatGPT plan only, and both plans.
        var chatgpt = mac(16)
        chatgpt.plans = ["chatgpt"]
        let d4 = solve("D4", chatgpt)
        eq("D4 reading: no ChatGPT row, falls to B1", pick(d4, "reading", "typewritten"), "apple-vision")
        eq("D4 segmentation: ChatGPT", pick(d4, "segmentation"), "chatgpt-gpt6.1-sol")
        var both = mac(16)
        both.plans = ["claude", "chatgpt"]
        eq("D4 both plans: segmentation the mix", pick(solve("D4-both", both), "segmentation"), "mix-claude-chatgpt")

        // D5. A Claude plan and a Gemini key, cheapest within a point.
        var d5r = claude
        d5r.keys = ["gemini"]
        var cheap = SettingsAnswers()
        cheap.preference = .cheapestWithinPoint
        // W46.seg-g2-offsets: Gemini's 88.8 (3.7's g2 answers, 88.8-89.1 over three window offsets) is 3.3 points
        // over Claude's 85.5, under the 4.2 floor (twice 2.1, the larger offset range of the two: Claude has none
        // measured and takes the largest), so a tie and the plan wins on money.
        eq("D5 segmentation: Gemini 3.3 points ahead, under the 4.2 floor, so the plan", pick(solve("D5", d5r, cheap), "segmentation"),
           "claude-sonnet5.5")
        let ranges = (table.stage("segmentation")?.routes ?? []).compactMap { $0.figure("test-boxes.offset_range") }
        check("segmentation floor is twice the largest measured offset range",
              abs(SettingsSolver.segmentationTie - 2 * (ranges.max() ?? 0)) < 0.05, "\(ranges)")

        // E. A cluster (Sherlock), two GPUs a job, no key; nothing downloaded to the Mac.
        var cl = mac(16, downloads: false)
        cl.cluster = true
        cl.gpusPerJob = 2
        var ea = SettingsAnswers()
        ea.mix = ["typewritten": 50, "printed": 28, "handwritten": 16, "forms": 5, "newspapers": 5]
        ea.strata = Dictionary(uniqueKeysWithValues: ["N6", "L5", "L6", "L7", "L8", "N1", "N3", "N4"].map { ($0, 1.0) })
        let e = solve("E", cl, ea)
        eq("E reading: Qwen3.6 27B ties Qwen3.5 27B and is faster", pick(e, "reading"), "qwen3.6-27b-farmshare")
        check("E reading cites its pair", e.pick("reading", "all")?.gap?.citation == "−0.07 [−0.71, +0.47], n 95, owner96/all/answered",
              e.pick("reading", "all")?.gap?.citation ?? "no pair")
        eq("E handwritten: Infinity-Parser2-Pro, the L1-L3 leader", pick(e, "reading", "handwritten"),
           "infinity-parser2-pro-sherlock")
        eq("E newspapers: Qwen3.5 27B, the L9 leader", pick(e, "reading", "L9"), "qwen3.5-27b-farmshare")
        eq("E forms: Qwen3.5 27B, the L4 leader", pick(e, "reading", "L4"), "qwen3.5-27b-farmshare")
        eq("E N6: Xiaomi-OCR-0", pick(e, "reading", "N6"), "xiaomi-ocr-0-sherlock")
        for s in ["L5", "L6", "L7", "L8", "N1", "N3", "N4"] {
            eq("E \(s): CHURRO 3B", pick(e, "reading", s), "churro-3b-farmshare")
        }
        eq("E segmentation: the cluster 2B, fastest of three ties", pick(e, "segmentation"), "seg-qwen3.5-2b-bf16-cluster")
        eq("E dating step 1: the 27B trace", pick(e, "dating", "step 1"), "qwen3.6-27b-trace-neigh-vision")
        eq("E dating step 4: the 27B trace", pick(e, "dating", "step 4"), "qwen3.6-27b-trace-neigh-vision")
        eq("E dating step 2: the 27B image pass", pick(e, "dating", "step 2"), "qwen3.6-27b-image")
        eq("E names: Qwen3.6 27B", pick(e, "entities", "correspondence-typed"), "qwen3.6-27b")
        check("E the teacher is a partner, not a voter alone",
              e.blockers("segmentation", "qwen3.5-27b-teacher").contains { $0.contains("not as a voter alone") })
        var clKey = cl
        clKey.keys = ["openrouter"]
        eq("E with a key as well: names from the entity feature's prompt (note 09 §9 profile 4)",
           pick(solve("E-key", clKey, ea), "entities", "correspondence-typed"), "gemini-entity-feature")
        clKey.excludedModelFamilies = ["gemini"]
        let ek = solve("E-key-nogemini", clKey, ea)
        eq("E with an OpenRouter key, no Gemini: names on the cluster", pick(ek, "entities", "correspondence-typed"),
           "qwen3.6-27b")
        check("E with an OpenRouter key: the cluster costs no money", ek.pick("entities", "correspondence-typed")?.usd == 0,
              "\(ek.pick("entities", "correspondence-typed")?.usd ?? -1)")
        skip("E placement's hand line detector setting", "a rule stage: the sheet's rules tab (W46.settings-sheet)")
        var cl1 = cl
        cl1.gpusPerJob = 1
        check("E one GPU a job: Infinity-Parser2-Pro is hollow, needs 2 GPUs",
              solve("E-1gpu", cl1, ea).blockers("reading", "infinity-parser2-pro-sherlock").contains("needs 2 GPUs a job"))

        // F. The fine-tuning answer.
        var krakenOnly = SettingsAnswers()
        krakenOnly.onlyRoutes["reading"] = ["apple-vision", "ppocrv6-kraken-blla"]
        krakenOnly.fineTuning = .codingAgent
        krakenOnly.correctedLinesOneHand = 100
        let fk = solve("F-kraken", mac(16), krakenOnly)
        eq("F hands on kraken (a restricted table)", pick(fk, "reading", "handwritten"), "ppocrv6-kraken-blla")
        check("F coding agent: the hand fine-tune shown past 80 lines",
              fk.afterTraining.first { $0.id == "kit-hands-ppocrv6-ft" }?.shown == true)
        krakenOnly.correctedLinesOneHand = 50
        check("F coding agent: hidden below 80 lines", solve("F-kraken-50", mac(16), krakenOnly)
              .afterTraining.first { $0.id == "kit-hands-ppocrv6-ft" }?.shown == false)
        var agent = SettingsAnswers()
        agent.fineTuning = .codingAgent
        agent.correctedLinesOneHand = 200
        let fa = solve("F-agent", mac(16), agent)
        check("F coding agent: no hand fine-tune where the reader is not kraken",
              fa.afterTraining.first { $0.id == "kit-hands-ppocrv6-ft" }?.shown == false)
        let lora = fa.afterTraining.first { $0.id == "kit-seg-lora-mac" }
        check("F coding agent: the Mac LoRA shown as not offered", lora?.shown == true && lora?.selectable == false
              && lora?.reason.contains("not measured to fit") == true)
        check("F coding agent: no cluster rows", !fa.afterTraining.contains { $0.id == "seg-2b-lora-k200" })
        var onCluster = ea
        onCluster.fineTuning = .cluster
        let fc0 = solve("F-cluster", cl, onCluster)
        check("F on a cluster: the student hidden without tags",
              fc0.afterTraining.first { $0.id == "kit-seg-student-tags" }?.shown == false)
        check("F on a cluster: the continuation hidden under 200 gaps",
              fc0.afterTraining.first { $0.id == "seg-2b-lora-k200" }?.shown == false)
        onCluster.collectionHasTagsOrFolders = true
        onCluster.correctedGapsOneMaterial = 200
        let fc = solve("F-cluster-ready", cl, onCluster)
        for id in ["kit-seg-student-tags", "seg-2b-lora-k200"] {
            let p = fc.afterTraining.first { $0.id == id }
            check("F on a cluster: \(id) shown, not selectable before the Mac build", p?.shown == true
                  && p?.selectable == false && p?.reason == "needs the Mac build step", p?.reason ?? "missing")
        }
        onCluster.kitMacBuild = true
        check("F on a cluster: selectable past the gate", solve("F-cluster-built", cl, onCluster)
              .afterTraining.filter { ["kit-seg-student-tags", "seg-2b-lora-k200"].contains($0.id) }
              .allSatisfy(\.selectable))

        // G4. Hours nothing meets: 10,000 pages on a 16 GB Mac in one hour.
        var rush = SettingsAnswers()
        rush.pages = 10_000
        rush.hours = 1
        let g4 = solve("G4", mac(16), rush)
        check("G4 every stage has a pick", ["reading/all", "segmentation/all", "dating/step 1", "entities/correspondence-typed"]
              .allSatisfy { k in g4.picks.contains { "\($0.stage)/\($0.part)" == k } })
        eq("G4 segmentation falls to manual", pick(g4, "segmentation"), "manual")
        check("G4 says to relax the hours, and by how much", g4.relax.contains { $0.contains("more hours") },
              g4.relax.joined(separator: " | "))
        check("G4 the 2B's card names the hours",
              g4.pick("segmentation", "all")?.better.first { $0.id == "seg-qwen3.5-2b-8bit" }?.isLimit == true)

        // G5. A tie chain: judged against the best usable route only, never chained.
        var chain = SettingsAnswers()
        chain.onlyRoutes["reading"] = ["qwen3.5-397b", "qwen3-vl-235b", "qwen3.5-9b"]
        var orOnly = SettingsResources(macMemoryGB: 16)
        orOnly.keys = ["openrouter"]
        eq("G5 the tie chain picks Qwen3-VL 235B, never Qwen3.5 9B", pick(solve("G5", orOnly, chain), "reading"),
           "qwen3-vl-235b")

        // Every pick explains itself in one sentence naming its evidence row.
        var unexplained: [String] = []
        for (name, s) in solved {
            for p in s.picks {
                let named = p.route.map { p.reason.contains("(\($0.id))") } ?? !p.reason.isEmpty
                let cites = p.gap.map { p.reason.contains($0.citation) } ?? true
                if !named || !cites || p.reason.isEmpty { unexplained.append("\(name) \(p.stage)/\(p.part): \(p.reason)") }
            }
        }
        check("H every pick names its evidence row", unexplained.isEmpty, unexplained.prefix(5).joined(separator: " | "))
        lines.append("--- the reasons, B1, C, D2 and E")
        for (name, s) in solved where ["B1", "C", "D2", "E"].contains(name) {
            for p in s.picks { lines.append("  \(name) \(p.stage)/\(p.part): \(p.reason)") }
        }
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["SETTINGS_SOLVER_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}

#endif
