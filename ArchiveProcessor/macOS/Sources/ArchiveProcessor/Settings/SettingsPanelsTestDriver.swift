#if DEBUG // a test driver, compiled out of Release
import Foundation

/// Headless, $0 self-test of the Settings window's panels (W47.settings-panels), gated by `SETTINGS_PANELS_TEST=1` (does
/// nothing in normal use). Checks that every setting has exactly one owning panel (`SettingsPanelOwnership`): each
/// layered key, each stage card and rule stage of the settings sheet, each sheet switch (owned by its stage's panel) and
/// each shortcut's key. No model call, no network, no Keychain read, no window. Writes the table as `OWNER <key>
/// <panel>` lines, which `scripts/test-settings-panels.sh` holds each panel's source file to. Run by that script.
@MainActor
enum SettingsPanelsTestDriver {
    private static var didRun = false
    private static var lines: [String] = []
    private static var failures = 0

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SETTINGS_PANELS_TEST"] == "1" else { return }
        didRun = true
        Task { @MainActor in run() }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    static func run() {
        defer { finish() }
        let owners = SettingsPanelOwnership.owners

        // 1. One owner per key.
        var seen: [String: SettingsPanel] = [:]
        var twice: [String] = []
        for (key, panel) in owners {
            if let first = seen[key], first != panel { twice.append("\(key): \(first.title) and \(panel.title)") }
            else if seen[key] != nil { twice.append("\(key): listed twice under \(panel.title)") }
            seen[key] = panel
        }
        check("1 no key has two owners", twice.isEmpty, twice.joined(separator: "; "))
        check("1 the panels are the design's eight, in its order",
              SettingsPanel.allCases.map(\.title) == ["General", "Collection", "Reading", "Documents", "Dates and names",
                                                     "Pages and output", "Capture", "Accounts"])
        for panel in SettingsPanel.allCases {
            check("1 \(panel.title) owns a setting", owners.contains { $0.panel == panel })
        }

        // 2. Every layered key in the catalog has an owner.
        let unowned = SettingsKey.catalog.filter { seen[$0.rawValue] == nil }.map(\.rawValue)
        check("2 every catalog key has an owning panel", unowned.isEmpty, unowned.joined(separator: ", "))

        // 3. Every sheet stage sits in a panel, and a card's override key is owned by that panel.
        for stage in SettingsSheetModel.cardStages + SettingsSheetModel.ruleStageIDs {
            check("3 stage \(stage) has a panel", SettingsPanelOwnership.stagePanels[stage] != nil)
        }
        for stage in SettingsSheetModel.cardStages {
            let key = SettingsSheetModel.overrideKey(stage).rawValue
            check("3 \(stage)'s override is owned by its card's panel",
                  seen[key] != nil && seen[key] == SettingsPanelOwnership.stagePanels[stage],
                  "\(seen[key]?.title ?? "none") against \(SettingsPanelOwnership.stagePanels[stage]?.title ?? "none")")
        }

        // 4. Each switch the sheet draws is owned by the panel that holds its stage (read from the bundled table).
        if let table = SettingsRouteTable.bundled, table.problems().isEmpty {
            let general = SettingsLayer(kind: .general, name: "General")
            let model = SettingsSheetModel(
                table: table, pairs: OCRPairMatrix.bundled,
                resolver: SettingsResolver(general: general, project: nil, collection: nil), macMemoryGB: 16, pages: 1000,
                running: .init(readingRouteID: "apple-vision", readingName: "Apple Vision on this Mac", segmentation: .manual),
                claudeBilling: .unknown)
            var drawn: [(String, String)] = model.ruleStages.flatMap { st in st.switches.map { (st.id, $0.key.rawValue) } }
            drawn += model.stageSwitches.flatMap { stage, rows in rows.map { (stage, $0.key.rawValue) } }
            if model.ruleStages.contains(where: { $0.forms != nil }) { drawn.append(("placement", SettingsKey.searchableFor.rawValue)) }
            check("4 the sheet draws its switches", drawn.count >= 4, "\(drawn.count) drawn")
            for (stage, key) in drawn {
                check("4 \(key) is owned by \(stage)'s panel",
                      seen[key] != nil && seen[key] == SettingsPanelOwnership.stagePanels[stage],
                      "\(seen[key]?.title ?? "none") against \(SettingsPanelOwnership.stagePanels[stage]?.title ?? "none")")
            }
            check("4 the dating card carries its image-pass switch",
                  model.stageSwitches["dating"]?.contains { $0.key == .dateImageEveryDocument } == true)
            check("4 the Dates card carries a separate local image switch, off by default",
                  model.stageSwitches["dating"]?.contains {
                      $0.key == .dateLocalImage && !$0.isOn && $0.label.contains("no measured gain")
                  } == true)
            check("4 the Names card carries its low-confidence switch, off by default",
                  model.stageSwitches["entities"]?.contains { $0.key == .lowConfidenceNames && !$0.isOn } == true)
            check("4 the layout stage carries its scanned-newspaper detector switch, off by default (W47.wh-yolo-scans)",
                  model.ruleStages.first { $0.id == "layout" }?.switches.contains {
                      $0.key == .scanNewspapersDocLayoutYOLO && !$0.isOn } == true)
            let switchKeys = Set(drawn.map(\.1))
            check("4 every sheet switch is drawn", SettingsPanelOwnership.sheetSwitches.allSatisfy { switchKeys.contains($0.rawValue) },
                  SettingsPanelOwnership.sheetSwitches.map(\.rawValue).filter { !switchKeys.contains($0) }.joined(separator: ", "))
        } else {
            check("4 bundled settings-routes.json fit to ship", false)
        }

        // 5. Every shortcut writes an owned key and names its home.
        for (control, key) in SettingsPanelOwnership.shortcuts {
            let note = SettingsPanelOwnership.shortcutNote(key)
            check("5 \(control) → \(key) names its owner",
                  seen[key] != nil && note?.contains(seen[key]!.home) == true, note ?? "no owner")
        }
        for stage in SettingsSheetModel.cardStages + SettingsSheetModel.ruleStageIDs {
            let panel = SettingsPanelOwnership.stagePanels[stage]
            check("5 the sheet's \(stage) box names its panel",
                  panel != nil && SettingsPanelOwnership.stageNote(stage)?.contains(panel!.home) == true)
        }

        levels(seen)

        // The tables themselves, for the script's source checks (a DEFAULT line is tab-separated: keys hold spaces).
        for (key, panel) in owners { lines.append("OWNER \(key) \(panel.rawValue)") }
        for row in SettingsLevels.rows {
            for key in row.keys {
                lines.append("LEVEL \(key) \(row.level.rawValue)")
                switch SettingsLevels.defaultValue(key) {
                case let b as Bool: lines.append("DEFAULT \(key)\t\(b)")
                case let n as Double: lines.append("DEFAULT \(key)\t\(n)")
                case let s as String: lines.append("DEFAULT \(key)\t\"\(s)\"")
                default: break
                }
            }
        }
    }

