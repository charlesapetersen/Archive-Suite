#if DEBUG // a test driver, compiled out of Release
import AppKit
import SwiftUI

/// Headless, $0 self-test of the settings sheet (W46.settings-sheet), gated by `SETTINGS_SHEET_TEST=1` (does nothing in
/// normal use). No model call, no network, no Keychain read (the layers are built here), no window: the sheet's pages
/// are drawn offscreen with `ImageRenderer`. With `SETTINGS_SHEET_RENDER_DIR` set, each page is saved there as a PNG,
/// and `SETTINGS_SHEET_DUMP` writes every word the sheet shows, for a reader to check. Run by
/// `scripts/test-settings-sheet.sh`.
@MainActor
enum SettingsSheetTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SETTINGS_SHEET_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in run() }
    }

    private static var lines: [String] = []
    private static var dump: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static let date = Date(timeIntervalSince1970: 1_794_355_200)   // 2026-11-11, fixed for the sources' words

    private static func layer(_ kind: SettingsLayerKind, _ values: [(SettingsKey, SettingsValue)]) -> SettingsLayer {
        var l = SettingsLayer(kind: kind, name: kind == .general ? "General" : "Letters")
        for (k, v) in values { _ = l.set(k, v, source: .setByUser(date)) }
        return l
    }

    private static let running = SettingsSheetModel.Running(readingRouteID: "apple-vision",
                                                            readingName: "Apple Vision on this Mac",
                                                            segmentation: .manual)

    static func run() {
        defer { finish() }
        guard let table = SettingsRouteTable.bundled, table.problems().isEmpty else {
            check("0 bundled settings-routes.json fit to ship", false)
            return
        }
        let pairs = OCRPairMatrix.bundled
        func sheet(_ name: String, general: SettingsLayer, collection: SettingsLayer? = nil, gb: Double = 16,
                   pages: Int = 1000, running: SettingsSheetModel.Running = running) -> SettingsSheetModel {
            let m = SettingsSheetModel(table: table, pairs: pairs,
                                       resolver: SettingsResolver(general: general, project: nil, collection: collection),
                                       macMemoryGB: gb, pages: pages, running: running)
            record(name, m)
            return m
        }
        func card(_ m: SettingsSheetModel, _ id: String) -> SettingsSheetModel.Card? { m.cards.first { $0.id == id } }

        // 1. The rules tab: the six no-choice stages, in words, with their switches.
        check("1 the rules tab table carries rules for every rule stage",
              SettingsSheetModel.ruleStageIDs.allSatisfy { !(table.stage($0)?.rules.isEmpty ?? true) },
              SettingsSheetModel.ruleStageIDs.filter { table.stage($0)?.rules.isEmpty ?? true }.joined(separator: ","))
        let free = sheet("free", general: SettingsLayer(kind: .general, name: "General"))
        check("1 six rule stages shown", free.ruleStages.map(\.id) == SettingsSheetModel.ruleStageIDs,
              free.ruleStages.map(\.id).joined(separator: ","))
        check("1 every rule stage has its sheet text", free.ruleStages.allSatisfy { !$0.text.isEmpty && !$0.title.isEmpty })
        // B1 (13-profile-tests.md): layout regions on newspapers only, never on handwriting or registers.
        let layout = free.ruleStages.first { $0.id == "layout" }
        check("B1 layout: regions on newspapers only, never on handwriting or registers",
              layout?.text.contains("Newspapers") == true && layout?.text.contains("never split") == true
              && layout?.rules.contains { $0.id == "layout-never-hands-registers" } == true)
        // E: placement's hand line setting visible.
        let place = free.ruleStages.first { $0.id == "placement" }
        check("E placement: the handwriting placement switch is visible, on by default",
              place?.switches.first?.key == .placeHandOnImage && place?.switches.first?.isOn == true)
        check("1 straighten switch on by default", free.ruleStages.first { $0.id == "reading-copy" }?.switches.first?.isOn == true)
        let off = sheet("straighten-off", general: SettingsLayer(kind: .general, name: "General"),
                        collection: layer(.collection, [(.straightenReadingCopy, .bool(false))]))
        check("1 a collection's switch is read back with its source",
              off.ruleStages.first { $0.id == "reading-copy" }?.switches.first.map { !$0.isOn && $0.source.hasPrefix("set for this collection") } == true)
        check("1 the placement switch may be held by a collection", SettingsKey.placeHandOnImage.allowed(in: .collection))
        check("1 every table switch of a rule stage is stored somewhere",
              SettingsSheetModel.ruleStageIDs.compactMap { table.stage($0) }.flatMap(\.rules)
                .compactMap(\.switchSetting).allSatisfy { SettingsSheetModel.switchKey($0.id) != nil })

        // 2. Free, on this Mac (the skipped interview, B1).
        check("2 four cards", free.cards.map(\.id) == ["reading", "segmentation", "dating", "entities"])
        for c in free.cards {
            check("2 \(c.id) card complete", !c.why.isEmpty && !c.cost.isEmpty && !c.time.isEmpty && !c.memory.isEmpty
                  && !c.sources.isEmpty && !c.about.isEmpty, "\(c.why) | \(c.cost) | \(c.sources)")
        }
        check("2 totals: nothing spent", free.totals.first { $0.id == "money" }?.value == "$0")
        check("2 limits: nothing to spend", free.limits.first { $0.id == "ceiling" }?.value.hasPrefix("Nothing") == true)
        if let r = card(free, "reading") {
            check("2 reading on this Mac, free", r.family.contains("this Mac") && r.cost == "free", "\(r.family) \(r.cost)")
            check("2 handwritten figures labelled conditional on the truth",
                  r.parts.first { $0.id == "handwritten" }?.label2?.hasPrefix("conditional on the truth") == true)
            check("2 every figure names its sample", r.parts.allSatisfy { $0.sample != nil || $0.warning || $0.figure == "unmeasured" })
        } else { check("2 reading card", false) }
        if let s = card(free, "segmentation") {
            check("2 a magazine figure off the article rule ranks nothing yet",
                  s.routeID != "gemini3.8-flash" && s.parts.contains { $0.id == "magazine" && $0.label2?.hasPrefix("ranks nothing yet") == true },
                  s.routeID ?? "nil")
            check("2 the user's own checking time shown, with its 20 s assumption",
                  s.parts.contains { $0.id == "checking" && $0.sample?.contains("20 seconds") == true })
            check("2 a segmentation pick Process Files can run is offered to it",
                  s.routeID == "seg-qwen3.5-2b-8bit" ? s.apply == .segmentation(.local) : true, "\(s.apply as Any)")
        } else { check("2 segmentation card", false) }
        check("2 reading already runs: nothing to apply", card(free, "reading")?.apply == nil)

        // 3. A Gemini key and a ceiling (D1-like).
        let gem = layer(.general, [(.keys, .strings(["gemini"])), (.moneyHabit, .string(MoneyHabit.perBatch.rawValue)),
                                   (.batchCeilingUSD, .double(10)), (.staysOnMac, .bool(false)),
                                   (.priorities, .strings(SettingsPriority.allCases.map(\.rawValue)))])
        let paid = sheet("gemini", general: gem)
        if let s = card(paid, "segmentation") {
            if s.routeID == "gemini3.8-flash" {
                check("3 Gemini 3.8's segmentation card labels its figures as 3.7's", s.labels.contains { $0.contains("Gemini 3.7") })
                check("3 Gemini 3.8's magazine figure ranks", s.parts.first { $0.id == "magazine" }?.label2 == nil)
            } else {
                lines.append("SKIP 3 Gemini segmentation labels: the pick is \(s.routeID ?? "nil")")
            }
        }
        if let r = card(paid, "reading") {
            check("3 a paid pick names its cost", r.cost.contains("$") || r.cost.hasPrefix("free"), r.cost)
            check("3 a reading pick the app runs can be applied", r.routeID == "gemini3.8-flash" ? r.apply == .reading(appRoute: "gemini|gemini-3.8-flash") : true)
        }
        check("3 limits: the ceiling", paid.limits.first { $0.id == "ceiling" }?.value == "$10.00")

        // 4. Override and the way back.
        let custom = sheet("custom", general: gem,
                           collection: layer(.collection, [(SettingsSheetModel.overrideKey("reading"), .string("apple-vision"))]))
        if let r = card(custom, "reading") {
            check("4 an override marks the card Custom and keeps the app's pick for the way back",
                  r.isCustom && r.routeID == "apple-vision" && r.appPick != nil && r.why.hasPrefix("You chose"),
                  "\(r.isCustom) \(r.routeID ?? "") \(r.appPick ?? "nil")")
        } else { check("4 custom reading card", false) }
        check("4 only the overridden card is Custom", custom.cards.filter(\.isCustom).map(\.id) == ["reading"])
        let gone = sheet("custom-unknown", general: gem,
                         collection: layer(.collection, [(SettingsSheetModel.overrideKey("reading"), .string("no-such-route"))]))
        check("4 an override naming no route is ignored, and can still be cleared",
              card(gone, "reading").map { !$0.isCustom && $0.hasOverride } == true)
        let blocked = sheet("custom-blocked", general: SettingsLayer(kind: .general, name: "General"),
                            collection: layer(.collection, [(SettingsSheetModel.overrideKey("segmentation"), .string("gemini3.8-flash"))]))
        if let s = card(blocked, "segmentation") {
            check("4 an override that cannot run says why and names the app's real pick",
                  s.isCustom && s.why.contains("cannot run here") && s.appPick != nil && s.appPick != "nothing",
                  "\(s.why) | \(s.appPick ?? "nil")")
        } else { check("4 blocked custom segmentation card", false) }
        let noNames = sheet("custom-none", general: gem,
                            collection: layer(.collection, [(SettingsSheetModel.overrideKey("entities"), .string("none"))]))
        check("4 choosing No names runs as asked",
              card(noNames, "entities").map { $0.isCustom && !$0.why.contains("cannot run") } == true,
              card(noNames, "entities")?.why ?? "nil")
        check("4 names unranked: the Mac name readers are not offered",
              card(free, "entities")?.options.filter { $0.id == "qwen3-vl-8b-mac" }.allSatisfy { $0.blocked != nil } == true)
        if let s = card(paid, "segmentation"), let b = s.better.first, let raw = s.routeID.flatMap({ table.stage("segmentation")?.route($0) })?.figure("test-boxes"),
           let other = table.stage("segmentation")?.route(b.id)?.figure("test-boxes") {
            check("4 segmentation gains are against the no-checking figure",
                  b.gain.hasPrefix(String(format: "%.0f", other - raw)), "\(b.gain) vs \(other - raw)")
        }
        check("4 options list the routes a user cannot use with why",
              card(free, "reading")?.options.contains { $0.blocked != nil } == true)

        // 4b. The writes, on a scratch store and a scratch output folder: an override into the collection, the way back
        // from every layer, a switch, and the general settings when there is no folder.
        writes(table: table, pairs: pairs)

        // 5. An unmeasured kind in the mix.
        let mixed = sheet("clippings", general: SettingsLayer(kind: .general, name: "General"),
                          collection: layer(.collection, [(.mix, .numbers(["typewritten": 60, "clippings": 40]))]))
        check("5 an unmeasured kind is labelled unmeasured",
              card(mixed, "reading")?.parts.contains { $0.id == "clippings" && $0.figure == "unmeasured" } == true)

        // 6. Plain words: what the sheet shows outside its notes (evidence, bench notes, sources, rule detail) holds
        // none of the bench's ids.
        let jargon = try! NSRegularExpression(pattern: #"owner96|public895|\bNES\b|hands16|_|\bL[1-9]\b|\bN[1-6]\b|test-boxes|\bp\d{3}\b|\bg[12]\b|\bc1\b|blla|CTC|ed2|F1\b|\.md\b|owner call"#)
        for (name, m) in [("free", free), ("gemini", paid), ("custom", custom), ("clippings", mixed)] {
            let shown = visibleText(m)
            let hits = shown.filter { jargon.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            check("6 \(name): no bench ids in the sheet's own words", hits.isEmpty, hits.prefix(3).joined(separator: " || "))
        }

        // 7. Render: each page draws, both tabs. An 8 GB Mac: segmentation by hand, handwriting unread.
        let small = sheet("small", general: SettingsLayer(kind: .general, name: "General"), gb: 8)
        check("7 an 8 GB Mac: segmentation by hand says nothing is proposed",
              card(small, "segmentation")?.parts.first?.figure.hasPrefix("nothing is proposed") == true)
        check("7 an 8 GB Mac: the overall figure says what counts as 0",
              small.totals.first { $0.id == "accuracy" }?.detail?.contains("count as 0") == true)
        for (name, m) in [("free", free), ("gemini", paid), ("custom", custom), ("small", small)] {
            for tab in SettingsSheetView.Tab.allCases {
                let ink = renderedInk(SettingsSheetPage(model: m, tab: tab), saveAs: "\(name)-\(tab.rawValue.lowercased())")
                check("7 \(name) \(tab.rawValue) renders (\(ink) dark px)", ink > 20_000)
            }
        }
        let dark = renderedInk(SettingsSheetPage(model: free, tab: .choices), saveAs: "free-choices-dark", dark: true)
        check("7 dark appearance renders (\(dark) light px)", dark > 20_000)
    }

    private static func writes(table: SettingsRouteTable, pairs: OCRPairMatrix?) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("settings-sheet-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Letters", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = SettingsLayerStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let key = SettingsSheetModel.overrideKey("reading")
        func model(_ doc: CollectionSettingsDocument?) -> SettingsSheetModel {
            SettingsSheetModel(table: table, pairs: pairs, resolver: store.resolver(for: doc), macMemoryGB: 16,
                               pages: 100, running: running)
        }
        let w = SettingsSheetWriter(store: store, folder: folder)
        var out = w.set(key, .string("xiaomi-ocr-0-bf16"), doc: nil)
        check("4b an override is written into the collection", out.ok && out.doc?.collection.entry(key) != nil)
        check("4b the collection's file holds it", {
            if case .document(let d) = CollectionSettingsFile.read(in: folder) { return d.collection.entry(key) != nil }
            return false
        }())
        check("4b the card is Custom after the write", model(out.doc).cards.first { $0.id == "reading" }?.isCustom == true)
        _ = store.setGeneral(key, .string("lightonocr-3-4b-mlx8"), source: .setByUser(date))
        out = w.clear(key, doc: out.doc)
        check("4b the way back clears the collection and the general settings",
              out.ok && out.doc?.collection.entry(key) == nil && store.general.entry(key) == nil)
        check("4b the card is the app's pick again", model(out.doc).cards.first { $0.id == "reading" }.map { !$0.isCustom && !$0.hasOverride } == true)
        out = w.set(.placeHandOnImage, .bool(false), doc: out.doc)
        check("4b a switch is written into the collection",
              model(out.doc).ruleStages.first { $0.id == "placement" }?.switches.first?.isOn == false)
        let g = SettingsSheetWriter(store: store, folder: nil)
        let none = g.set(SettingsSheetModel.overrideKey("dating"), .string("vision-rules-t3"), doc: nil)
        check("4b with no folder the general settings take it", none.ok && store.general.entry(SettingsSheetModel.overrideKey("dating")) != nil)
        _ = g.clear(SettingsSheetModel.overrideKey("dating"), doc: nil)
        check("4b and give it back", store.general.entry(SettingsSheetModel.overrideKey("dating")) == nil)
    }

    /// Every string the sheet shows in its own words (not the notes, which quote the bench).
    private static func visibleText(_ m: SettingsSheetModel) -> [String] {
        var out = m.limits.flatMap { [$0.label, $0.value] } + m.totals.flatMap { [$0.label, $0.value, $0.detail ?? ""] } + m.toRelax
            + [m.notInUse ?? ""]
        for c in m.cards {
            out += [c.title, c.about, c.weight, c.family, c.why, c.cost, c.time, c.memory, c.runsNow ?? ""] + c.labels
            out += c.parts.flatMap { [$0.label, $0.figure, $0.sample ?? "", $0.label2 ?? ""] }
            out += c.better.flatMap { [$0.gain, $0.reason] }
            out += c.alternatives.flatMap { [$0.family, $0.figure, $0.cost] }
            out += c.options.compactMap(\.blocked)
        }
        out += m.ruleStages.flatMap { [$0.title, $0.text] + $0.switches.flatMap { [$0.label, $0.note ?? ""] } }
        return out.filter { !$0.isEmpty }
    }

    private static func record(_ name: String, _ m: SettingsSheetModel) {
        dump.append("=== \(name)")
        for l in m.limits { dump.append("LIMIT \(l.label): \(l.value) [\(l.source)]") }
        for t in m.totals { dump.append("TOTAL \(t.label): \(t.value) \(t.detail ?? "")") }
        for r in m.toRelax { dump.append("RELAX \(r)") }
        if let n = m.notInUse { dump.append("NOTINUSE \(n)") }
        for c in m.cards {
            dump.append("CARD \(c.title) | \(c.routeName) | \(c.family) | custom \(c.isCustom) | \(c.weight)")
            dump.append("  why: \(c.why)")
            for p in c.parts { dump.append("  part \(p.label): \(p.figure) \(p.routeName.map { "— \($0)" } ?? "") (\(p.sample ?? "-")) \(p.label2 ?? "")") }
            dump.append("  cost: \(c.cost) | time: \(c.time) | memory: \(c.memory)")
            for l in c.labels { dump.append("  label: \(l)") }
            if let n = c.runsNow { dump.append("  now: \(n) apply \(c.apply.map { "\($0)" } ?? "-")") }
            for b in c.better { dump.append("  better: \(b.name) would give \(b.gain): \(b.reason)") }
            for a in c.alternatives { dump.append("  alt: \(a.name) (\(a.family)): \(a.figure), \(a.cost)") }
            dump.append("  options: " + c.options.map { $0.name + ($0.blocked.map { " (\($0))" } ?? "") }.joined(separator: "; "))
            dump.append("  evidence: \(c.evidence)")
        }
        for s in m.ruleStages {
            dump.append("RULES \(s.title): \(s.text)")
            for w in s.switches { dump.append("  switch \(w.label): \(w.isOn) [\(w.source)]") }
        }
    }

    /// Dark (or, in dark mode, light) pixels of a page drawn offscreen at the sheet's width. Blank → 0.
    private static func renderedInk(_ view: some View, saveAs name: String, dark: Bool = false) -> Int {
        let content = view
            .frame(width: 780, alignment: .topLeading)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return 0 }
        if let dir = ProcessInfo.processInfo.environment["SETTINGS_SHEET_RENDER_DIR"],
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.setFillColor(dark ? .black : .white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var ink = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let lum = (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3
            if dark ? lum > 128 : lum < 128 { ink += 1 }
        }
        return ink
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["SETTINGS_SHEET_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
        if let path = ProcessInfo.processInfo.environment["SETTINGS_SHEET_DUMP"] {
            try? (dump.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

#endif
