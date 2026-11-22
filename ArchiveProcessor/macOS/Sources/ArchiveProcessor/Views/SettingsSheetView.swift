import SwiftUI

/// The settings sheet, shape A (W46.settings-sheet; `12-settings-design.md` §3.3): the limits and this batch's totals at
/// the top, one card per stage with the app's pick and what a better figure would need, an override with a way back,
/// the range tab's charts one tab away (`SettingsRangeTab`, §3.4), and a tab of the stages that are rules rather than
/// choices. Replaces the segmentation chooser's figures and the OCR
/// model guide; a card whose pick the Processor can run offers to apply it to what Process Files runs. Everything shown is built by
/// `SettingsSheetModel`, which the self-test reads.
struct SettingsSheetView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case choices = "Choices", range = "Range", rules = "Rules"
        var id: String { rawValue }
    }

    /// The collection: Process Files' output folder, or nil when none is chosen (the general settings then answer).
    let outputFolder: URL?
    /// The pages the batch figures are for.
    let pages: Int
    /// Says what `pages` is ("for the 42 pages dropped", "for 1,000 pages").
    let pagesCaption: String
    var initialTab: Tab = .choices
    var onDone: () -> Void

    @State private var tab: Tab = .choices

    static func running(segmentation: SegmentationApproach, useAppleVision: Bool, useGateway: Bool,
                        useLocalAgent: Bool, provider: LLMProvider, model: LLMModel,
                        table: SettingsRouteTable?, localAgentTool: LocalAgentTool = .claude,
                        localAgentModel: String = "", appleVisionModelID: String = "macos-vision",
                        claudeBilling: ClaudeCLIBilling = .unknown) -> SettingsSheetModel.Running {
        if useAppleVision {
            // W47.wh-readers-lost-clients: the Mac's reader is Vision unless the reading card chose the on-device model.
            if appleVisionModelID == OnDeviceModelClient.modelID {
                return .init(readingRouteID: SettingsSheetModel.onDeviceRouteID, readingName: "the macOS on-device model on this Mac",
                             segmentation: segmentation)
            }
            return .init(readingRouteID: "apple-vision", readingName: "Apple Vision on this Mac", segmentation: segmentation)
        }
        if useLocalAgent {
            // `claude` at a measured Anthropic model is that row read by the plan (W41.app-claude-plan-reading).
            let model = localAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if localAgentTool == .claude, claudeBilling == .subscription, !model.isEmpty,
               let r = table?.stage("reading")?.routes.first(where: { $0.appRoute == "anthropic|\(model)" && $0.needs.plan == ["claude"] }) {
                return .init(readingRouteID: r.id, readingName: "your Claude plan (\(model))", segmentation: segmentation,
                             onPlan: true)
            }
            let name = localAgentTool == .claude && claudeBilling == .apiKey
                ? "Claude Code on its API key" : "your signed-in command-line agent"
            return .init(readingRouteID: nil, readingName: name, segmentation: segmentation)
        }
        if useGateway {
            return .init(readingRouteID: nil, readingName: "the model on your API gateway", segmentation: segmentation)
        }
        // A maker's model through OpenRouter is the measured row of its maker (W41.app-openrouter-any).
        let route = (provider == .openrouter ? OpenRouterRoute.forModel(model.id)?.makerAppRoute : nil)
            ?? "\(provider.rawValue.lowercased())|\(model.id)"
        let id = table?.stage("reading")?.routes.first { $0.appRoute == route }?.id
        return .init(readingRouteID: id, readingName: model.displayName, segmentation: segmentation)
    }

    var body: some View {
        SettingsSheetHost(outputFolder: outputFolder, pages: pages) { model, actions in
            VStack(spacing: 0) {
                header
                Divider()
                if let model {
                    ScrollView {
                        // Each card and rule says which Settings panel it is set in (W47.settings-panels).
                        SettingsSheetPage(model: model, tab: tab, choose: actions.choose, apply: actions.apply,
                                          setSwitch: actions.setSwitch, setStrings: actions.setStrings,
                                          seeRange: { tab = .range }, showsHomes: true)
                    }
                } else {
                    Text("The measured figures are missing from this build, so the settings sheet cannot be shown.")
                        .padding(24)
                    Spacer()
                }
                Divider()
                HStack {
                    if let message = actions.problem {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("ap.sheet.done")
                }
                .padding(12)
            }
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 720)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.sheet")
        .onAppear { tab = initialTab }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings for \(outputFolder?.lastPathComponent ?? "new collections")").font(.title3.weight(.semibold))
                Text("The app's choices for your answers and your Mac, \(pagesCaption). Every figure was measured on test "
                     + "pages and says how many.")
                    .font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .accessibilityIdentifier("ap.sheet.tab")
        }
        .padding(16)
    }
}

