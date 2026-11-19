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
                running: .init(readingRouteID: "apple-vision", readingName: "Apple Vision on this Mac", segmentation: .manual))
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

        // The table itself, for the script's source check.
        for (key, panel) in owners { lines.append("OWNER \(key) \(panel.rawValue)") }
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
