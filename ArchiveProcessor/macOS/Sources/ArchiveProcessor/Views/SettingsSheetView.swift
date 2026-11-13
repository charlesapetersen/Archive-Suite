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

    @ObservedObject private var store = SettingsLayerStore.shared
    @AppStorage(DefaultsKeys.segmentationApproach) private var segmentationRaw = SegmentationApproach.defaultApproach.rawValue
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision = false
    @AppStorage(DefaultsKeys.useGateway) private var useGateway = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent = false
    @AppStorage(DefaultsKeys.batchMode) private var batchMode = false
    @ObservedObject private var modelStore = ModelSelectionStore.shared

    @State private var tab: Tab = .choices
    @State private var doc: CollectionSettingsDocument?
    @State private var problem: String?

    private var resolver: SettingsResolver { store.resolver(for: doc) }

    static func running(segmentation: SegmentationApproach, useAppleVision: Bool, useGateway: Bool,
                        useLocalAgent: Bool, provider: LLMProvider, model: LLMModel,
                        table: SettingsRouteTable?) -> SettingsSheetModel.Running {
        if useAppleVision {
            return .init(readingRouteID: "apple-vision", readingName: "Apple Vision on this Mac", segmentation: segmentation)
        }
        if useLocalAgent {
            return .init(readingRouteID: nil, readingName: "your signed-in command-line agent", segmentation: segmentation)
        }
        if useGateway {
            return .init(readingRouteID: nil, readingName: "the model on your API gateway", segmentation: segmentation)
        }
        let route = "\(provider.rawValue.lowercased())|\(model.id)"
        let id = table?.stage("reading")?.routes.first { $0.appRoute == route }?.id
        return .init(readingRouteID: id, readingName: model.displayName, segmentation: segmentation)
    }

    private var model: SettingsSheetModel? {
        guard let table = SettingsRouteTable.bundled, table.problems().isEmpty else { return nil }
        let running = Self.running(
            segmentation: SegmentationApproach(rawValue: segmentationRaw) ?? .defaultApproach,
            useAppleVision: useAppleVision, useGateway: useGateway, useLocalAgent: useLocalAgent,
            provider: selectedProvider, model: modelStore.model(for: selectedProvider), table: table)
        return SettingsSheetModel(table: table, pairs: OCRPairMatrix.bundled, resolver: resolver,
                                  macMemoryGB: SettingsLayerStore.thisMacMemoryGB, pages: pages,
                                  month: store.monthSpend(), running: running)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let model {
                ScrollView {
                    SettingsSheetPage(model: model, tab: tab, choose: choose, apply: apply, setSwitch: setSwitch)
                }
            } else {
                Text("The measured figures are missing from this build, so the settings sheet cannot be shown.")
                    .padding(24)
                Spacer()
            }
            Divider()
            HStack {
                if let message = problem ?? store.lastProblem {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ap.sheet.done")
            }
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 720)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.sheet")
        .onAppear {
            tab = initialTab
            reload()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings for \(outputFolder?.lastPathComponent ?? "new collections")").font(.title3.weight(.semibold))
                Text("The app's choices for your answers and your Mac, \(pagesCaption). Every figure was measured on test "
                     + "pages and says how many.")
                    .font(.caption).foregroundStyle(.secondary)
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

    // MARK: Writing

    private var writer: SettingsSheetWriter { SettingsSheetWriter(store: store, folder: outputFolder) }

    /// A card's override, or the way back (nil). Process Files' own choice changes only by the card's Use button.
    private func choose(_ stage: String, _ routeID: String?) {
        let key = SettingsSheetModel.overrideKey(stage)
        take(routeID.map { writer.set(key, .string($0), doc: doc) } ?? writer.clear(key, doc: doc))
    }

    private func setSwitch(_ key: SettingsKey, _ on: Bool) { take(writer.set(key, .bool(on), doc: doc)) }

    private func take(_ outcome: SettingsSheetWriter.Outcome) {
        doc = outcome.doc
        problem = outcome.ok ? nil : (store.lastProblem ?? "The change could not be saved.")
    }

    private func apply(_ a: SettingsSheetModel.Apply) {
        switch a {
        case .segmentation(let approach):
            segmentationRaw = approach.rawValue
        case .appleVision:
            useGateway = false
            useLocalAgent = false
            useAppleVision = true
            batchMode = false
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
        SheetBox {
            Text("Your limits").font(.headline)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(m.limits) { l in
                        GridRow {
                            Text(l.label).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(l.value).fixedSize(horizontal: false, vertical: true)
                                Text(l.source).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Change these with “Questions about this material” in Settings.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ap.sheet.limits")

        HStack(alignment: .top, spacing: 8) {
            ForEach(m.totals) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.label).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(t.value).font(.title3.weight(.semibold))
                    if let d = t.detail {
                        Text(d).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

        ForEach(m.cards) { card in
            StageCardView(card: card, choose: { choose(card.id, $0) }, backToApp: { choose(card.id, nil) },
                          apply: apply)
        }
    }

    // MARK: Rules

    @ViewBuilder private func rules(_ m: SettingsSheetModel) -> some View {
        Text("These steps were measured and have no trade-off to choose: every option tried was the same or worse. "
             + "They run the same way for every collection; a switch is shown only where one is offered.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(m.ruleStages) { stage in
            SheetBox {
                Text(stage.title).font(.headline)
            } content: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stage.text).fixedSize(horizontal: false, vertical: true)
                    ForEach(stage.switches) { sw in
                        Toggle(isOn: Binding(get: { sw.isOn }, set: { setSwitch(sw.key, $0) })) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(sw.label)
                                Text(sw.source).font(.caption2).foregroundStyle(.secondary)
                                if let note = sw.note {
                                    Text(note).font(.caption2).italic().foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .accessibilityIdentifier("ap.sheet.switch.\(sw.id)")
                    }
                    DisclosureGroup("The rules in detail") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(stage.rules) { r in
                                Text("• \(r.text)" + (r.source.map { " (\($0))" } ?? ""))
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                            if let s = stage.source {
                                Text("Source: \(s)").font(.caption2).foregroundStyle(.secondary)
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

    var body: some View {
        SheetBox {
            HStack {
                Text(card.title).font(.headline)
                Spacer()
                Text(card.weight).font(.caption).foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.about).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.routeName).font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    chip(card.family)
                    chip(card.isCustom ? "Custom" : "The app's pick", highlight: card.isCustom)
                }
                Text(card.why).fixedSize(horizontal: false, vertical: true)
                    .help(card.evidence)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(card.parts) { p in
                        GridRow {
                            Text(p.label).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 250, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.figure + (p.routeName.map { $0 != card.routeName ? " — \($0)" : "" } ?? ""))
                                    .foregroundStyle(p.warning ? Color.orange : Color.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let s = p.sample { Text(s).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                if let l = p.label2 {
                                    Text(l).font(.caption2).italic().foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                    GridRow { Text("Cost").foregroundStyle(.secondary); Text(card.cost) }
                    GridRow { Text("Time").foregroundStyle(.secondary); Text(card.time) }
                    GridRow { Text("Memory").foregroundStyle(.secondary); Text(card.memory) }
                }
                .font(.callout)

                ForEach(card.labels, id: \.self) { l in
                    Label(l, systemImage: "info.circle").font(.caption).fixedSize(horizontal: false, vertical: true)
                }

                if let now = card.runsNow {
                    HStack(alignment: .firstTextBaseline) {
                        Text(now).font(.caption).fixedSize(horizontal: false, vertical: true)
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

                if !card.alternatives.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nearest alternatives you could use").font(.caption.weight(.semibold))
                        ForEach(card.alternatives) { a in
                            Text("\(a.name) (\(a.family)): \(a.figure), \(a.cost)")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack {
                    Menu("Use instead…") {
                        ForEach(card.options) { o in
                            Button(o.blocked.map { "\(o.name) (\($0))" } ?? o.name) { choose(o.id) }
                                .disabled(o.blocked != nil || o.id == card.routeID)
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("ap.sheet.override.\(card.id)")
                    if card.isCustom || card.hasOverride {
                        Button(card.isCustom ? "Back to the app's pick" + (card.appPick.map { " (\($0))" } ?? "")
                               : "Clear an old choice") { backToApp() }
                            .help("Clears your choice for this card here and wherever it was set (a project or your general settings).")
                            .accessibilityIdentifier("ap.sheet.reset.\(card.id)")
                    }
                }

                DisclosureGroup("Notes from the measurements") {
                    VStack(alignment: .leading, spacing: 3) {
                        if !card.evidence.isEmpty {
                            Text(card.evidence).font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(card.caveats, id: \.self) {
                            Text("• \($0)").font(.caption2).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Figures from: " + card.sources.joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        case .reading, .appleVision: return "Read with this"
        }
    }
}