/// What a sheet page or a Settings panel's cards do when the user chooses: written through `SettingsSheetWriter` or to
/// what Process Files runs. `problem` is what went wrong, in words: this host's own reading or writing (`ownProblem`),
/// else the store's last problem.
struct SettingsSheetActions {
    var choose: (String, String?) -> Void
    var apply: (SettingsSheetModel.Apply) -> Void
    var setSwitch: (SettingsKey, Bool) -> Void
    var setStrings: (SettingsKey, [String]) -> Void
    var ownProblem: String?
    var storeProblem: String?
    var problem: String? { ownProblem ?? storeProblem }
}

/// Builds the settings sheet's model for the collection and this Mac, and writes its choices. Shared by the modal
/// sheet and the Settings panels' stage cards (W47.settings-panels), so the two read and write the same layers.
struct SettingsSheetHost<Content: View>: View {
    let outputFolder: URL?
    let pages: Int
    @ViewBuilder var content: (SettingsSheetModel?, SettingsSheetActions) -> Content

    @ObservedObject private var store = SettingsLayerStore.shared
    @AppStorage(DefaultsKeys.segmentationApproach) private var segmentationRaw = SegmentationApproach.defaultApproach.rawValue
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision = false
    @AppStorage(DefaultsKeys.useGateway) private var useGateway = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent = false
    @AppStorage(DefaultsKeys.localAgentTool) private var localAgentToolRaw = LocalAgentTool.claude.rawValue
    @AppStorage(DefaultsKeys.localAgentBinaryPath) private var localAgentBinaryPath = ""
    @ObservedObject private var claudeUsage = ClaudeCLIUsage.shared
    @AppStorage(DefaultsKeys.localAgentModel) private var localAgentModel = ""
    @AppStorage(DefaultsKeys.batchMode) private var batchMode = false
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    @AppStorage(OpenRouterListing.defaultsKey) private var openRouterListingData: Data?

    @State private var doc: CollectionSettingsDocument?
    @State private var problem: String?

    private var resolver: SettingsResolver { store.resolver(for: doc) }

    private var claudeBinary: String? {
        ClaudeCLIBilling.binaryPath(tool: LocalAgentTool(rawValue: localAgentToolRaw) ?? .claude,
                                    override: localAgentBinaryPath)
    }

    private var claudeBilling: ClaudeCLIBilling { claudeUsage.billing(for: claudeBinary) }