    /// W47.settings-level-switch: every setting has one level, every route row has one, the solver never picks an
    /// Advanced row, and a value changed from its default is shown at every level.
    private static func levels(_ owned: [String: SettingsPanel]) {
        let rows = SettingsLevels.rows

        // 6. One level per key, for every key a panel owns and every catalog key.
        var levelOf: [String: SettingsLevel] = [:]
        var twice: [String] = []
        for row in rows {
            for key in row.keys {
                if levelOf[key] != nil { twice.append(key) }
                levelOf[key] = row.level
            }
        }
        check("6 no key sits at two levels", twice.isEmpty, twice.joined(separator: ", "))
        check("6 row names are unique", Set(rows.map(\.id)).count == rows.count)
        let unlevelled = owned.keys.filter { levelOf[$0] == nil }.sorted()
        check("6 every key a panel owns has a level", unlevelled.isEmpty, unlevelled.joined(separator: ", "))
        let catalogUnlevelled = SettingsKey.catalog.filter { levelOf[$0.rawValue] == nil }.map(\.rawValue)
        check("6 every catalog key has a level", catalogUnlevelled.isEmpty, catalogUnlevelled.joined(separator: ", "))
        let stray = levelOf.keys.filter { owned[$0] == nil }.sorted()
        check("6 every levelled key has an owning panel", stray.isEmpty, stray.joined(separator: ", "))
        let empty = "settings-levels-empty-\(UUID().uuidString)"
        check("6 a new user starts at Basic", SettingsLevel.defaultLevel == .basic
              && UserDefaults(suiteName: empty).map { SettingsLevel.current($0) } == .basic)
        UserDefaults.standard.removePersistentDomain(forName: empty)
        check("6 the level itself is Basic, in General", levelOf[DefaultsKeys.settingsLevel] == .basic
              && owned[DefaultsKeys.settingsLevel] == .general)

        // 7. Advanced groups, each with its reason (levels.md §4 and §5).
        let advanced = rows.filter { $0.level == .advanced }
        // Sixteen since the owner's 2026-11-24 call (W49.proc-pipeline-prune-ok 1) moved handwriting placement to Advanced.
        check("7 sixteen groups at Advanced", advanced.count == 16,
              "\(advanced.count): " + advanced.map(\.id).joined(separator: ", "))
        check("7 every Advanced row says why", advanced.allSatisfy { !($0.why ?? "").isEmpty })
        check("7 no row below Advanced carries a reason", rows.filter { $0.level != .advanced }.allSatisfy { $0.why == nil })
        let expected: [(String, SettingsLevel)] = [
            (SettingsKey.lowConfidenceNames.rawValue, .advanced), (SettingsKey.dateLocalImage.rawValue, .advanced),
            (SettingsKey.placeHandOnImage.rawValue, .advanced), (SettingsKey.numericDatesDayFirst.rawValue, .standard),
            (DefaultsKeys.ocrPostCorrection, .advanced), (DefaultsKeys.selectedThinking, .advanced), (DefaultsKeys.ocrCascadeOnDisagreement, .advanced),
            (DefaultsKeys.visionMinimumConfidence, .advanced), (DefaultsKeys.gatewayBaseURL, .advanced),
            (DefaultsKeys.localAgentBinaryPath, .advanced), (DefaultsKeys.standardImageSizeMB, .advanced),
            (DefaultsKeys.ocrWorkerCount, .advanced), (DefaultsKeys.writeLogFile, .advanced),
            (DefaultsKeys.sendPreviousImage, .advanced), (DefaultsKeys.customOCRPrompt, .advanced),
            (DefaultsKeys.localSegmenterPartner, .advanced),
            (DefaultsKeys.selectedProvider, .standard), (DefaultsKeys.ocrCascadeRoute, .standard),
            (DefaultsKeys.rotationModeRaw, .standard), (DefaultsKeys.batchMode, .standard),
            (DefaultsKeys.segmentationApproach, .standard), (SettingsKey.dateImageEveryDocument.rawValue, .standard),
            (SettingsKey.scanNewspapersDocLayoutYOLO.rawValue, .standard),
            (SettingsSheetModel.overrideKey("reading").rawValue, .standard),
            (DefaultsKeys.taggingModeRaw, .basic), (DefaultsKeys.skipAlreadyProcessed, .basic),
            (SettingsKey.straightenReadingCopy.rawValue, .basic), (DefaultsKeys.liveProcessingMode, .basic),
            (DefaultsKeys.outputDirectory, .basic), ("keychain:Gateway", .basic),
        ]
        for (key, level) in expected {
            check("7 \(key) at \(level.title)", levelOf[key] == level, levelOf[key]?.title ?? "none")
        }
        // Every hidden setting stored in UserDefaults knows its default, so "changed" can be judged.
        let noDefault = rows.filter { $0.level > .basic }.flatMap(\.keys).filter {
            !$0.hasPrefix("keychain:") && !SettingsKey(rawValue: $0).isKnown && SettingsLevels.defaultValue($0) == nil
        }
        check("7 every setting above Basic knows its default", noDefault.isEmpty, noDefault.joined(separator: ", "))

        // 8. Every route row has a level; a lost or floor row and a trained model are Advanced; the solver never
        // picks one, and each card's choices carry their row's level.
        guard let table = SettingsRouteTable.bundled else { return check("8 the bundled table loads", false) }
        var routes = 0
        var wrong: [String] = []
        for stage in table.stages {
            for r in stage.routes {
                routes += 1
                let level = SettingsLevels.level(of: r)
                if !r.offered || r.afterTraining || r.lowerScoring {   // lower-scoring: W47.wh-readers-lost
                    if level != .advanced { wrong.append("\(stage.id)/\(r.id)") }
                    check("8 \(stage.id)/\(r.id) says why it is Advanced", !(SettingsLevels.why(r) ?? "").isEmpty)
                } else if level != .standard {
                    wrong.append("\(stage.id)/\(r.id)")
                }
            }
        }
        check("8 every route row has a level", routes > 0 && wrong.isEmpty,
              "\(routes) rows; wrong: " + wrong.joined(separator: ", "))
        if let fm = table.stage("reading")?.route("apple-fm-27") {
            check("8 the on-device row reports the Apple Vision comparison", SettingsLevels.why(fm)?.hasPrefix("Apple Vision scored 83.1") == true,
                  SettingsLevels.why(fm) ?? "nil")
        } else {
            check("8 apple-fm-27 is a reading row", false)
        }
        let model = SettingsSheetModel(
            table: table, pairs: OCRPairMatrix.bundled,
            resolver: SettingsResolver(general: SettingsLayer(kind: .general, name: "General"), project: nil, collection: nil),
            macMemoryGB: 16, pages: 1000,
            running: .init(readingRouteID: "apple-vision", readingName: "Apple Vision on this Mac", segmentation: .manual),
                claudeBilling: .unknown)
        for card in model.cards {
            let stageRoutes = table.stage(card.id)?.routes ?? []
            let route = card.routeID.flatMap { id in stageRoutes.first { $0.id == id } }
            check("8 the \(card.id) card's pick is not an Advanced row",
                  card.isCustom || route.map { SettingsLevels.level(of: $0) != .advanced } ?? true, card.routeID ?? "none")
            check("8 the \(card.id) card's choices each carry their row's level", card.options.allSatisfy { o in
                stageRoutes.first { $0.id == o.id }.map { SettingsLevels.level(of: $0) == o.level } ?? false
            })
            check("8 the \(card.id) card puts forward no lower-scoring row",
                  !card.alternatives.contains { a in stageRoutes.first { $0.id == a.id }?.lowerScoring == true }
                    && !card.better.contains { b in stageRoutes.first { $0.id == b.id }?.lowerScoring == true })
            if card.id == "reading" {
                // Owner call 25 keeps the document services as benchmark rows without Processor choices.
                let lower = Set(stageRoutes.filter { $0.lowerScoring && $0.offered }.map(\.id))
                let offered = Set(card.options.filter { $0.level == .advanced }.map(\.id)).intersection(lower)
                check("8 the reading card offers the lower-scoring rows at Advanced", offered == lower,
                      lower.subtracting(offered).sorted().joined(separator: ", "))
            }
        }

        // 9. A value changed from its default is shown at every level, and Reset puts it back (a scratch domain).
        let suite = "settings-levels-test-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else { return check("9 a scratch defaults domain", false) }
        defer { d.removePersistentDomain(forName: suite) }
        let workers = SettingsLevels.Row.workers
        check("9 an unset Advanced value is not a change", !SettingsLevels.changed(workers, in: d))
        check("9 an unset Advanced row is hidden at Basic",
              !SettingsLevels.shows(workers, at: .basic, changed: SettingsLevels.changed(workers, in: d)))
        d.set(4, forKey: DefaultsKeys.ocrWorkerCount)
        check("9 a stored default is not a change", !SettingsLevels.changed(workers, in: d))
        d.set(8, forKey: DefaultsKeys.ocrWorkerCount)
        check("9 a non-default Advanced value is a change", SettingsLevels.changed(workers, in: d))
        for level in SettingsLevel.allCases {
            check("9 a non-default Advanced value shows at \(level.title)",
                  SettingsLevels.shows(workers, at: level, changed: SettingsLevels.changed(workers, in: d)))
        }
        d.set(3.0, forKey: DefaultsKeys.standardImageSizeMB)   // what normalizeSizingDefaults writes back
        check("9 a normalized default is not a change", !SettingsLevels.changed(.imageSize, in: d))
        d.set(ThinkingLevel.high.rawValue, forKey: DefaultsKeys.selectedThinking)
        check("9 High thinking is a change", SettingsLevels.changed(.thinking, in: d))
        d.set(SegmentationApproach.gemini.rawValue, forKey: DefaultsKeys.segmentationApproach)
        check("9 a segmentation approach the user chose is a change", SettingsLevels.changed(.segmentationApproach, in: d))
        d.set(SegmentationApproach.gemini.rawValue, forKey: DefaultsKeys.segmentationApproachPreselected)
        check("9 the approach the app preselected is not a change", !SettingsLevels.changed(.segmentationApproach, in: d))
        d.set(true, forKey: DefaultsKeys.outputImageFile)
        check("9 a default-on switch left on is not a change", !SettingsLevels.changed(.outputSizes, in: d))
        SettingsLevels.reset(workers, in: d)
        check("9 Reset puts the value back",
              d.object(forKey: DefaultsKeys.ocrWorkerCount) == nil && !SettingsLevels.changed(workers, in: d))
        check("9 Standard rows show at Standard and Advanced, not Basic",
              !SettingsLevels.shows(.batch, at: .basic, changed: false)
              && SettingsLevels.shows(.batch, at: .standard, changed: false)
              && SettingsLevels.shows(.batch, at: .advanced, changed: false))
        check("9 Basic rows show at every level",
              SettingsLevel.allCases.allSatisfy { SettingsLevels.shows(.taggingMode, at: $0, changed: false) })
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["SETTINGS_PANELS_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
#endif
