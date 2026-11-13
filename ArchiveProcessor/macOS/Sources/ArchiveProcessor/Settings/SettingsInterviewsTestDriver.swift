#if DEBUG // a test driver, compiled out of Release
import Foundation

/// Headless, $0 self-test of the two interviews (W46.settings-interviews), gated by `SETTINGS_INTERVIEWS_TEST=1` (does
/// nothing in normal use). The Mac's keys come from a fake probe, the kind classifier's answers are given, and every
/// file it writes is under a fresh scratch folder in `SETTINGS_INTERVIEWS_TEST_DIR`: never the app's own store, never an
/// output folder of the user's, never the corpus. No Keychain read, no network, no window. Run by
/// `scripts/test-settings-interviews.sh`.
@MainActor
enum SettingsInterviewsTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SETTINGS_INTERVIEWS_TEST"] == "1" else { return }
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

    private static func near(_ name: String, _ got: Double?, _ want: Double) {
        check(name, got.map { abs($0 - want) < 0.001 } ?? false, "got \(String(describing: got)) want \(want)")
    }

    private static let fm = FileManager.default
    private static let day = Date(timeIntervalSince1970: 1_793_793_600)

    private static func run() {
        let base = ProcessInfo.processInfo.environment["SETTINGS_INTERVIEWS_TEST_DIR"].map(URL.init(fileURLWithPath:))
            ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("settings-interviews-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        inventory()
        skipped()
        general()
        startingPoints()
        measurement(root)
        mixAndStrata()
        collection()
        inheritance()
        weights()
        stores(root)
        plainWords()
        finish()
    }

    // MARK: General interview

    private static func fakeMac(_ accounts: Set<String>, claude: String? = nil) -> MacInventory {
        MacInventory.read(exists: { accounts.contains($0) }, claudePath: claude, memoryGB: 16, chip: "Apple M4")
    }

    private static func inventory() {
        let m = fakeMac(["Gemini", "Gateway", "ChatGPTPlanCredentials"], claude: "/opt/homebrew/bin/claude")
        eq("keys found are named as the route table names them, in order", m.keys, ["gemini", "gateway"])
        eq("a ChatGPT sign-in is a plan; an unchecked Claude tool is not", m.plans, ["chatgpt"])
        var signed = m
        signed.claudeSignedIn = true
        eq("Claude is a plan once the check finds it signed in", signed.plans, ["claude", "chatgpt"])
        signed.claudeSignedIn = false
        eq("a Claude tool that is not signed in is never a plan", signed.plans, ["chatgpt"])
        var noTool = fakeMac([])
        noTool.claudeSignedIn = true
        eq("no Claude tool, no Claude plan", noTool.plans, [])
        check("the ChatGPT account is the store's own", MacInventory.chatGPTAccount == KeychainChatGPTCredentialStore.account)
        check("the general interview's Keychain check never reads in a headless run",
              !KeychainHelper.exists(account: LLMProvider.gemini.rawValue))
    }

    private static func skipped() {
        var layer = SettingsLayer(kind: .general, name: "General")
        GeneralInterviewAnswers.applyFound(fakeMac(["Gemini", "OpenRouter"]), to: &layer, now: day)
        eq("a skipped interview writes only what was found", Set(layer.entries.keys), ["keys", "plans"])
        eq("found keys carry the source 'found on this Mac'", layer.entry(.keys)?.source, .detected(day))
        let r = SettingsResolver(general: layer)
        eq("skipped: the keys are listed for the sheet", r.resources(macMemoryGB: 16).keys, ["gemini", "openrouter"])
        let a = r.answers(pages: 100)
        eq("skipped: nothing is spent", a.ceilingUSD, 0)
        check("skipped: no page leaves this Mac", a.staysOnMac)
        eq("skipped: names are not ranked", a.priorities, [.reading, .findingDocuments, .dates])
        if let table = try? SettingsRouteTable.loadBundled() {
            let s = SettingsSolver(table: table, pairs: OCRPairMatrix.bundled, resources: r.resources(macMemoryGB: 16),
                                   answers: a).solve()
            eq("skipped: the solver spends nothing with keys present", s.usd, 0)
            check("skipped: every pick is on this Mac or by hand",
                  s.picks.allSatisfy { $0.route.map { $0.family == .mac || $0.family == .manual } ?? true },
                  s.picks.compactMap { $0.route.map { "\($0.id) \($0.family)" } }.joined(separator: ", "))
        } else {
            check("the bundled route table decodes", false)
        }
    }

    private static func general() {
        var layer = SettingsLayer(kind: .general, name: "General")
        GeneralInterviewAnswers().apply(to: &layer, inventory: fakeMac([]), now: day)
        let r = SettingsResolver(general: layer)
        eq("default answers: nothing is spent", r.ceilingUSD(), 0)
        eq("default answers: no cluster", r.resources(macMemoryGB: 16).cluster, false)
        check("default answers write no ceiling and no graphics cards",
              layer.entry(.batchCeilingUSD) == nil && layer.entry(.monthCeilingUSD) == nil && layer.entry(.gpusPerJob) == nil)
        eq("default answers: overnight", r.answers(pages: 10).hours, 8)
        eq("default answers: no training", r.resolve(.fineTuning).value, .string(FineTuningAnswer.no.rawValue))
        eq("answers are the user's", layer.entry(.hours)?.source, .setByUser(day))

        var a = GeneralInterviewAnswers()
        a.setMoneyHabit(.perBatch)
        check("choosing to spend lets pages leave the Mac", !a.staysOnMac)
        a.setMoneyHabit(.none)
        check("choosing to spend nothing again keeps them here", a.staysOnMac)
        a.setMoneyHabit(.perBatch)
        a.batchCeilingUSD = 5
        a.cluster = true
        a.gpusPerJob = 2
        a.apply(to: &layer, inventory: fakeMac([]), now: day)
        let rb = SettingsResolver(general: layer)
        eq("per batch: the batch ceiling", rb.ceilingUSD(), 5)
        eq("a cluster and its graphics cards", rb.resources(macMemoryGB: 16).gpusPerJob, 2)
        check("pages may leave the Mac when answered so", !rb.answers(pages: 10).staysOnMac)

        a.moneyHabit = .perMonth
        a.monthCeilingUSD = 20
        a.apply(to: &layer, inventory: fakeMac([]), now: day)
        let rm = SettingsResolver(general: layer)
        check("per month: the batch ceiling answered before is removed", layer.entry(.batchCeilingUSD) == nil)
        eq("per month: what is left of the month", rm.ceilingUSD(spentThisMonthUSD: 12), 8)

        a.moneyHabit = .noCeiling
        a.apply(to: &layer, inventory: fakeMac([]), now: day)
        let rn = SettingsResolver(general: layer)
        check("no ceiling resolves to none", rn.answers(pages: 10).ceilingUSD == nil)
        check("no ceiling writes no ceiling value", layer.entry(.batchCeilingUSD) == nil && layer.entry(.monthCeilingUSD) == nil)

        let back = GeneralInterviewAnswers(from: layer)
        check("running the interview again starts from the last answers",
              back.moneyHabit == .noCeiling && back.cluster && back.gpusPerJob == 2 && !back.staysOnMac)
        check("a first run has not chosen whether pages leave", !GeneralInterviewAnswers().staysOnMacChosen)
        eq("a switch the spending answer set says so", layer.entry(.staysOnMac)?.source, .follows("Spending", day))
        check("…and still follows it on the next run", !back.staysOnMacChosen)
        var later = back
        later.setMoneyHabit(.none)
        check("so spending nothing on a later run keeps pages on the Mac again", later.staysOnMac)
        var chosen = back
        chosen.staysOnMac = false
        chosen.staysOnMacChosen = true
        var cl = layer
        chosen.apply(to: &cl, inventory: fakeMac([]), now: day)
        let second = GeneralInterviewAnswers(from: cl)
        check("a switch the user set is theirs on the next run", second.staysOnMacChosen)
        var kept = second
        kept.setMoneyHabit(.none)
        check("…and the spending answer does not move it", !kept.staysOnMac)
        var noLimit = layer
        noLimit.set(.batchCeilingUSD, .double(9), source: .setByUser(day))
        check("under no limit a leftover general batch ceiling does not cap it", SettingsResolver(general: noLimit).ceilingUSD().isInfinite)

        let coll = SettingsLayer(kind: .collection, name: "c", entries: [
            SettingsKey.batchCeilingUSD.rawValue: SettingsEntry(value: .double(2), source: .setByUser(day))])
        eq("under no limit, a collection's own ceiling holds", SettingsResolver(general: layer, collection: coll).ceilingUSD(), 2)

        check("the general layer now holds answers", GeneralInterviewAnswers.hasAnswers(layer))
        layer.set(.excludedModelFamilies, .strings(["gemini"]), source: .setByUser(day))
        GeneralInterviewAnswers.skip(fakeMac(["Gemini"]), layer: &layer, now: day)
        eq("skipping after answering clears the interview's earlier answers", Set(layer.entries.keys),
           ["keys", "plans", "excludedModelFamilies"])
        check("…and nothing it does not ask", layer.entry(.excludedModelFamilies) != nil)
        let rs = SettingsResolver(general: layer)
        check("…so it is free again: nothing spent, no page leaves",
              rs.ceilingUSD() == 0 && rs.answers(pages: 10).staysOnMac && rs.resources(macMemoryGB: 16).cluster == false)
    }

    private static func startingPoints() {
        var a = GeneralInterviewAnswers()
        a.fill(.fewDollars)
        check("“A few dollars, overnight” fills $5 a batch, the cheaper choice, pages may leave",
              a.moneyHabit == .perBatch && a.batchCeilingUSD == 5 && a.preference == .cheapestWithinPoint && !a.staysOnMac
              && a.hours == 30)
        a.touch(.hours)
        a.hours = 12
        var layer = SettingsLayer(kind: .general, name: "General")
        a.apply(to: &layer, inventory: fakeMac([]), now: day)
        eq("a filled answer says it was filled", layer.entry(.batchCeilingUSD)?.source,
           .startingPoint("A few dollars, overnight", day))
        eq("a filled answer the user changed is theirs", layer.entry(.hours)?.source, .setByUser(day))

        var f = GeneralInterviewAnswers()
        f.fill(.free)
        check("“Free, on this Mac” spends nothing and keeps pages here", f.moneyHabit == .none && f.staysOnMac)
        f.fill(.best)
        check("“Best measured, no limit” has no ceiling", f.moneyHabit == .noCeiling && f.preference == .bestMeasured)
        f.fill(.plan)
        check("“My Claude plan, no money” spends nothing but may use the plan", f.moneyHabit == .none && !f.staysOnMac)

        var c = CollectionInterviewAnswers()
        c.fill(.fewDollars)
        eq("a collection's fill sets its own ceiling", c.batchCeilingUSD, 5)
        var best = CollectionInterviewAnswers()
        best.batchCeilingUSD = 50
        best.fill(.best)
        var bl = SettingsLayer(kind: .collection, name: "c")
        best.apply(to: &bl, now: day)
        check("a fill that does not spend leaves the inherited ceiling alone", bl.entry(.batchCeilingUSD) == nil)
        check("a collection's fill never lets pages leave by itself", bl.entry(.staysOnMac) == nil)
        var free = CollectionInterviewAnswers()
        free.staysOnMac = false
        free.fill(.free)
        var fl = SettingsLayer(kind: .collection, name: "c")
        free.apply(to: &fl, now: day)
        eq("…but “Free, on this Mac” keeps them here", fl.entry(.staysOnMac)?.value, .bool(true))
        eq("…and fills what it means", bl.entry(.hours)?.source, .startingPoint("Best measured, no limit", day))
        check("a collection's money fill under 'spend nothing' says it has no effect",
              CollectionInterviewAnswers.moneyNote(point: .fewDollars, habit: .none) != nil)
        check("a collection's money fill under a per-batch habit needs no note",
              CollectionInterviewAnswers.moneyNote(point: .fewDollars, habit: .perBatch) == nil)
        check("“no limit” from a collection says it is a general setting",
              CollectionInterviewAnswers.moneyNote(point: .best, habit: .perBatch) != nil)
        check("a free fill needs no note", CollectionInterviewAnswers.moneyNote(point: .free, habit: .none) == nil)
    }

    // MARK: Collection interview

    private static func measurement(_ root: URL) {
        let kinds: [PageKind?] = [
            PageKind(kind: .typewritten, confidence: 0.95), PageKind(kind: .typewritten, confidence: 0.6),
            PageKind(kind: .handwritten, confidence: 0.9), nil,
            PageKind(kind: .printed, confidence: 0.85),
        ]
        let m = KindMeasurement.tally(kinds, date: day)
        eq("the sample counts every photograph given", m.sample, 5)
        eq("pages under the 0.8 floor are counted as unsure", m.unsure, 1)
        eq("a page it could not tell is unknown", m.unknown, 1)
        near("shares are over the pages it could tell", m.shares["typewritten"], 50)
        near("shares add to 100", m.shares.values.reduce(0, +), 100)

        let names = (1...100).map { "IMG_\($0).jpg" } + ["notes.txt", "scan.pdf"]
        let urls = names.map { root.appendingPathComponent($0) }
        let s = KindMeasurement.sample(urls, limit: 10)
        eq("the sample is capped", s.count, 10)
        eq("the sample starts at the first photograph in name order", s.first?.lastPathComponent, "IMG_1.jpg")
        eq("the sample is spread through the batch", s.last?.lastPathComponent, "IMG_91.jpg")
        check("only photographs are sampled", s.allSatisfy { $0.pathExtension == "jpg" })
        eq("a small batch is sampled whole", KindMeasurement.sample(Array(urls.prefix(3)), limit: 10).count, 3)

        let folder = root.appendingPathComponent("box", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in ["a.jpg", "b.png", ".hidden.jpg"] { fm.createFile(atPath: folder.appendingPathComponent(n).path, contents: Data()) }
        eq("a chosen folder gives its own photographs", Set(CollectionInterviewView.imageFiles(in: [folder]).map(\.lastPathComponent)),
           ["a.jpg", "b.png"])
    }

    private static func base() -> CollectionInterviewAnswers {
        var a = CollectionInterviewAnswers()
        a.measuredShares = ["typewritten": 50, "printed": 25, "handwritten": 25]
        a.touch(.mix)
        return a
    }

    /// Save, answer again from the saved layer, and save unchanged: the same layer.
    private static func roundTrip(_ a: CollectionInterviewAnswers) -> (SettingsLayer, SettingsLayer) {
        var first = SettingsLayer(kind: .collection, name: "c")
        a.apply(to: &first, now: day)
        let g = SettingsLayer(kind: .general, name: "G")
        let again = CollectionInterviewAnswers(resolver: SettingsResolver(general: g, collection: first), own: first)
        var second = first
        again.apply(to: &second, now: day)
        return (first, second)
    }

    private static func sameNumbers(_ a: SettingsValue?, _ b: SettingsValue?) -> Bool {
        guard let x = a?.numbers, let y = b?.numbers, Set(x.keys) == Set(y.keys) else { return a == nil && b == nil }
        return x.allSatisfy { abs($0.value - (y[$0.key] ?? .nan)) < 0.0001 }
    }

    private static func mixAndStrata() {
        let plain = base().mixAndStrata()
        eq("a measured mix alone is the mix", plain.mix, ["typewritten": 50, "printed": 25, "handwritten": 25])
        check("an English 20th-century collection is judged on the owner's pages", plain.strata.isEmpty)

        var u = base()
        u.unmeasuredShares = ["newspapers": 10, "registers": 5]
        let um = u.mixAndStrata()
        near("measured kinds share what the unmeasured leave", um.mix["typewritten"], 42.5)
        near("newspapers are their own kind", um.mix["newspapers"], 10)
        near("registers keep their name in the document", um.mix["registers"], 5)
        near("the mix still adds to 100", um.mix.values.reduce(0, +), 100)
        var ul = SettingsLayer(kind: .collection, name: "c")
        u.apply(to: &ul, now: day)
        near("…and the solver reads registers as forms and tables",
             SettingsResolver(general: SettingsLayer(kind: .general, name: "G"), collection: ul).answers(pages: 10).mix["forms"], 5)

        var n = base()
        n.scriptShares = [.arabic: 20]
        let nm = n.mixAndStrata()
        near("Arabic pages go to the Arabic test set", nm.strata["N1"], 20)
        near("the rest shrink to make room", nm.mix["typewritten"], 40)
        near("mix and strata add to 100", nm.mix.values.reduce(0, +) + nm.strata.values.reduce(0, +), 100)

        var d = base()
        d.languages = ["nl"]
        d.periodFrom = 1620
        d.periodTo = 1780
        let dm = d.mixAndStrata()
        near("Dutch hands of 1620-1780 are judged on L5", dm.strata["L5"], 25)
        check("and are no longer read as the owner's handwriting", dm.mix["handwritten"] == nil)
        check("print of 1620-1780 is not early print", dm.strata["L8"] == nil)

        var g = base()
        g.languages = ["de"]
        g.periodFrom = 1820
        g.periodTo = 1880
        near("German hands of the 19th century are judged on L6", g.mixAndStrata().strata["L6"], 25)
        var k = base()
        k.latinForms = [.kurrent]
        near("Kurrent is judged on L6 whatever the period", k.mixAndStrata().strata["L6"], 25)
        var e = base()
        e.periodFrom = 1400
        e.periodTo = 1550
        let em = e.mixAndStrata()
        near("hands before 1600 are judged on the charters", em.strata["L7"], 25)
        near("print before 1700 is judged on L8", em.strata["L8"], 25)
        var f = base()
        f.latinForms = [.fraktur]
        f.periodFrom = 1900
        f.periodTo = 1940
        near("Fraktur print is judged on L8", f.mixAndStrata().strata["L8"], 25)
        var two = base()
        two.languages = ["es", "de"]
        two.periodFrom = 1650
        two.periodTo = 1750
        let tm = two.mixAndStrata()
        near("hands that fit two sets are split between them", tm.strata["L5"], 12.5)
        near("…evenly", tm.strata["L6"], 12.5)
        check("nothing measured and nothing given is no mix", CollectionInterviewAnswers().mixAndStrata().mix.isEmpty)
        let onlyGiven: CollectionInterviewAnswers = {
            var x = CollectionInterviewAnswers()
            x.unmeasuredShares = ["clippings": 100]
            return x
        }()
        eq("a mix of only unmeasured kinds is as given", onlyGiven.mixAndStrata().mix, ["clippings": 100])
    }

    private static func collection() {
        var a = base()
        a.measurement = KindMeasurement(sample: 40, counts: ["typewritten": 20, "printed": 10, "handwritten": 10],
                                        unsure: 2, unknown: 0, date: day)
        a.languages = ["en"]
        a.periodFrom = 1950
        a.periodTo = 1980
        a.batchCeilingUSD = 3
        a.hours = 12
        a.checkingMinutes = 20
        a.staysOnMac = false
        for key in [SettingsKey.languages, .period, .batchCeilingUSD, .hours, .checkingMinutes, .staysOnMac] { a.touch(key) }
        var layer = SettingsLayer(kind: .collection, name: "Box 1")
        a.apply(to: &layer, now: day)
        eq("an uncorrected mix is 'measured from 40 photos'", layer.entry(.mix)?.source, .measured(day, sample: 40))
        eq("the period is kept as a span", layer.entry(.period)?.value, .string("1950-1980"))
        eq("the languages are kept", layer.entry(.languages)?.value, .strings(["en"]))
        eq("the scripts go with the mix, empty when none", layer.entry(.scripts)?.value, .strings([]))
        check("a collection never holds a general-only value", layer.entry(.keys) == nil && layer.entry(.moneyHabit) == nil)
        let r = SettingsResolver(general: SettingsLayer(kind: .general, name: "General"), collection: layer)
        let ans = r.answers(pages: 200)
        eq("the solver reads the collection's mix", ans.mix, ["typewritten": 50, "printed": 25, "handwritten": 25])
        eq("and its checking minutes", ans.checkingMinutes, 20)
        check("and its switch to let pages leave", !ans.staysOnMac)
        eq("its ceiling still waits on the general spending habit", ans.ceilingUSD, 0)

        a.correctedMix = true
        a.apply(to: &layer, now: day)
        eq("a corrected mix is the user's", layer.entry(.mix)?.source, .setByUser(day))

        var s = base()
        s.scriptShares = [.greek: 10]
        s.latinForms = [.fraktur]
        s.touch(.scripts)
        s.apply(to: &layer, now: day)
        eq("scripts are kept with their shares", layer.entry(.scripts)?.value, .strings(["fraktur", "greek:10"]))
        check("strata are written beside the mix", layer.entry(.strata)?.value.numbers?["N3"] != nil)
        let back = CollectionInterviewAnswers(resolver: SettingsResolver(general: SettingsLayer(kind: .general, name: "G"),
                                                                         collection: layer))
        check("answering again starts from the collection's answers",
              back.scriptShares[.greek] == 10 && back.latinForms == [.fraktur] && back.measuredShares["typewritten"] != nil)

        var p = SettingsLayer(kind: .project, name: "Letters")
        var pa = base()
        pa.touch(.priorities)
        pa.apply(to: &p, now: day)
        check("a project holds the same answers", p.entry(.mix) != nil && p.entry(.priorities) != nil && p.entry(.weights) != nil)
    }

    /// The interview writes only what it answered; everything else stays inherited live (owner, 2026-11-04).
    private static func inheritance() {
        let general = SettingsLayer(kind: .general, name: "G", entries: [
            SettingsKey.staysOnMac.rawValue: SettingsEntry(value: .bool(false), source: .setByUser(day)),
            SettingsKey.batchCeilingUSD.rawValue: SettingsEntry(value: .double(20), source: .setByUser(day))])
        let shown = CollectionInterviewAnswers(resolver: SettingsResolver(general: general), own: nil)
        check("the interview shows the inherited values", !shown.staysOnMac && shown.batchCeilingUSD == 20)
        var layer = SettingsLayer(kind: .collection, name: "c")
        shown.apply(to: &layer, now: day)
        check("saving an untouched interview copies nothing down", layer.entries.isEmpty, "\(layer.entries.keys.sorted())")
        var lowered = general
        lowered.set(.batchCeilingUSD, .double(2), source: .setByUser(day))
        lowered.set(.moneyHabit, .string(MoneyHabit.perBatch.rawValue), source: .setByUser(day))
        eq("…so a general change reaches the collection", SettingsResolver(general: lowered, collection: layer).ceilingUSD(), 2)

        var touched = shown
        touched.staysOnMac = true
        touched.touch(.staysOnMac)
        var t = SettingsLayer(kind: .collection, name: "c")
        touched.apply(to: &t, now: day)
        eq("a touched value is the collection's own", Set(t.entries.keys), ["staysOnMac"])
        let again = CollectionInterviewAnswers(resolver: SettingsResolver(general: general, collection: t), own: t)
        check("answering again keeps a value the collection held", again.isAnswered(.staysOnMac))
        var reset = t
        again.apply(to: &reset, now: day)
        eq("…and still writes only it", Set(reset.entries.keys), ["staysOnMac"])

        var german = base()
        german.languages = ["de"]
        german.periodFrom = 1700
        german.periodTo = 1800
        german.touch(.languages); german.touch(.period)
        let (g1, g2) = roundTrip(german)
        check("German hands saved to L6 come back as handwriting", sameNumbers(g1.entry(.strata)?.value, g2.entry(.strata)?.value)
              && sameNumbers(g1.entry(.mix)?.value, g2.entry(.mix)?.value), "\(String(describing: g2.entry(.mix)?.value)) \(String(describing: g2.entry(.strata)?.value))")
        var arabic = base()
        arabic.unmeasuredShares = ["clippings": 20, "registers": 10]
        arabic.scriptShares = [.arabic: 50]
        arabic.touch(.scripts)
        let (a1, a2) = roundTrip(arabic)
        check("unmeasured kinds beside a non-Latin share do not shrink on each save",
              sameNumbers(a1.entry(.mix)?.value, a2.entry(.mix)?.value) && sameNumbers(a1.entry(.strata)?.value, a2.entry(.strata)?.value),
              "\(String(describing: a1.entry(.mix)?.value)) → \(String(describing: a2.entry(.mix)?.value))")
        var print = base()
        print.periodFrom = 1550
        print.periodTo = 1650
        print.touch(.period)
        let (p1, p2) = roundTrip(print)
        check("early print saved to L8 comes back as print", sameNumbers(p1.entry(.mix)?.value, p2.entry(.mix)?.value)
              && sameNumbers(p1.entry(.strata)?.value, p2.entry(.strata)?.value))
        // The mix group lives in one layer.
        let g = SettingsLayer(kind: .general, name: "G")
        var project = SettingsLayer(kind: .project, name: "Letters")
        var pg = base()
        pg.languages = ["de"]; pg.periodFrom = 1800; pg.periodTo = 1850
        pg.scriptShares = [.arabic: 50]
        pg.touch(.languages); pg.touch(.scripts)
        pg.apply(to: &project, now: day)
        var own = CollectionInterviewAnswers(resolver: SettingsResolver(general: g, project: project), own: nil)
        check("a project's mix shows as inherited", own.mixInheritedFrom == "the project “Letters”" && !own.correctedMix)
        own.take(KindMeasurement.tally([PageKind(kind: .typewritten, confidence: 0.9)], date: day))
        own.languages = []; own.scriptShares = [:]; own.periodFrom = nil; own.periodTo = nil
        var cl2 = SettingsLayer(kind: .collection, name: "c")
        own.apply(to: &cl2, now: day)
        let rr = SettingsResolver(general: g, project: project, collection: cl2)
        check("a collection's own mix never sits beside the project's public sets", rr.answers(pages: 10).strata.isEmpty)
        eq("emptied answers override the project's", rr.resolve(.scripts).value, .strings([]))
        let again2 = CollectionInterviewAnswers(resolver: rr, own: cl2)
        check("…and read back empty, not the project's", again2.scriptShares.isEmpty && again2.languages.isEmpty
              && again2.measuredShares == ["typewritten": 100])
        var lang = CollectionInterviewAnswers(resolver: SettingsResolver(general: g), own: nil)
        lang.languages = ["fr"]; lang.touch(.languages)
        var ll = SettingsLayer(kind: .collection, name: "c")
        lang.apply(to: &ll, now: day)
        check("a language alone does not write an empty mix", ll.entry(.mix) == nil && ll.entry(.languages) != nil)
        eq("…so the built-in mix still applies", SettingsResolver(general: g, collection: ll).answers(pages: 10).mix,
           SettingsAnswers().mix)

        var over = CollectionInterviewAnswers()
        over.measuredShares = ["typewritten": 100]
        over.unmeasuredShares = ["clippings": 70, "newspapers": 50]
        let om = over.mixAndStrata().mix
        near("unmeasured kinds over 100% are read as shares of the whole", om["clippings"].map { $0 + (om["newspapers"] ?? 0) }, 100)
        over.touch(.mix)
        let (o1, o2) = roundTrip(over)
        check("…and survive answering again", sameNumbers(o1.entry(.mix)?.value, o2.entry(.mix)?.value))

        let measured: CollectionInterviewAnswers = {
            var m = CollectionInterviewAnswers()
            m.take(KindMeasurement(sample: 12, counts: ["typewritten": 12], unsure: 0, unknown: 0, date: day))
            return m
        }()
        let (m1, m2) = roundTrip(measured)
        eq("a measured mix stays measured when saved again unchanged", m2.entry(.mix)?.source, m1.entry(.mix)?.source)
    }

    private static func weights() {
        var a = CollectionInterviewAnswers()
        eq("the default order ranks names last, unranked", a.weights[.names], 0)
        a.move(.names, by: -1)
        eq("moving names up gives it the third weight", a.weights[.names], 15)
        eq("and the one it passed drops out", a.weights[.dates], 0)
        a.move(.names, by: -1)
        a.weights[.reading] = 60
        a.touch(.priorities)
        var layer = SettingsLayer(kind: .collection, name: "c")
        a.apply(to: &layer, now: day)
        eq("ranked priorities are written by weight", layer.entry(.priorities)?.value,
           .strings(["reading", "names", "findingDocuments"]))
        let ans = SettingsResolver(general: SettingsLayer(kind: .general, name: "G"), collection: layer).answers(pages: 10)
        eq("the solver reads the weights by stage", ans.weights, ["reading": 60, "entities": 30, "segmentation": 15])
        check("names now count", ans.priorities.contains(.names))
        if let table = try? SettingsRouteTable.loadBundled() {
            let solver = SettingsSolver(table: table, pairs: nil, resources: SettingsResources(macMemoryGB: 16), answers: ans)
            eq("a typed weight is the stage's weight", solver.weight("reading"), 60)
            eq("an unranked stage weighs nothing", solver.weight("dating"), 0)
            var positional = ans
            positional.weights = [:]
            let p = SettingsSolver(table: table, pairs: nil, resources: SettingsResources(macMemoryGB: 16), answers: positional)
            eq("with no weights the order gives 45, 30, 15", [p.weight("reading"), p.weight("entities"), p.weight("segmentation")],
               [45, 30, 15])
        }
        let back = CollectionInterviewAnswers(resolver: SettingsResolver(general: SettingsLayer(kind: .general, name: "G"),
                                                                         collection: layer))
        eq("the order reads back", back.order.prefix(3).map(\.self), [.reading, .names, .findingDocuments])
        eq("the weights read back", back.weights[.reading], 60)

        var split = SettingsLayer(kind: .collection, name: "c")
        split.set(.weights, .numbers(["reading": 5, "dates": 90]), source: .setByUser(day))
        let project = SettingsLayer(kind: .project, name: "P", entries: [
            SettingsKey.priorities.rawValue: SettingsEntry(value: .strings(["dates", "reading"]), source: .setByUser(day))])
        let sa = SettingsResolver(general: SettingsLayer(kind: .general, name: "G"), project: project, collection: split)
            .answers(pages: 10)
        check("weights from another layer than the order are not used", sa.weights.isEmpty)
    }

    private static func stores(_ root: URL) {
        let store = SettingsLayerStore(directory: root.appendingPathComponent("store", isDirectory: true))
        var g = store.general
        var answers = GeneralInterviewAnswers()
        answers.moneyHabit = .perBatch
        answers.batchCeilingUSD = 4
        answers.apply(to: &g, inventory: fakeMac(["Mistral"]), now: day)
        check("the general interview's answers are saved", store.replaceGeneral(g))
        let reopened = SettingsLayerStore(directory: store.directory)
        eq("…and read back by the next launch", SettingsResolver(general: reopened.general).ceilingUSD(), 4)
        eq("…with the keys found", reopened.general.entry(.keys)?.value, .strings(["mistral"]))
        check("a layer of another kind is never put in the general place",
              !store.replaceGeneral(SettingsLayer(kind: .collection, name: "x")))

        let output = root.appendingPathComponent("output", isDirectory: true)
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        let written = store.updateCollection(in: output) { base().apply(to: &$0.collection, now: day) }
        check("the collection interview writes the collection's document", written?.collection.entry(.mix) != nil)
        if case .document(let d) = CollectionSettingsFile.read(in: output) {
            eq("…which reads back from the output folder", d.collection.entry(.mix)?.value.numbers?["printed"], 25)
        } else {
            check("the collection's document reads back", false)
        }
        if let project = store.addProject(named: "Letters") {
            check("the interview answers for a project", store.updateProject(project.id) { base().apply(to: &$0, now: day) })
            check("…in the general store", store.project(project.id)?.entry(.mix) != nil)
        } else {
            check("a project can be made", false)
        }
    }

    /// The settings-plain rule: no term a non-technical user cannot explain from the screen. The interview's own
    /// words are checked for the bench's and the trade's jargon.
    private static func plainWords() {
        let banned = ["NES", "VLM", "LLM", "OCR", "API", "stratum", "strata", "token", "inference", "LoRA", "GPU",
                      "Slurm", "fine-tun", "L1", "L5", "N1", "classifier", "MLX"]
        var words: [String] = []
        words += SettingsStartingPoint.allCases.flatMap { [$0.name, $0.summary] }
        words += CollectionScript.allCases.map(\.label)
        words += CollectionInterviewAnswers.unmeasuredKinds.map(CollectionInterviewAnswers.unmeasuredLabel)
        words += SettingsPriority.allCases.map(CollectionInterviewAnswers.priorityLabel)
        words += ["L4", "L5", "L6", "L7", "L8", "L9", "N1", "N2", "N3", "N4", "N5", "N6"].map(PublicStratum.label)
        words += [SettingsKey.weights.label, SettingsKey.moneyHabit.describe(.string(MoneyHabit.noCeiling.rawValue))]
        words += MacInventory.keyAccounts.map(\.label)
        words += [SettingsKey.weights.describe(.numbers(["reading": 45, "findingDocuments": 30])),
                  SettingsKey.strata.describe(.numbers(["L6": 25])),
                  SettingsKey.languages.describe(.strings(["de", "nl"])),
                  SettingsKey.scripts.describe(.strings(["kurrent", "arabic:30"])),
                  SettingsKey.mix.describe(.numbers(["typewritten": 60, "registers": 5]))]
        eq("weights read as words", SettingsKey.weights.describe(.numbers(["reading": 45, "findingDocuments": 30])),
           "reading 45, finding documents 30")
        eq("scripts read as words", SettingsKey.scripts.describe(.strings(["arabic:30"])), "Arabic 30%")
        let hits = words.filter { w in
            banned.contains { w.range(of: "\\b\($0)", options: [.regularExpression, .caseInsensitive]) != nil }
        }
        check("the interviews' words carry no jargon", hits.isEmpty, hits.joined(separator: " | "))
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let report = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["SETTINGS_INTERVIEWS_TEST_OUT"] {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(report)
        }
    }
}
#endif