    private var model: SettingsSheetModel? {
        guard let table = SettingsRouteTable.bundled, table.problems().isEmpty else { return nil }
        _ = openRouterListingData
        var running = SettingsSheetView.running(
            segmentation: SegmentationApproach(rawValue: segmentationRaw) ?? .defaultApproach,
            useAppleVision: useAppleVision, useGateway: useGateway, useLocalAgent: useLocalAgent,
            provider: selectedProvider, model: modelStore.model(for: selectedProvider), table: table,
            localAgentTool: LocalAgentTool(rawValue: localAgentToolRaw) ?? .claude, localAgentModel: localAgentModel,
            appleVisionModelID: modelStore.model(for: .appleVision).id, claudeBilling: claudeBilling)
        if !useAppleVision, !useGateway, !useLocalAgent,
           let warning = modelStore.unavailableOpenRouterSelection(for: selectedProvider) {
            running.readingRouteID = nil
            running.unavailableModelWarning = warning
        }
        return SettingsSheetModel(table: table, pairs: OCRPairMatrix.bundled, resolver: resolver,
                                  macMemoryGB: SettingsLayerStore.thisMacMemoryGB, pages: pages,
                                  month: store.monthSpend(), running: running, claudeBilling: claudeBilling)
    }

    var body: some View {
        content(model, SettingsSheetActions(choose: choose, apply: apply, setSwitch: setSwitch, setStrings: setStrings,
                                            ownProblem: problem, storeProblem: store.lastProblem))
            .onAppear { reload() }
            // A Settings panel lives as long as the window: follow Process Files' folder, and another view's write.
            .onChange(of: outputFolder) { _, _ in reload() }
            .onChange(of: store.collectionRevision) { _, _ in reload() }
    }

    // MARK: Writing

    private var writer: SettingsSheetWriter { SettingsSheetWriter(store: store, folder: outputFolder) }

    /// A card's override, or the way back (nil). Process Files' own choice changes only by the card's Use button.
    private func choose(_ stage: String, _ routeID: String?) {
        let key = SettingsSheetModel.overrideKey(stage)
        take(routeID.map { writer.set(key, .string($0), doc: doc) } ?? writer.clear(key, doc: doc))
    }

    private func setSwitch(_ key: SettingsKey, _ on: Bool) { take(writer.set(key, .bool(on), doc: doc)) }

    private func setStrings(_ key: SettingsKey, _ list: [String]) { take(writer.set(key, .strings(list), doc: doc)) }

    private func take(_ outcome: SettingsSheetWriter.Outcome) {
        doc = outcome.doc
        problem = outcome.ok ? nil : (store.lastProblem ?? "The change could not be saved.")
    }

    private func apply(_ a: SettingsSheetModel.Apply) {
        switch a {
        case .segmentation(let approach):
            segmentationRaw = approach.rawValue
        case .appleVision(let modelID):
            useGateway = false
            useLocalAgent = false
            useAppleVision = true
            batchMode = false
            if let m = LLMProvider.appleVision.models.first(where: { $0.id == modelID }) {
                modelStore.setModel(m, for: .appleVision)
            }
        case .reading(let appRoute):
            let parts = appRoute.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let provider = LLMProvider.allCases.first(where: { $0.rawValue.lowercased() == parts[0] }),
                  let m = provider.models.first(where: { $0.id == parts[1] }) else { return }
            useGateway = false
            useLocalAgent = false
            useAppleVision = false
            selectedProvider = provider
            modelStore.setModel(m, for: provider)
        case .readingByPlan(let model):
            let binary = claudeBinary
            Task {
                let billing = await claudeUsage.refresh(binary: binary, force: true)
                guard binary == claudeBinary, billing == .subscription else {
                    problem = "Claude Code's subscription sign-in could not be confirmed. Check its sign-in before selecting the plan."
                    return
                }
                problem = nil
                useGateway = false
                useAppleVision = false
                if localAgentToolRaw != LocalAgentTool.claude.rawValue { localAgentBinaryPath = "" }
                localAgentToolRaw = LocalAgentTool.claude.rawValue
                localAgentModel = model
                useLocalAgent = true
            }
        }
    }

    private func reload() {
        guard let folder = outputFolder else { doc = nil; return }
        switch CollectionSettingsFile.read(in: folder) {
        case .document(let d): doc = d; problem = nil
        case .missing: doc = nil; problem = nil
        case .unreadable:
            doc = nil
            problem = "This collection's settings file could not be read, so your general settings are shown."
        case .refused(let e): doc = nil; problem = "This collection's settings were left alone: \(e.description)."
        }
    }
}

