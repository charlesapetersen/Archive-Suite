#if DEBUG // a test driver, compiled out of Release
import Foundation
import ArchiveCore

/// Headless, $0 self-test of the Settings window's five tabs (W49.proc-settings-redesign-core), gated by
/// `SETTINGS_TABS_TEST=1` (does nothing in normal use). Checks that every setting the window sets has exactly one home
/// tab (`SettingsTabOwnership`), that the Advanced groups know their defaults and count and reset as the Processing tab
/// says, that every measured route row has a tier, and that the reader and the presets read the stored flags as a run
/// does. No model call, no network, no Keychain read, no window; scratch defaults domains only. Writes the table as
/// `OWNER <key> <tab>` lines, which `scripts/test-settings-tabs.sh` holds each tab's source file to.
@MainActor
enum SettingsTabsTestDriver {
    private static var didRun = false
    private static var lines: [String] = []
    private static var failures = 0

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SETTINGS_TABS_TEST"] == "1" else { return }
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
        ownership()
        advanced()
        routeTiers()
        readerAndPresets()
    }

    // 1-3. Five tabs in the design's order; every key one home; the shortcuts name it.
    private static func ownership() {
        check("1 five tabs in order", SettingsTab.allCases.map(\.title) == ["Processing", "Output", "Capture", "Accounts", "Advanced"])
        var seen: [String: SettingsTab] = [:]
        var twice: [String] = []
        for (key, tab) in SettingsTabOwnership.owners {
            if let other = seen[key], other != tab { twice.append("\(key): \(other.title), \(tab.title)") }
            seen[key] = tab
            lines.append("OWNER \(key) \(tab.rawValue)")
        }
        // The Advanced defaults, for the script's check against the app's own declarations (tab-separated).
        for key in SettingsAdvanced.groups.flatMap(\.keys) {
            switch SettingsAdvanced.defaultValue(key) {
            case let b as Bool: lines.append("DEFAULT \(key)\t\(b)")
            case let n as Double: lines.append("DEFAULT \(key)\t\(n)")
            case let s as String: lines.append("DEFAULT \(key)\t\"\(s)\"")
            default: break
            }
        }
        check("2 no setting has two home tabs", twice.isEmpty, twice.joined(separator: "; "))
        // The settings the window must still set (processor-settings-redesign.md §6.2, call 13: nothing dropped).
        let expected = [
            DefaultsKeys.selectedProvider, DefaultsKeys.selectedThinking, DefaultsKeys.useGateway, DefaultsKeys.useLocalAgent,
            DefaultsKeys.useAppleVision, DefaultsKeys.gatewayBaseURL, DefaultsKeys.gatewayModelID, DefaultsKeys.gatewayDisplayName,
            DefaultsKeys.gatewayInputCost, DefaultsKeys.gatewayOutputCost, DefaultsKeys.gatewayUpstreamProvider,
            DefaultsKeys.gatewayLocalModel, DefaultsKeys.gatewayLocalEscalates, DefaultsKeys.visionUseLLMJudgment,
            DefaultsKeys.visionLanguages, DefaultsKeys.visionFastRecognition, DefaultsKeys.visionMinimumConfidence,
            DefaultsKeys.visionCustomVocabulary, DefaultsKeys.ocrCascadeRoute, DefaultsKeys.ocrCascadeOnDisagreement,
            DefaultsKeys.ocrPostCorrection, DefaultsKeys.ocrPageKindRouting, DefaultsKeys.taggingModeRaw,
            DefaultsKeys.itemTypeColourBox, DefaultsKeys.itemTypeColourFolder, DefaultsKeys.tagVocabulary,
            DefaultsKeys.enableCollectionSegmentation, DefaultsKeys.confirmCollectionIDs, DefaultsKeys.reviewDocumentSegmentation,
            DefaultsKeys.enableSegmentJSON, DefaultsKeys.sendPreviousImage, DefaultsKeys.macItemFields, DefaultsKeys.mergeDocuments,
            DefaultsKeys.customOCRPrompt, DefaultsKeys.segmentationApproach, DefaultsKeys.localSegmenterPartner,
            DefaultsKeys.localSegmenterBaseURL, DefaultsKeys.localSegmenterModelID, DefaultsKeys.rotationModeRaw,
            DefaultsKeys.reviewRotation, DefaultsKeys.imageResolutionPercent, DefaultsKeys.standardImageSizeMB,
            DefaultsKeys.pdfImageSizeMB, DefaultsKeys.exportedImageSizeMB, DefaultsKeys.outputImageFile, DefaultsKeys.textColumns,
            DefaultsKeys.skipAlreadyProcessed, DefaultsKeys.preOCRedInput, DefaultsKeys.batchMode, DefaultsKeys.ocrWorkerCount,
            DefaultsKeys.writeLogFile, DefaultsKeys.liveProcessingMode, DefaultsKeys.readContainerLabels, DefaultsKeys.driveClientId,
            DefaultsKeys.localAgentTool, DefaultsKeys.localAgentBinaryPath, DefaultsKeys.localAgentModel,
            DefaultsKeys.offerExperimentalRoutes, AppAppearance.defaultsKey,
        ] + [SettingsKey.straightenReadingCopy, .placeHandOnImage, .searchableFor, .dateImageEveryDocument, .dateLocalImage,
             .lowConfidenceNames, .numericDatesDayFirst, .scanNewspapersDocLayoutYOLO, .staysOnMac, .noTraining,
             .keepPreservationCopies, .moneyHabit, .monthCeilingUSD, .batchCeilingUSD].map(\.rawValue)
            + LLMProvider.allCases.filter { $0 != .appleVision }.map { "keychain:\($0.rawValue)" }
        let homeless = expected.filter { seen[$0] == nil }
        check("2 every setting the window sets has a home tab", homeless.isEmpty, homeless.joined(separator: ", "))
        for (control, key) in SettingsTabOwnership.shortcuts {
            let note = SettingsTabOwnership.shortcutNote(key)
            check("3 \(control) names its home", note?.contains(seen[key]?.home ?? "?") == true, note ?? "nil")
        }
        for stage in SettingsSheetModel.cardStages + SettingsSheetModel.ruleStageIDs {
            check("3 sheet stage \(stage) names a tab", SettingsSheetPage.stageNote(stage) != nil)
        }
    }

    // 4. The Advanced groups: a reason each, a default each key, and a count and a reset that mean what they say.
    private static func advanced() {
        for g in SettingsAdvanced.groups {
            check("4 \(g.id) says why it is Advanced", !g.why.isEmpty)
            for key in g.keys {
                check("4 \(key) knows its default", SettingsAdvanced.defaultValue(key) != nil)
            }
        }
        let suite = "settings-tabs-test-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else { return check("4 a scratch defaults domain", false) }
        defer { d.removePersistentDomain(forName: suite) }
        let general = SettingsResolver(general: SettingsLayer(kind: .general, name: "General"), project: nil, collection: nil)
        check("4 nothing set: nothing in use", SettingsAdvanced.activeGroups(in: d, resolver: general).isEmpty)
        d.set(4, forKey: DefaultsKeys.ocrWorkerCount)
        d.set(100.0, forKey: DefaultsKeys.imageResolutionPercent)
        d.set(LocalSegmenter.defaultBaseURL, forKey: DefaultsKeys.localSegmenterBaseURL)
        check("4 a stored default is not in use", SettingsAdvanced.activeGroups(in: d, resolver: general).isEmpty,
              SettingsAdvanced.activeGroups(in: d, resolver: general).map(\.id).joined(separator: ", "))
        d.set(8, forKey: DefaultsKeys.ocrWorkerCount)
        d.set(ThinkingLevel.high.rawValue, forKey: DefaultsKeys.selectedThinking)
        let active = SettingsAdvanced.activeGroups(in: d, resolver: general).map(\.id)
        check("4 a changed value is in use", active == ["thinking", "workers"], active.joined(separator: ", "))
        var layer = SettingsLayer(kind: .collection, name: "Letters")
        layer.set(.lowConfidenceNames, .bool(true), source: .setByUser(Date()))
        let collection = SettingsResolver(general: general.general, project: nil, collection: layer)
        check("4 a collection's layered switch is in use there",
              SettingsAdvanced.activeGroups(in: d, resolver: collection).map(\.id).contains("low-confidence-names"))
        check("4 and not in the general defaults",
              !SettingsAdvanced.activeGroups(in: d, resolver: general).map(\.id).contains("low-confidence-names"))
        if let workers = SettingsAdvanced.group("workers") { SettingsAdvanced.reset(workers, in: d) }
        check("4 Reset removes the stored value", d.object(forKey: DefaultsKeys.ocrWorkerCount) == nil
              && !SettingsAdvanced.activeGroups(in: d, resolver: general).map(\.id).contains("workers"))
        check("4 lower-scoring choices are off by default", RouteTier.current(d) == .standard)
        d.set(true, forKey: DefaultsKeys.offerExperimentalRoutes)
        check("4 the Advanced switch offers them", RouteTier.current(d) == .advanced
              && SettingsAdvanced.activeGroups(in: d, resolver: general).map(\.id).contains("experimental"))
    }

    // 5. Every route row has a tier; a lost or floor row, a trained model and a lower-scoring reader are Advanced,
    // say why, and are never a card's pick.
    private static func routeTiers() {
        guard let table = SettingsRouteTable.bundled else { return check("5 the bundled table loads", false) }
        var routes = 0
        var wrong: [String] = []
        for stage in table.stages {
            for r in stage.routes {
                routes += 1
                let tier = SettingsAdvanced.tier(of: r)
                if !r.offered || r.afterTraining || r.lowerScoring {
                    if tier != .advanced { wrong.append("\(stage.id)/\(r.id)") }
                    check("5 \(stage.id)/\(r.id) says why it is Advanced", !(SettingsAdvanced.why(r) ?? "").isEmpty)
                } else if tier != .standard {
                    wrong.append("\(stage.id)/\(r.id)")
                }
            }
        }
        check("5 every route row has a tier", routes > 0 && wrong.isEmpty, "\(routes) rows; wrong: " + wrong.joined(separator: ", "))
        if let fm = table.stage("reading")?.route("apple-fm-27") {
            check("5 the on-device row reports the Apple Vision comparison",
                  SettingsAdvanced.why(fm)?.hasPrefix("Apple Vision scored 83.1") == true, SettingsAdvanced.why(fm) ?? "nil")
        } else {
            check("5 apple-fm-27 is a reading row", false)
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
            check("5 the \(card.id) card's pick is not an Advanced row",
                  card.isCustom || route.map { SettingsAdvanced.tier(of: $0) != .advanced } ?? true, card.routeID ?? "none")
            check("5 the \(card.id) card's choices each carry their row's tier", card.options.allSatisfy { o in
                stageRoutes.first { $0.id == o.id }.map { SettingsAdvanced.tier(of: $0) == o.tier } ?? false
            })
        }
    }

    // 6. The reader menu and the presets read the four backend flags exactly as a run does.
    private static func readerAndPresets() {
        let suite = "settings-reader-test-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else { return check("6 a scratch defaults domain", false) }
        defer { d.removePersistentDomain(forName: suite) }
        for choice in [ReaderChoice.appleVision, .onDevice, .localAgent, .gateway, .direct(.gemini, "gemini-x"),
                       .direct(.openrouter, "vendor/model:free")] {
            check("6 \(choice.tag) round-trips its tag", ReaderChoice(tag: choice.tag) == choice)
        }
        d.set(true, forKey: DefaultsKeys.useLocalAgent)
        check("6 the Local Agent flag reads as the CLI reader", ReaderChoice.current(d) == .localAgent)
        let config = ResolvedRunConfig.fromDefaults(d)
        check("6 and a run reads it the same way", config.localAgent != nil)
        d.set(false, forKey: DefaultsKeys.useLocalAgent)
        d.set(true, forKey: DefaultsKeys.useGateway)
        check("6 the gateway flag reads as the gateway", ReaderChoice.current(d) == .gateway)
        check("6 a gateway that is not local is no Local HD preset", !WorkflowPreset.localHD.matches(d, cluster: false))
        d.set(true, forKey: DefaultsKeys.gatewayLocalModel)
        check("6 a local gateway is the Local HD preset", WorkflowPreset.localHD.matches(d, cluster: false)
              && !WorkflowPreset.cloud.matches(d, cluster: false))
        d.set(false, forKey: DefaultsKeys.useGateway)
        d.set(LLMProvider.anthropic.rawValue, forKey: DefaultsKeys.selectedProvider)
        if case .direct(let p, _) = ReaderChoice.current(d) {
            check("6 no flag reads as the selected provider's model", p == .anthropic)
        } else {
            check("6 no flag reads as the selected provider's model", false)
        }
        check("6 a direct key is the Cloud preset", WorkflowPreset.cloud.matches(d, cluster: false)
              && !WorkflowPreset.fastFree.matches(d, cluster: false))
        check("6 the Cluster preset follows the cluster answer", WorkflowPreset.cluster.matches(d, cluster: true)
              && !WorkflowPreset.cluster.matches(d, cluster: false))
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["SETTINGS_TABS_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
#endif
