import SwiftUI
import UniformTypeIdentifiers

/// "Compare routes & trade-offs…" (W49.proc-settings-advisor-advanced, `processor-settings-redesign.md` §5.6): the
/// optional Advisor sheet over the pruned route table. Opened from Settings › Processing's estimate footer, its collection
/// questions, Process Files' segmentation chooser, and after the first files of a new collection. Its inputs are the
/// answers the collection interview used to ask; the stage rows and the Range charts follow them at once; nothing is
/// written until Save answers or Apply (`SettingsAdvisor`).
struct SettingsAdvisorSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case advisor = "Advisor", range = "Range"
        var id: String { rawValue }
    }

    let target: SettingsAdvisor.Target
    /// Files already chosen for the batch, measured without asking for them again.
    var files: [URL] = []
    /// The batch the figures are for, until the user changes it.
    var pages: Int = 1000
    var initialTab: Tab = .advisor
    var onDone: () -> Void

    @ObservedObject private var store = SettingsLayerStore.shared
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    @ObservedObject private var claudeUsage = ClaudeCLIUsage.shared
    @AppStorage(DefaultsKeys.segmentationApproach) private var segmentationRaw = SegmentationApproach.defaultApproach.rawValue
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision = false
    @AppStorage(DefaultsKeys.useGateway) private var useGateway = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent = false
    @AppStorage(DefaultsKeys.localAgentTool) private var localAgentToolRaw = LocalAgentTool.claude.rawValue
    @AppStorage(DefaultsKeys.localAgentBinaryPath) private var localAgentBinaryPath = ""
    @AppStorage(DefaultsKeys.localAgentModel) private var localAgentModel = ""
    @AppStorage(OpenRouterListing.defaultsKey) private var openRouterListingData: Data?

    @State private var tab: Tab = .advisor
    @State private var loaded = false
    @State private var doc: CollectionSettingsDocument?
    @State private var draft = SettingsAdvisor.Draft(answers: CollectionInterviewAnswers(), pages: 1000)
    @State private var problem: String?
    @State private var applying = false
    @State private var measuring = false
    @State private var measuredCount = 0
    @State private var measureTotal = 0
    @State private var pickedFiles: [URL]?
    @State private var measureTask: Task<Void, Never>?

    private var base: SettingsResolver { SettingsAdvisor.baseResolver(target, store: store, doc: doc) }

    private var claudeBinary: String? {
        ClaudeCLIBilling.binaryPath(tool: LocalAgentTool(rawValue: localAgentToolRaw) ?? .claude, override: localAgentBinaryPath)
    }

    private var model: SettingsSheetModel? {
        guard loaded, let table = SettingsRouteTable.bundled, table.problems().isEmpty else { return nil }
        _ = openRouterListingData
        let billing = claudeUsage.billing(for: claudeBinary)
        var running = SettingsAdvisor.running(
            segmentation: SegmentationApproach(rawValue: segmentationRaw) ?? .defaultApproach,
            useAppleVision: useAppleVision, useGateway: useGateway, useLocalAgent: useLocalAgent,
            provider: selectedProvider, model: modelStore.model(for: selectedProvider), table: table,
            localAgentTool: LocalAgentTool(rawValue: localAgentToolRaw) ?? .claude, localAgentModel: localAgentModel,
            appleVisionModelID: modelStore.model(for: .appleVision).id, claudeBilling: billing)
        if !useAppleVision, !useGateway, !useLocalAgent,
           let warning = modelStore.unavailableOpenRouterSelection(for: selectedProvider) {
            running.readingRouteID = nil
            running.unavailableModelWarning = warning
        }
        return SettingsSheetModel(table: table, pairs: OCRPairMatrix.bundled,
                                  resolver: SettingsAdvisor.resolver(base, target: target, draft: draft),
                                  macMemoryGB: SettingsLayerStore.thisMacMemoryGB, pages: draft.pages,
                                  month: store.monthSpend(), running: running, claudeBilling: billing)
    }

    private var projectName: String? {
        switch target {
        case .project(let id): return store.project(id)?.name
        default: return nil
        }
    }

    var body: some View {
        let m = model
        VStack(spacing: 0) {
            header
            Divider()
            if let m {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if tab == .advisor { inputs }
                        SettingsAdvisorPage(model: m, tab: tab, choose: choose)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if loaded {
                Text("The measured figures are missing from this build, so the Advisor cannot be shown.")
                    .padding(24)
                Spacer()
            } else {
                Spacer()
            }
            Divider()
            footer(m)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 680)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.advisor")
        .onAppear(perform: load)
        .task(id: pickedFiles) {
            guard let urls = pickedFiles else { return }
            defer { pickedFiles = nil }
            guard await CloudDriveWarning.confirmUse(of: urls) else { return }
            measure(urls, expandFolders: true)
        }
        .onDisappear {
            pickedFiles = nil
            measureTask?.cancel()
        }
    }

    private func load() {
        guard !loaded else { return }
        tab = initialTab
        if case .collection(let folder) = target {
            switch CollectionSettingsFile.read(in: folder) {
            case .document(let d): doc = d
            case .missing: doc = nil
            case .unreadable:
                problem = "This collection's settings file could not be read. It will be set aside, not deleted, when you save."
            case .refused(let e): problem = "This collection's settings were left alone: \(e.description)."
            }
        }
        draft = SettingsAdvisor.draft(target, base: base, pages: pages)
        loaded = true
        if draft.answers.measuredShares.isEmpty, !files.isEmpty { measure(files) }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsAdvisor.title(target, projectName: projectName)).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Answer what you know about this material: the app's picks follow at once. Nothing is saved until "
                     + "Save answers or Apply. Every figure was measured on test pages and says how many.")
                    .font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .accessibilityIdentifier("ap.advisor.tab")
        }
        .padding(16)
    }

    private func footer(_ m: SettingsSheetModel?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = problem ?? store.lastProblem {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Link("The full research benchmark and how it was measured",
                     destination: URL(string: "https://claude.ai/artifact/LGb43P7kewBvqXJ6Kiwd41")!)
                    .font(.caption)
                    .help("ArchiveOCRBench: every route measured, including the ones the app does not run.")
                    .accessibilityIdentifier("ap.advisor.bench")
                Spacer()
                Button("Cancel") { measureTask?.cancel(); onDone() }
                    .keyboardShortcut(.cancelAction)
                    .help("Saves nothing.")
                    .accessibilityIdentifier("ap.advisor.cancel")
                Button("Save answers") { saveAnswers() }
                    .disabled(measuring || pickedFiles != nil || applying)
                    .help("Saves your answers about this material and leaves every reader and choice as it is.")
                    .accessibilityIdentifier("ap.advisor.save")
                Button(SettingsAdvisor.applyTitle(target)) { if let m { apply(m) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(m == nil || measuring || pickedFiles != nil || applying)
                    .help("Saves your answers and the choices shown, and switches on what Process Files runs for them.")
                    .accessibilityIdentifier("ap.advisor.apply")
            }
        }
        .padding(12)
    }

    // MARK: Inputs

    private var habit: MoneyHabit {
        SettingsResolver(general: store.general).resolve(.moneyHabit).value.string.flatMap(MoneyHabit.init(rawValue:)) ?? .none
    }

    /// The layers above the target, for "Use inherited limit".
    private var inheritedResolver: SettingsResolver {
        switch target {
        case .collection: return SettingsResolver(general: store.general, project: base.project)
        case .project: return SettingsResolver(general: store.general)
        case .general: return SettingsResolver(general: SettingsLayer(kind: .general, name: "General"))
        }
    }

    private enum BatchLimit: Hashable { case inherited, unlimited, amount }

    private var batchLimit: Binding<BatchLimit> {
        Binding {
            guard draft.answers.isAnswered(.batchCeilingUSD) else { return .inherited }
            return draft.answers.noBatchCeiling ? .unlimited : .amount
        } set: { limit in
            draft.answers.noBatchCeiling = limit == .unlimited
            if limit == .inherited {
                draft.answers.inheritBatchCeiling()
                draft.answers.batchCeilingUSD = inheritedResolver.batchSpendingCapUSD ?? 0
            } else {
                draft.answers.touch(.batchCeilingUSD)
            }
        }
    }

    private func bind<T>(_ path: WritableKeyPath<CollectionInterviewAnswers, T>, _ key: SettingsKey) -> Binding<T> {
        Binding(get: { draft.answers[keyPath: path] }, set: { draft.answers[keyPath: path] = $0; draft.answers.touch(key) })
    }

    /// A value the public test sets are derived from: the mix is written with it.
    private func derives<T>(_ path: WritableKeyPath<CollectionInterviewAnswers, T>, _ key: SettingsKey) -> Binding<T> {
        Binding(get: { draft.answers[keyPath: path] },
                set: { draft.answers[keyPath: path] = $0; draft.answers.touch(key); draft.answers.touch(.mix) })
    }

    private var inputs: some View {
        SheetBox {
            Text("About this batch and this material").font(.headline)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Batch pages")
                        HStack {
                            TextField("Batch pages", value: Binding(get: { draft.pages }, set: { draft.pages = max(1, $0) }),
                                      format: .number)
                                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("ap.advisor.pages")
                            Text("for the figures below; not saved").font(.caption2).foregroundStyle(.primary)
                        }
                    }
                    GridRow {
                        Text("Most to spend on a batch")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Picker("Most to spend on a batch", selection: batchLimit) {
                                    Text(target == .general ? "Use the default" : "Use inherited limit").tag(BatchLimit.inherited)
                                    Text("No limit").tag(BatchLimit.unlimited)
                                    Text("Set an amount").tag(BatchLimit.amount)
                                }
                                .labelsHidden().fixedSize()
                                .accessibilityIdentifier("ap.advisor.batchLimit")
                                if batchLimit.wrappedValue == .amount {
                                    TextField("Most to spend", value: bind(\.batchCeilingUSD, .batchCeilingUSD),
                                              format: .currency(code: "USD"))
                                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 100)
                                        .multilineTextAlignment(.trailing)
                                        .accessibilityIdentifier("ap.advisor.batchCeiling")
                                }
                            }
                            if let note = limitNote {
                                Text(note).font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    GridRow {
                        Text("How long it may run")
                        Stepper(value: bind(\.hours, .hours), in: 1...168) {
                            Text(draft.answers.hours == 1 ? "1 hour" : "\(Int(draft.answers.hours)) hours")
                        }
                        .accessibilityIdentifier("ap.advisor.hours")
                    }
                    GridRow {
                        Text("Kinds of document")
                        kindsRow
                    }
                    GridRow {
                        Text("When two choices are close")
                        Picker("When two choices are close", selection: bind(\.preference, .preference)) {
                            Text("Best accuracy").tag(SettingsPreference.bestMeasured)
                            Text("Cheapest within 1 pt").tag(SettingsPreference.cheapestWithinPoint)
                            Text("Fastest within 1 pt").tag(SettingsPreference.fastestWithinPoint)
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                        .accessibilityIdentifier("ap.advisor.preference")
                    }
                }
                SheetDisclosure("Change the shares of each kind", identifier: "ap.advisor.shares") { sharesRows }
                SheetDisclosure("More about this material: period, languages, what matters most",
                                identifier: "ap.advisor.more") { moreRows }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ap.advisor.inputs")
    }

    private var limitNote: String? {
        if habit == .none {
            return "Settings › Processing's spending limit is Spend nothing, so this has no effect until it is changed there."
        }
        var parts: [String] = []
        if batchLimit.wrappedValue == .inherited {
            parts.append(inheritedResolver.batchSpendingCapUSD.map { "Inherited: " + $0.formatted(.currency(code: "USD")) }
                         ?? "No inherited limit.")
        }
        if habit == .perMonth { parts.append("Your monthly limit still applies.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    @ViewBuilder private var kindsRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(SettingsAdvisor.mixSummary(draft.answers))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.advisor.mix")
                Spacer()
                if measuring {
                    if measureTotal == 0 {
                        ProgressView().controlSize(.small)
                        Text("Finding pages…").font(.caption)
                    } else {
                        ProgressView(value: Double(measuredCount), total: Double(measureTotal)).frame(width: 80)
                        Text("\(measuredCount) of \(measureTotal)").font(.caption).monospacedDigit()
                    }
                    Button("Stop") { measureTask?.cancel() }.controlSize(.small)
                } else {
                    Button(draft.answers.measurement == nil ? "Measure from files…" : "Measure again…") { chooseFiles() }
                        .controlSize(.small)
                        .disabled(pickedFiles != nil)
                        .help("Looks at up to \(KindMeasurement.sampleLimit) photos and PDF pages on this Mac to tell typed, printed, handwritten and form pages apart. Nothing is sent anywhere.")
                        .accessibilityIdentifier("ap.advisor.measure")
                }
            }
            Text(measurementText).font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var measurementText: String {
        let a = draft.answers
        if let from = a.mixInheritedFrom { return "These shares come from \(from). Measure this material to replace them." }
        guard let m = a.measurement else {
            return a.measuredShares.isEmpty ? "Not measured yet." : "You gave these shares."
        }
        var s = "Measured on \(m.sample) page\(m.sample == 1 ? "" : "s")"
        if m.unsure > 0 { s += "; \(m.unsure) of them unsure" }
        if m.unknown > 0 { s += "; \(m.unknown) could not be read" }
        s += ". On the app's test pages it named the kind rightly on \(KindMeasurement.ownerRight) of \(KindMeasurement.ownerPages)."
        if a.correctedMix { s += " You have corrected the shares." }
        return s
    }

    @ViewBuilder private var sharesRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(CollectionInterviewAnswers.measuredKinds, id: \.self) { kind in
                percentRow(PageKindName.label(kind), id: kind, value: Binding(
                    get: { draft.answers.measuredShares[kind] ?? 0 },
                    set: { draft.answers.measuredShares[kind] = $0; draft.answers.correctedMix = true; draft.answers.touch(.mix) }))
            }
            ForEach(CollectionInterviewAnswers.unmeasuredKinds, id: \.self) { kind in
                percentRow(CollectionInterviewAnswers.unmeasuredLabel(kind), id: kind, note: "not measured", value: Binding(
                    get: { draft.answers.unmeasuredShares[kind] ?? 0 },
                    set: { draft.answers.unmeasuredShares[kind] = $0; draft.answers.touch(.mix) }))
            }
            Text("Percent of the pages. The kinds marked “not measured” cannot be told by the app, so give your own estimate; registers are judged with forms and tables.")
                .font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percentRow(_ label: String, id: String, note: String? = nil, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label)
            if let note { Text(note).font(.caption2).foregroundStyle(.primary) }
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 60)
                .accessibilityIdentifier("ap.advisor.share.\(id)")
            Text("%")
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder private var moreRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Start from", selection: Binding(get: { draft.answers.startingPoint },
                                                        set: { if let p = $0 { draft.answers.fill(p) } })) {
                    Text("Choose…").tag(SettingsStartingPoint?.none)
                    ForEach(SettingsStartingPoint.allCases, id: \.self) { Text($0.name).tag(SettingsStartingPoint?.some($0)) }
                }
                .fixedSize()
                .help("A starting point only fills in the limits above; change any of them afterwards.")
            }
            if let point = draft.answers.startingPoint {
                Text(point.summary).font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            if draft.answers.filled.contains(SettingsKey.batchCeilingUSD.rawValue),
               let note = CollectionInterviewAnswers.moneyNote(point: draft.answers.startingPoint, habit: habit) {
                Text(note).font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text("Period")
                TextField("from", value: derives(\.periodFrom, .period), format: .number.grouping(.never))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
                Text("to")
                TextField("to", value: derives(\.periodTo, .period), format: .number.grouping(.never))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
            }
            SheetDisclosure("Languages: \(languageSummary)") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CollectionInterviewAnswers.languageChoices, id: \.code) { choice in
                        Toggle(choice.label, isOn: Binding(
                            get: { draft.answers.languages.contains(choice.code) },
                            set: { on in
                                draft.answers.languages.removeAll { $0 == choice.code }
                                if on { draft.answers.languages.append(choice.code) }
                                draft.answers.touch(.languages); draft.answers.touch(.mix)
                            }))
                    }
                }
            }
            SheetDisclosure("Writing: \(scriptSummary)") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach([CollectionScript.kurrent, .fraktur], id: \.self) { s in
                        Toggle(s.label, isOn: Binding(
                            get: { draft.answers.latinForms.contains(s) },
                            set: {
                                if $0 { draft.answers.latinForms.insert(s) } else { draft.answers.latinForms.remove(s) }
                                draft.answers.touch(.scripts); draft.answers.touch(.mix)
                            }))
                    }
                    ForEach(CollectionScript.allCases.filter { !$0.isLatinForm }, id: \.self) { s in
                        percentRow(s.label, id: "script.\(s.rawValue)", value: Binding(
                            get: { draft.answers.scriptShares[s] ?? 0 },
                            set: { draft.answers.scriptShares[s] = $0; draft.answers.touch(.scripts); draft.answers.touch(.mix) }))
                    }
                }
            }
            Text(judgedOnText).font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Text("What matters most").font(.callout.weight(.semibold)).padding(.top, 4)
            ForEach(Array(draft.answers.order.enumerated()), id: \.element) { i, p in
                HStack {
                    Text("\(i + 1).").monospacedDigit()
                    Text(CollectionInterviewAnswers.priorityLabel(p))
                    Spacer()
                    TextField("weight", value: Binding(get: { draft.answers.weights[p] ?? 0 },
                                                       set: { draft.answers.weights[p] = max(0, $0); draft.answers.touch(.priorities) }),
                              format: .number.precision(.fractionLength(0)))
                        .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 50)
                        .accessibilityIdentifier("ap.advisor.weight.\(p.rawValue)")
                    Button { draft.answers.move(p, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(i == 0)
                        .accessibilityLabel("Move \(CollectionInterviewAnswers.priorityLabel(p)) up")
                    Button { draft.answers.move(p, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(i == draft.answers.order.count - 1)
                        .accessibilityLabel("Move \(CollectionInterviewAnswers.priorityLabel(p)) down")
                }
                .frame(maxWidth: 480)
            }
            Text("The numbers say how much each one counts when money or time has to be shared out; 0 leaves it out. Names are only looked for when they count.")
                .font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Stepper(value: bind(\.checkingMinutes, .checkingMinutes), in: 0...600, step: 5) {
                Text("Minutes you will spend checking where documents begin: \(Int(draft.answers.checkingMinutes))")
            }
            .help("The app asks you to look at the places it is least sure one document ends and the next begins. More minutes, fewer mistakes.")
        }
    }

    private var languageSummary: String {
        let names = draft.answers.languages.compactMap { c in CollectionInterviewAnswers.languageChoices.first { $0.code == c }?.label }
        return names.isEmpty ? "not given" : names.joined(separator: ", ")
    }

    private var scriptSummary: String {
        let a = draft.answers
        var parts = a.latinForms.sorted { $0.rawValue < $1.rawValue }.map(\.label)
        parts += a.scriptShares.filter { $0.value > 0 }.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.label) \(String(format: "%g", $0.value))%" }
        return parts.isEmpty ? "the Latin alphabet" : parts.joined(separator: ", ")
    }

    private var judgedOnText: String {
        let strata = draft.answers.mixAndStrata().strata.keys.sorted()
        guard !strata.isEmpty else {
            return "Your pages are judged on the app's own measured pages (English, 20th century, Latin alphabet)."
        }
        return "Some of your pages are judged on public test pages: " + strata.map { PublicStratum.label($0) }.joined(separator: "; ") + "."
    }

    // MARK: Choosing, saving and applying

    /// A stage row's or a range mark's choice: a route, or the app's pick again (nil).
    private func choose(_ stage: String, _ routeID: String?) {
        draft.choices[stage] = routeID.map(SettingsAdvisor.Choice.route) ?? .appPick
    }

    private func saveAnswers() {
        let out = SettingsAdvisor.save(draft, to: target, store: store, doc: doc, choices: false)
        doc = out.doc
        if out.ok { onDone() } else { problem = out.problem }
    }

    private func apply(_ m: SettingsSheetModel) {
        let changes = SettingsAdvisor.runChanges(m)
        let out = SettingsAdvisor.save(draft, to: target, store: store, doc: doc, choices: true)
        doc = out.doc
        guard out.ok else { problem = out.problem; return }
        var plan: String?
        for change in changes {
            if case .readingByPlan(let model) = change { plan = model } else { SettingsAdvisor.applyRun(change) }
        }
        guard let plan else { onDone(); return }
        // The plan is switched on only once Claude Code's subscription sign-in is confirmed.
        applying = true
        let binary = claudeBinary
        Task {
            let billing = await claudeUsage.refresh(binary: binary, force: true)
            applying = false
            guard binary == claudeBinary, billing == .subscription else {
                problem = "Your answers and choices are saved, but Claude Code's subscription sign-in could not be confirmed, so the reader is unchanged. Check its sign-in in Settings › Accounts."
                return
            }
            SettingsAdvisor.applyRun(.readingByPlan(model: plan))
            onDone()
        }
    }

    // MARK: Measuring

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf, .folder]
        panel.prompt = "Measure"
        panel.message = "Choose photos, PDFs or a folder of files to measure."
        guard panel.runModal() == .OK else { return }
        pickedFiles = panel.urls
    }

    private func measure(_ urls: [URL], expandFolders: Bool = false) {
        problem = nil
        measuring = true
        measuredCount = 0
        measureTotal = 0
        measureTask = Task {
            defer { measuring = false }
            let sampling = Task.detached(priority: .utility) {
                KindMeasurement.sample(expandFolders ? KindMeasurement.inputFiles(in: urls) : urls)
            }
            let sample = await withTaskCancellationHandler {
                await sampling.value
            } onCancel: {
                sampling.cancel()
            }
            guard !Task.isCancelled else { return }
            guard !sample.isEmpty else {
                problem = "No readable PDF pages or supported photos (JPEG, PNG, HEIC or TIFF) were found."
                return
            }
            measureTotal = sample.count
            var kinds: [PageKind?] = []
            for page in sample {
                if Task.isCancelled { return }
                let kind = await Task.detached(priority: .utility) { await page.classify() }.value
                kinds.append(kind)
                measuredCount = kinds.count
            }
            guard !Task.isCancelled else { return }
            let m = KindMeasurement.tally(kinds)
            if m.counts.isEmpty {
                if #available(macOS 26, *) {
                    problem = "The app could not tell the kind of document on any of the sampled pages."
                } else {
                    problem = "Measuring kinds of document requires macOS 26 or later."
                }
            } else {
                draft.answers.take(m)
            }
        }
    }
}