/// A button that opens the settings sheet for Process Files' output folder (the collection), scaled to `pages`.
struct SettingsSheetButton: View {
    let title: String
    let pages: Int
    let pagesCaption: String
    var initialTab: SettingsSheetView.Tab = .choices
    @State private var showing = false

    /// The folder Process Files writes into, resolved as it resolves it (as `CollectionSettingsSection` does).
    static func outputFolder() -> URL? {
        #if DEBUG
        if let folder = ProcessorUITestConfiguration.outputDirectory { return folder }
        #endif
        return ModelSelectionStore.savedOutputDirectory()
    }

    var body: some View {
        Button(title) { showing = true }
            .sheet(isPresented: $showing) {
                SettingsSheetView(outputFolder: Self.outputFolder(), pages: max(1, pages), pagesCaption: pagesCaption,
                                  initialTab: initialTab) { showing = false }
            }
    }
}

/// The sheet's page for one tab, from a model alone, so the self-test renders exactly what the sheet draws.
struct SettingsSheetPage: View {
    let model: SettingsSheetModel
    let tab: SettingsSheetView.Tab
    var choose: (String, String?) -> Void = { _, _ in }
    var apply: (SettingsSheetModel.Apply) -> Void = { _ in }
    var setSwitch: (SettingsKey, Bool) -> Void = { _, _ in }
    var setStrings: (SettingsKey, [String]) -> Void = { _, _ in }
    /// Each card's "See the range" link; nil draws none.
    var seeRange: (() -> Void)? = nil
    /// Each card and rule names the Settings panel it is set in (the modal sheet; W47.settings-panels).
    var showsHomes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tab {
            case .choices: choices(model)
            case .range: SettingsRangeTab(model: model, choose: choose)
            case .rules: rules(model)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Choices

    @ViewBuilder private func choices(_ m: SettingsSheetModel) -> some View {
        SheetLimitsAndTotals(model: m)

        ForEach(m.cards) { card in
            StageCardView(card: card, choose: { choose(card.id, $0) }, backToApp: { choose(card.id, nil) },
                          apply: apply, seeRange: seeRange,
                          homeNote: showsHomes ? SettingsPanelOwnership.stageNote(card.id) : nil)
            ForEach(m.stageSwitches[card.id] ?? []) { sw in
                SheetSwitchRow(row: sw, setSwitch: setSwitch)
            }
        }
    }

    // MARK: Rules

    @ViewBuilder private func rules(_ m: SettingsSheetModel) -> some View {
        Text("These steps were measured and have no trade-off to choose: every option tried was the same or worse. "
             + "They run the same way for every collection; a switch is shown only where one is offered.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(m.ruleStages) { stage in
            RuleStageBox(stage: stage, setSwitch: setSwitch, setStrings: setStrings,
                         homeNote: showsHomes ? SettingsPanelOwnership.stageNote(stage.id) : nil)
        }
    }
}

/// The limits the user set and this batch's totals: the top of the sheet, and the Collection panel's strip.
struct SheetLimitsAndTotals: View {
    let model: SettingsSheetModel