/// The Advisor's page for one tab, from a model alone, so the self-test renders exactly what the sheet draws: this
/// batch's totals and the four stage rows, or the Range charts.
struct SettingsAdvisorPage: View {
    let model: SettingsSheetModel
    let tab: SettingsAdvisorSheet.Tab
    var choose: (String, String?) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tab {
            case .advisor: advisor
            case .range: SettingsRangeTab(model: model, choose: choose)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var advisor: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(model.totals) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.label).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Text(t.value).font(.title3.weight(.semibold))
                    if let d = t.detail {
                        Text(d).font(.caption2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ap.advisor.totals")
        if !model.toRelax.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("To do better").font(.caption.weight(.semibold))
                ForEach(model.toRelax, id: \.self) { Text("• \($0)").font(.caption).fixedSize(horizontal: false, vertical: true) }
            }
        }
        if let words = SettingsAdvisor.runChangeWords(model) {
            Label("Apply also switches what Process Files runs, on this Mac for every collection: \(words).",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ap.advisor.runChanges")
        }
        ForEach(model.cards) { card in
            AdvisorStageRow(card: card, choose: { choose(card.id, $0) })
        }
    }
}

/// One stage's row: the pick with its measured figure, cost and time, the next step up, and a way to choose another.
struct AdvisorStageRow: View {
    let card: SettingsSheetModel.Card
    var choose: (String?) -> Void
    /// The Advanced route rows are listed while Settings › Advanced offers them, and the row's own choice always.
    @AppStorage(DefaultsKeys.offerExperimentalRoutes) private var offerExperimental = false
    private var tier: RouteTier { offerExperimental ? .advanced : .standard }

    var body: some View {
        SheetBox {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title).font(.headline)
                Spacer()
                Text(card.weight).font(.caption)
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(card.routeName).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    chip(card.family)
                    chip(card.isCustom ? "Your choice" : "The app's pick", highlight: card.isCustom)
                }
                ForEach(card.parts) { p in
                    let figure = "\(p.label): \(p.figure)" + (p.routeName.map { $0 != card.routeName ? " — \($0)" : "" } ?? "")
                    if p.warning {
                        Label { Text(figure).fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.callout)
                    } else {
                        Text(figure).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Cost \(card.cost) · Time \(card.time) · Memory \(card.memory)").font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let trainingCost = card.trainingCost {
                    Label { Text(trainingCost).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "lock.shield").foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
                Text(nextStep).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.advisor.next.\(card.id)")
                if let now = card.runsNow {
                    Text(now).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ap.advisor.now.\(card.id)")
                }
                HStack {
                    Menu("Use instead…") {
                        ForEach(card.options.filter { $0.tier <= tier || $0.id == card.routeID }) { o in
                            Button(o.blocked.map { "\(o.name) (\($0))" } ?? o.name) { choose(o.id) }
                                .disabled(o.blocked != nil || o.id == card.routeID)
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("ap.advisor.override.\(card.id)")
                    if card.isCustom || card.hasOverride {
                        Button(card.isCustom ? "Back to the app's pick" + (card.appPick.map { " (\($0))" } ?? "")
                               : "Clear an old choice") { choose(nil) }
                            .help("On Apply, clears your choice for this step here and wherever it was set (a project or your general defaults).")
                            .accessibilityIdentifier("ap.advisor.reset.\(card.id)")
                    }
                    Spacer()
                }
                SheetDisclosure("Why, and the measurements", identifier: "ap.advisor.details.\(card.id)") { details }
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("ap.advisor.stage.\(card.id)")
    }

    /// "Next step up: X would give +2.1 points: raise the ceiling by $1.20."
    private var nextStep: String {
        guard let b = card.better.first else { return "Next step up: nothing measured does better here." }
        return "Next step up: \(b.name) would give \(b.gain): \(b.reason)."
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.about).fixedSize(horizontal: false, vertical: true)
            Text(card.why).fixedSize(horizontal: false, vertical: true)
            if card.better.count > 1 {
                ForEach(card.better.dropFirst()) { b in
                    Text("• \(b.name) would give \(b.gain): \(b.reason).").fixedSize(horizontal: false, vertical: true)
                }
            }
            if !card.alternatives.isEmpty {
                Text("Nearest alternatives you could use").font(.caption.weight(.semibold))
                ForEach(card.alternatives) { a in
                    Text("\(a.name) (\(a.family)): \(a.figure), \(a.cost)").fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(card.labels, id: \.self) { Text("• \($0)").fixedSize(horizontal: false, vertical: true) }
            if !card.evidence.isEmpty { Text(card.evidence).font(.caption2).fixedSize(horizontal: false, vertical: true) }
            ForEach(card.caveats, id: \.self) { Text("• \($0)").font(.caption2).fixedSize(horizontal: false, vertical: true) }
            Text("Figures from: " + card.sources.joined(separator: ", ")).font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(highlight ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15)))
    }
}

/// A button that opens the Advisor for Process Files' output folder (the collection), scaled to `pages`.
struct SettingsAdvisorButton: View {
    let title: String
    let pages: Int
    var initialTab: SettingsAdvisorSheet.Tab = .advisor
    @State private var showing = false

    /// The folder Process Files writes into, resolved as it resolves it.
    static func outputFolder() -> URL? {
        #if DEBUG
        if let folder = ProcessorUITestConfiguration.outputDirectory { return folder }
        #endif
        return ModelSelectionStore.savedOutputDirectory()
    }

    var body: some View {
        Button(title) { showing = true }
            .sheet(isPresented: $showing) {
                SettingsAdvisorSheet(target: Self.outputFolder().map(SettingsAdvisor.Target.collection) ?? .general,
                                     pages: max(1, pages), initialTab: initialTab) { showing = false }
            }
    }
}