    var body: some View {
        let m = model
        SheetBox {
            Text("Your limits").font(.headline)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(m.limits) { l in
                        GridRow {
                            Text(l.label).foregroundStyle(.primary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(l.value).fixedSize(horizontal: false, vertical: true)
                                Text(l.source).font(.caption2).foregroundStyle(.primary)
                            }
                        }
                    }
                }
                Text("Change these with “Questions about this material” in Settings.")
                    .font(.caption2).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ap.sheet.limits")

        HStack(alignment: .top, spacing: 8) {
            ForEach(m.totals) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.label).font(.caption).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(t.value).font(.title3.weight(.semibold))
                    if let d = t.detail {
                        Text(d).font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ap.sheet.totals")

        if let n = m.notInUse {
            Label(n, systemImage: "exclamationmark.circle").font(.caption).fixedSize(horizontal: false, vertical: true)
        }

        if !m.toRelax.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("To do better").font(.caption.weight(.semibold))
                ForEach(m.toRelax, id: \.self) { Text("• \($0)").font(.caption).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// One table switch, with where its value comes from.
struct SheetSwitchRow: View {
    let row: SettingsSheetModel.SwitchRow
    var setSwitch: (SettingsKey, Bool) -> Void

    var body: some View {
        let sw = row
        // W47.settings-level-switch: the switch is shown from its key's level up, and below it while it is not its
        // default (judged on the value the layers resolve, wherever it was set).
        let builtIn: Bool? = { if case .bool(let b) = sw.key.defaultValue { return b } else { return nil } }()
        let changed = builtIn.map { $0 != sw.isOn } ?? false
        if let levelRow = SettingsLevels.rows.first(where: { $0.keys.contains(sw.key.rawValue) }) {
            SettingsLevelRows(levelRow, changed: changed, reset: builtIn.map { b in { setSwitch(sw.key, b) } }) { toggle(sw) }
        } else {
            toggle(sw)
        }
        if sw.offersHandDownload { HandPlacerDownloadRow().settingsLevel(.downloads) }
        if sw.offersScanLayoutDownload { ScanNewspaperLayoutDownloadRow().settingsLevel(.downloads) }
    }

    private func toggle(_ sw: SettingsSheetModel.SwitchRow) -> some View {
        Toggle(isOn: Binding(get: { sw.isOn }, set: { setSwitch(sw.key, $0) })) {
            VStack(alignment: .leading, spacing: 0) {
                Text(sw.label)
                Text(sw.source).font(.caption2).foregroundStyle(.primary)
                if let note = sw.note {
                    Text(note).font(.caption2).italic().foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("ap.sheet.switch.\(sw.id)")
    }
}

/// One stage that is a rule rather than a choice: its text, its switches and its rules in detail.
struct RuleStageBox: View {
    let stage: SettingsSheetModel.RuleStage
    var setSwitch: (SettingsKey, Bool) -> Void
    var setStrings: (SettingsKey, [String]) -> Void
    /// Where the stage is set, in the modal sheet (W47.settings-panels).
    var homeNote: String? = nil

    var body: some View {
        SheetBox {
            Text(stage.title).font(.headline)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text(stage.text).fixedSize(horizontal: false, vertical: true)
                if let homeNote {
                    Text(homeNote).font(.caption2).foregroundStyle(.primary)
                        .accessibilityIdentifier("ap.sheet.home.\(stage.id)")
                }
                ForEach(stage.switches) { sw in SheetSwitchRow(row: sw, setSwitch: setSwitch) }
                if stage.id == "layout" { NewspaperLayoutDownloadRow().settingsLevel(.downloads) }
                if let forms = stage.forms {
                    SettingsLevelRows(.searchable, changed: !forms.entries.isEmpty,
                                      reset: { setStrings(.searchableFor, []) }) { formsRow(forms) }
                }
                SheetDisclosure("The rules in detail") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(stage.rules) { r in
                            Text("• \(r.text)" + (r.source.map { " (\($0))" } ?? ""))
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        if let s = stage.source {
                            Text("Source: \(s)").font(.caption2).foregroundStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ap.sheet.rule.\(stage.id)")
    }

    @ViewBuilder private func formsRow(_ forms: SettingsSheetModel.FormsRow) -> some View {
        SearchableFormatControls(forms: forms, setEntries: { setStrings(.searchableFor, $0) })
    }
}

private struct SearchableFormatControls: View {
    let forms: SettingsSheetModel.FormsRow
    let setEntries: ([String]) -> Void
    @State private var format = "*"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Write as one searchable page, with no text page").padding(.top, 4)
            Text("Search and select the reading on the page image. If the words cannot be placed, search still works "
                 + "but selections may not line up. Handwritten, mixed and register pages keep their separate text page. "
                 + "Searchable images use less space when the compression tools are available.")
                .font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Text(forms.source).font(.caption2).foregroundStyle(.primary)
            Picker("Input format", selection: $format) {
                ForEach(SettingsSheetModel.FormsRow.formats, id: \.self) { value in
                    Text(value == "*" ? "All formats" : value.uppercased()).tag(value)
                }
            }
            .accessibilityIdentifier("ap.sheet.forms.format")
            if format != "*", forms.all || SettingsSheetModel.FormsRow.kinds.contains(where: { forms.inherited($0, format: format) }) {
                Text("Choices checked and dimmed here come from All formats.")
                    .font(.caption2).foregroundStyle(.primary)
            }
            Toggle("Every page, pages of no known kind too",
                   isOn: Binding(get: { forms.isOn(format: format) || forms.inherited(format: format) },
                                 set: { setEntries(forms.settingAll($0, format: format)) }))
                .disabled(forms.inherited(format: format))
                .accessibilityIdentifier("ap.sheet.forms.all")
            ForEach(SettingsSheetModel.FormsRow.kinds, id: \.self) { kind in
                Toggle(kind.label,
                       isOn: Binding(get: { forms.isOn(kind, format: format) || forms.inherited(kind, format: format) },
                                     set: { setEntries(forms.setting(kind, $0, format: format)) }))
                    .disabled(forms.inherited(kind, format: format))
                    .padding(.leading, 16)
                    .accessibilityIdentifier("ap.sheet.forms.\(kind.rawValue)")
            }
            if !forms.others.isEmpty {
                Text("Other settings file entries: " + forms.others.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.sheet.forms")
    }
}

/// A disclosure drawn as a button (W47.settings-panels): SwiftUI's `DisclosureGroup` triangle carries no accessibility
/// action, which the audit fails now that the sheet's boxes sit in Settings.
struct SheetDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @State private var expanded = false

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                Label(title, systemImage: expanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded { content().padding(.leading, 18) }
        }
    }
}

/// A titled box drawn in SwiftUI alone (a `GroupBox` draws nothing offscreen, so the self-test could not see it).
struct SheetBox<Title: View, Content: View>: View {
    @ViewBuilder var title: () -> Title
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title()
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}

/// One stage's card.
struct StageCardView: View {
    let card: SettingsSheetModel.Card
    var choose: (String) -> Void
    var backToApp: () -> Void
    var apply: (SettingsSheetModel.Apply) -> Void
    /// Opens the Range view at this card's chart; nil draws no link.
    var seeRange: (() -> Void)? = nil
    /// Where the card's stage is set, in the modal sheet (W47.settings-panels).
    var homeNote: String? = nil
    /// W47.settings-level-switch: at Basic the card is the app's pick with its figures; choosing another route starts
    /// at Standard. A card already set by hand keeps its "Back to the app's pick" at every level.
    @AppStorage(DefaultsKeys.settingsLevel) private var levelRaw = SettingsLevel.defaultLevel.rawValue
    private var level: SettingsLevel { SettingsLevel(rawValue: levelRaw) ?? .defaultLevel }

    var body: some View {
        SheetBox {
            HStack {
                Text(card.title).font(.headline)
                Spacer()
                Text(card.weight).font(.caption).foregroundStyle(.primary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.about).font(.caption).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if let homeNote {
                    Text(homeNote).font(.caption2).foregroundStyle(.primary)
                        .accessibilityIdentifier("ap.sheet.home.\(card.id)")
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.routeName).font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    chip(card.family)
                    chip(card.isCustom ? "Custom" : "The app's pick", highlight: card.isCustom)
                }
                Text(card.why).fixedSize(horizontal: false, vertical: true)
                    .help(card.evidence)
                if let t = card.trainingCost {
                    Label { Text(t).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "lock.shield").foregroundStyle(.orange)
                    }
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(card.parts) { p in
                        GridRow {
                            Text(p.label).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 250, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                let figure = Text(p.figure + (p.routeName.map { $0 != card.routeName ? " — \($0)" : "" } ?? ""))
                                    .fixedSize(horizontal: false, vertical: true)
                                if p.warning {
                                    Label { figure } icon: {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    }
                                } else {
                                    figure
                                }
                                if let s = p.sample { Text(s).font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true) }
                                if let l = p.label2 {
                                    Text(l).font(.caption2).italic().foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                    GridRow { Text("Cost").foregroundStyle(.primary); Text(card.cost) }
                    GridRow { Text("Time").foregroundStyle(.primary); Text(card.time) }
                    GridRow { Text("Memory").foregroundStyle(.primary); Text(card.memory) }
                }
                .font(.callout)

                ForEach(card.labels, id: \.self) { l in
                    Label(l, systemImage: "info.circle").font(.caption).fixedSize(horizontal: false, vertical: true)
                }

                if let now = card.runsNow {
                    HStack(alignment: .firstTextBaseline) {
                        Text(now).font(.caption).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ap.sheet.current.\(card.id)")
                        if let a = card.apply {
                            Button(a.buttonTitle) { apply(a) }
                                .controlSize(.small)
                                .help("Changes what Process Files runs, for every collection.")
                                .accessibilityIdentifier("ap.sheet.apply.\(card.id)")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("What a better figure would need").font(.caption.weight(.semibold))
                    if card.better.isEmpty {
                        Text("Nothing measured does better here.").font(.caption)
                    }
                    ForEach(card.better) { b in
                        Text("\(Text(b.name).bold()) would give \(b.gain): \(b.reason).")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

                if !card.alternatives.isEmpty && level >= SettingsLevels.Row.overrides.level {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nearest alternatives you could use").font(.caption.weight(.semibold))
                        ForEach(card.alternatives) { a in
                            Text("\(a.name) (\(a.family)): \(a.figure), \(a.cost)")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack {
                    if level >= SettingsLevels.Row.overrides.level {
                        Menu("Use instead…") {
                            ForEach(card.options.filter { $0.level <= level || $0.id == card.routeID }) { o in
                                Button(o.blocked.map { "\(o.name) (\($0))" } ?? o.name) { choose(o.id) }
                                    .disabled(o.blocked != nil || o.id == card.routeID)
                            }
                        }
                        .fixedSize()
                        .accessibilityIdentifier("ap.sheet.override.\(card.id)")
                    }
                    if let seeRange {
                        Button("See the range") { seeRange() }
                            .buttonStyle(.link)
                            .help("Every measured route for this stage on one chart, with this card's pick marked.")
                            .accessibilityIdentifier("ap.sheet.seeRange.\(card.id)")
                    }
                    if card.isCustom || card.hasOverride {
                        Button(card.isCustom ? "Back to the app's pick" + (card.appPick.map { " (\($0))" } ?? "")
                               : "Clear an old choice") { backToApp() }
                            .help("Clears your choice for this card here and wherever it was set (a project or your general settings).")
                            .accessibilityIdentifier("ap.sheet.reset.\(card.id)")
                    }
                }

                SheetDisclosure("Notes from the measurements") {
                    VStack(alignment: .leading, spacing: 3) {
                        if !card.evidence.isEmpty {
                            Text(card.evidence).font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(card.caveats, id: \.self) {
                            Text("• \($0)").font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Figures from: " + card.sources.joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ap.sheet.card.\(card.id)")
    }

    private func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(highlight ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15)))
    }
}

extension SettingsSheetModel.Apply {
    var buttonTitle: String {
        switch self {
        case .segmentation: return "Use this in Process Files"
        case .reading, .readingByPlan, .appleVision: return "Read with this"
        }
    }
}
