import SwiftUI
import ArchiveCore

/// Settings › Processing (W49.proc-settings-redesign-core, `processor-settings-redesign.md` §5.1): the scope bar, the
/// four workflow presets, the reader, documents and tagging, dates, privacy and spending, and the one estimate.
struct SettingsProcessingTab: View {
    var showAdvanced: () -> Void

    @EnvironmentObject private var scope: SettingsScopeModel
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision = false
    @AppStorage(DefaultsKeys.useGateway) private var useGateway = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent = false
    @AppStorage(DefaultsKeys.gatewayLocalModel) private var gatewayLocalModel = false
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(OpenRouterListing.defaultsKey) private var openRouterListingData: Data?
    @AppStorage(DefaultsKeys.visionUseLLMJudgment) private var visionUseLLMJudgment = false
    @AppStorage(DefaultsKeys.visionLanguages) private var visionLanguages = "en-US"
    @AppStorage(DefaultsKeys.ocrPageKindRouting) private var ocrPageKindRouting = false
    @AppStorage(DefaultsKeys.taggingModeRaw) private var taggingModeRaw = TaggingMode.automatic.rawValue
    @AppStorage(DefaultsKeys.reviewDocumentSegmentation) private var reviewDocumentSegmentation = true
    @AppStorage(DefaultsKeys.mergeDocuments) private var mergeDocuments = false
    @AppStorage(DefaultsKeys.enableCollectionSegmentation) private var enableCollectionSegmentation = false
    @AppStorage(DefaultsKeys.confirmCollectionIDs) private var confirmCollectionIDs = false
    @AppStorage(DefaultsKeys.macItemFields) private var macItemFields = true
    @AppStorage(DefaultsKeys.batchMode) private var batchMode = false
    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput = false
    @AppStorage(DefaultsKeys.segmentationApproach) private var segmentationApproachRaw = SegmentationApproach.defaultApproach.rawValue
    @AppStorage(DefaultsKeys.outputDirectory) private var outputPath = ""
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = AppAppearance.defaultValue
    @ObservedObject private var modelStore = ModelSelectionStore.shared

    @State private var keyed: Set<LLMProvider> = []
    @State private var segmentationRoutes = SegmentationRoutes.none
    @State private var showGeneralInterview = false
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var interview: SettingsAdvisor.Target?
    @State private var projectToAsk: UUID?
    @State private var defaultsTick = 0

    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }
    private var segmentationPlan: SegmentationPlan {
        SegmentationPlan.resolve(tagging: taggingMode,
                                 approach: SegmentationApproach(rawValue: segmentationApproachRaw) ?? .defaultApproach)
    }
    private var isDirect: Bool { !useAppleVision && !useGateway && !useLocalAgent }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                scopeSection
                AdvancedInUseBanner(showAdvanced: showAdvanced).id(defaultsTick)
                Section {
                    WorkflowPresetRow(keyed: keyed)
                } header: {
                    HelpLabel("Workflow preset", help: "Each preset fills the reader and tagging below; change any row freely afterwards. The highlighted preset is the one your current choices match.")
                }
                readingSection
                documentsSection
                datesSection
                privacySection
            }
            .formStyle(.grouped)
            // On a view of its own: two sheets on one view present only one (the scope section holds New project's).
            .sheet(item: $interview) { target in
                SettingsAdvisorSheet(target: target) { interview = nil; scope.reload() }
            }
            Divider()
            SettingsEstimateFooter()
        }
        .onAppear(perform: reloadKeys)
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in reloadKeys() }
        // The Advanced groups' keys are plain defaults another tab writes: count them again on any change.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in defaultsTick += 1 }
        .sheet(isPresented: $showGeneralInterview) { GeneralInterviewView { showGeneralInterview = false } }
    }

    private func reloadKeys() {
        keyed = Set(LLMProvider.allCases.filter { $0 != .appleVision && KeychainHelper.exists(account: $0.rawValue) })
        segmentationRoutes = SegmentationRoutes.currentPreselecting()
    }

    // MARK: Scope

    @ViewBuilder private var scopeSection: some View {
        Section {
            if let folder = scope.folder {
                Picker("Editing", selection: $scope.scope) {
                    Text("General defaults").tag(SettingsScopeModel.Scope.general)
                    Text("Collection: \(folder.lastPathComponent)").tag(SettingsScopeModel.Scope.collection)
                }
                .accessibilityIdentifier("ap.settings.scope")
                if scope.effectiveScope == .collection { collectionRows(folder) }
            } else {
                Text("Choose an output folder in Process Files. Each output folder is a collection with its own settings; until then you edit your general defaults.")
                    .font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Rows with a source line under them follow this choice; the others apply to every run on this Mac.")
                .font(.caption2).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = scope.problem ?? scope.store.lastProblem {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        } header: {
            HelpLabel("Scope", help: "Each output folder is a collection with its own settings, kept in its hidden “.archivesuite/collection-settings.json”. Anything you leave unchanged inherits live from its project and your general defaults, so a key you add later is used by older collections too. Changed rows show a Reset button. API keys are never written there.")
        }
        .sheet(isPresented: $showNewProject, onDismiss: {
            if let id = projectToAsk { projectToAsk = nil; interview = .project(id) }
        }) {
            NameEntrySheet(title: "New Project",
                           message: "A project groups similar collections so they can share answers. A collection in it uses the project's answers unless it has its own.",
                           placeholder: "Project name", confirmLabel: "Create", name: $newProjectName) { name in
                guard let project = scope.store.addProject(named: name) else { return }
                scope.updateCollection { $0.projectID = project.id }
                projectToAsk = project.id
            }
        }
    }

    @ViewBuilder private func collectionRows(_ folder: URL) -> some View {
        HStack {
            Picker("Project", selection: Binding(
                get: { scope.doc?.projectID.flatMap { scope.store.project($0) != nil ? $0 : nil } },
                set: { id in scope.updateCollection { $0.projectID = id } })) {
                Text("None").tag(UUID?.none)
                ForEach(scope.store.projects) { Text($0.name).tag(UUID?.some($0.id)) }
            }
            .accessibilityIdentifier("ap.settings.project")
            Button("New project…") { newProjectName = ""; showNewProject = true }
        }
        if let id = scope.doc?.projectID, scope.store.project(id) == nil {
            Text("The project “\(scope.doc?.projectName ?? "")” is not on this Mac, so your general settings apply.")
                .font(.caption).foregroundStyle(.primary)
        }
        LabeledContent("Questions about this material") {
            HStack {
                Button(scope.heldKeys.isEmpty ? "Answer…" : "Answer again…") { interview = .collection(folder) }
                if let id = scope.doc?.projectID, scope.store.project(id) != nil {
                    Button("Project questions…") { interview = .project(id) }
                }
            }
        }
        let held = scope.heldKeys
        if held.isEmpty {
            Text("This collection has no settings of its own yet: everything comes from "
                 + (scope.resolver.project != nil ? "its project and " : "") + "your general defaults.")
                .font(.caption).foregroundStyle(.primary)
                .accessibilityIdentifier("ap.settings.collection.none")
        } else {
            DisclosureGroup("\(held.count) setting\(held.count == 1 ? "" : "s") held by this collection") {
                ForEach(held, id: \.self) { key in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key.label)
                            Text(key.describe(scope.resolve(key).value)).font(.caption).foregroundStyle(.primary)
                        }
                        Spacer()
                        Button("Reset") { scope.reset(key) }.controlSize(.small)
                    }
                }
            }
            .accessibilityIdentifier("ap.settings.collection.held")
        }
        if scope.runCount > 0 {
            Text("\(scope.runCount) batch\(scope.runCount == 1 ? "" : "es") recorded with the settings each one used.")
                .font(.caption).foregroundStyle(.primary)
        }
    }

    // MARK: Reading

    @ViewBuilder private var readingSection: some View {
        Section("Reading") {
            SettingsReaderPicker(keyed: keyed)
            // Shown only where it applies: a dimmed switch measured 1.25:1 in the accessibility audit.
            if isDirect || ocrPageKindRouting {
            Toggle(isOn: $ocrPageKindRouting) {
                HelpLabel("Use a different reader for handwritten pages", help: "Before a run, this Mac tells each dropped photo's kind with Apple Vision, free (about 0.6 s a page). Typed, printed and form pages keep the reader above; a handwritten page goes to the best measured handwriting reader you have a key or a download for. A page whose kind is unsure keeps the reader above. You can change the reader for one page in the file list, and the estimate follows. Needs macOS 26 and a cloud reader above.")
            }
            .accessibilityIdentifier("ap.settings.pageKindRouting")
            }
            if !isDirect {
                Text("Handwritten pages go to a second reader only with a cloud reader above.")
                    .font(.caption2).foregroundStyle(.primary)
            }
            if useAppleVision { appleVisionRows }
        }
    }

    @ViewBuilder private var appleVisionRows: some View {
        SettingsField("Languages") {
            TextField("Languages", text: $visionLanguages, prompt: Text("Auto-detect or enter en-US, fr-FR"))
                .accessibilityIdentifier("ap.settings.visionLanguages")
        }
        Toggle(isOn: $visionUseLLMJudgment) {
            HelpLabel("Use a cloud model for the text-only steps", help: "Sends only the text Apple Vision read, never the image, to the model chosen here for classification, document breaks, dates and tags. Add its key in Settings › Accounts.")
        }
        .accessibilityIdentifier("ap.settings.visionUseLLMJudgment")
        if visionUseLLMJudgment {
            Picker("Text model provider", selection: $selectedProvider) {
                ForEach(LLMProvider.allCases.filter { $0 != .appleVision }) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("ap.settings.visionJudgmentProviderPicker")
            let unavailable: String? = { _ = openRouterListingData; return modelStore.unavailableOpenRouterSelection(for: selectedProvider) }()
            let savedID = modelStore.selectedModelIDs[selectedProvider.rawValue]
            Picker("Text model", selection: Binding(get: { unavailable != nil ? (savedID ?? "") : modelStore.model(for: selectedProvider).id },
                                                     set: { id in
                if let m = selectedProvider.models.first(where: { $0.id == id }) { modelStore.setModel(m, for: selectedProvider) }
            })) {
                if unavailable != nil, let savedID { Text("\(savedID) (unavailable)").tag(savedID) }
                ForEach(selectedProvider.models) { Text($0.displayName).tag($0.id) }
            }
            .accessibilityIdentifier("ap.settings.visionJudgmentModelPicker")
            if let unavailable {
                Text(unavailable).font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.settings.openRouterUnavailable")
            }
        } else {
            let localAutoDate = !preOCRedInput && taggingMode == .autoDate
                && DateRoute.localImageEnabled(scope.resolve(.dateLocalImage).value)
            if !localAutoDate && taggingMode != .none && taggingMode != .copySource {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tagging is set to \(taggingMode.displayName), which Apple Vision cannot do on its own, so Start stays off.")
                        .font(.caption2).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ap.settings.visionTaggingConflict")
                    Spacer()
                    Button("Use No tagging") { taggingModeRaw = TaggingMode.none.rawValue }
                        .accessibilityIdentifier("ap.settings.visionUseNoTagging")
                }
            }
            if enableCollectionSegmentation {
                Text("Identifying collections needs a cloud model as well: turn it off below, or turn on the text-only model above.")
                    .font(.caption2).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Documents

    @ViewBuilder private var documentsSection: some View {
        Section("Documents and tagging") {
            Picker(selection: $taggingModeRaw) {
                ForEach(TaggingMode.allCases) { Text($0.displayName).tag($0.rawValue) }
            } label: {
                HelpLabel("Tagging mode", help: "\(taggingMode.detail)\n\nProcess Files' Tagging menu is a shortcut to this setting: changing either changes both.")
            }
            .accessibilityIdentifier("ap.settings.taggingMode")
            SegmentationChooserView(pageCount: 1000, scaleCaption: "per 1,000 pages", routes: $segmentationRoutes)
            Toggle(isOn: $reviewDocumentSegmentation) {
                HelpLabel("Review document breaks before filing", help: "Pause before tagging to review how the pages were grouped into documents. Rotation, flagged boundary checks, and box and folder confirmation have their own rules.")
            }
            .disabled(!segmentationPlan.reviewShowsDocumentClasses)
            .accessibilityIdentifier("ap.settings.reviewSegmentation")
            Toggle(isOn: $mergeDocuments) {
                HelpLabel("Merge multi-page documents", help: "Combine a document's continuation pages into one multi-page PDF instead of a separate PDF per page.")
            }
            Toggle(isOn: $enableCollectionSegmentation) {
                HelpLabel("Identify collections from box labels", help: "Read archival collections from box-label photos and file outputs into per-collection folders with sequential names, e.g. “000001 Collection Name.pdf”.")
            }
            if enableCollectionSegmentation {
                Toggle(isOn: $confirmCollectionIDs) {
                    HelpLabel("Confirm before filing", help: "Pause before filing so you can correct the collection names read from the box labels.")
                }
            }
            if taggingMode == .automatic {
                Toggle(isOn: $macItemFields) {
                    HelpLabel("Fill item fields on this Mac", help: "With a Mac model or Local Agent, suggest a kind, byline and publication date for the Reader to check. " + ItemFieldExtractor.macSetup + "\n\n" + ItemFieldExtractor.macCost + ". " + ItemFieldExtractor.macTimingNote)
                }
            }
        }
    }

    // MARK: Dates

    @ViewBuilder private var datesSection: some View {
        Section("Dates and names") {
            VStack(alignment: .leading, spacing: 2) {
                Picker(selection: Binding(get: { scope.resolve(.numericDatesDayFirst).value.bool ?? false },
                                          set: { scope.set(.numericDatesDayFirst, .bool($0)) })) {
                    Text("MM/DD (US)").tag(false)
                    Text("DD/MM (International)").tag(true)
                } label: {
                    HelpLabel("Numeric dates", help: "How an ambiguous numeric date such as 04/07/1962 is read: 7 April (MM/DD) or 4 July (DD/MM). Kept per collection.")
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("ap.settings.numericDates")
                LayeredSourceLine(key: .numericDatesDayFirst)
            }
            VStack(alignment: .leading, spacing: 2) {
                Picker(selection: Binding(get: { scope.resolve(.dateImageEveryDocument).value.bool ?? false },
                                          set: { scope.set(.dateImageEveryDocument, .bool($0)) })) {
                    Text("Only when the text has no year").tag(false)
                    Text("Every document").tag(true)
                } label: {
                    HelpLabel("Stamp and image dates", help: "When the page image is searched for a date, such as a received stamp. Every document also finds stamp dates on documents whose text already has a year, at one more call each.")
                }
                .accessibilityIdentifier("ap.settings.dateImage")
                LayeredSourceLine(key: .dateImageEveryDocument)
            }
        }
    }

    // MARK: Privacy, spending and the app

    private var monthCeiling: Binding<Double> {
        Binding(get: { scope.resolve(.monthCeilingUSD).value.double ?? 0 },
                set: { scope.set(.monthCeilingUSD, .double(max(0, $0))) })
    }

    private var batchCeiling: Binding<Double> {
        Binding(get: { scope.resolve(.batchCeilingUSD).value.double ?? 0 },
                set: { scope.set(.batchCeilingUSD, .double(max(0, $0))) })
    }

    /// Why the batch switch cannot apply to this run, or nil when it can (the pipeline batches only `batchMode &&
    /// provider.supportsBatch` off the gateway and the Local Agent).
    private var batchUnavailableReason: String? {
        if useAppleVision { return "Not used: Apple Vision reads every page on this Mac, with nothing to batch." }
        if useLocalAgent { return "Not used: the CLI runs on your subscription, so there is no batch discount." }
        if useGateway { return "Not used: the API gateway has no batch endpoint." }
        if preOCRedInput { return "Not used for pre-OCRed input." }
        if !selectedProvider.supportsBatch { return "Not used: \(selectedProvider.rawValue) has no batch API here." }
        return nil
    }

    @ViewBuilder private var privacySection: some View {
        Section("Privacy, spending and the app") {
            LayeredToggle(key: .staysOnMac) {
                HelpLabel("Keep pages on this Mac", help: "The app's picks and the Advisor (“Compare routes & trade-offs…”) offer only readers that run on this Mac, so no page image or text leaves it. A cloud reader you choose yourself above still sends pages to its provider.")
            }
            if scope.resolve(.staysOnMac).value.bool == true, !useAppleVision, !(useGateway && gatewayLocalModel) {
                Text("Your Reader above is not on this Mac: pages go to it when you run.")
                    .font(.caption2).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.settings.staysOnMacConflict")
            }
            LayeredToggle(key: .noTraining) {
                HelpLabel("Exclude routes that may train on your pages", help: "Pages go only where the provider's terms say uploads do not train its models; a route that may train, or whose terms depend on your account, is not offered.")
            }
            let habit = MoneyHabit(rawValue: scope.resolve(.moneyHabit).value.string ?? "") ?? .none
            VStack(alignment: .leading, spacing: 2) {
                Picker(selection: Binding(get: { habit }, set: { scope.set(.moneyHabit, .string($0.rawValue)) })) {
                    Text("Spend nothing").tag(MoneyHabit.none)
                    Text("A limit for each batch").tag(MoneyHabit.perBatch)
                    Text("A limit for each month").tag(MoneyHabit.perMonth)
                    Text("No limit").tag(MoneyHabit.noCeiling)
                } label: {
                    HelpLabel("Spending limit", help: "The most the app's picks may cost. A run that would pass the limit asks before it starts. Spent this month: \(scope.store.monthSpend().summary).")
                }
                .accessibilityIdentifier("ap.settings.moneyHabit")
                LayeredSourceLine(key: .moneyHabit)
            }
            if habit == .perMonth {
                LabeledContent("Most to spend in a month") {
                    TextField("Month limit", value: monthCeiling, format: .currency(code: "USD"))
                        .textFieldStyle(.roundedBorder).frame(width: 100).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("ap.settings.monthCeiling")
                }
                Text("Spent this month: \(scope.store.monthSpend().summary).")
                    .font(.caption2).foregroundStyle(.primary)
                    .accessibilityIdentifier("ap.settings.monthSpent")
            } else if habit == .perBatch {
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Most to spend on a batch") {
                        TextField("Batch limit", value: batchCeiling, format: .currency(code: "USD"))
                            .textFieldStyle(.roundedBorder).frame(width: 100).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("ap.settings.batchCeiling")
                    }
                    LayeredSourceLine(key: .batchCeilingUSD)
                }
            }
            Toggle(isOn: $batchMode) {
                HelpLabel("Use overnight batch pricing (about half price)", help: "Batch jobs are queued and returned later — minutes to hours — at about half the price. Not available with Apple Vision, the command-line agent, a gateway, pre-OCRed input or a provider without a batch API.\n\nGemini batch jobs occasionally stay pending; if one does not finish within a few hours, cancel and retry, or turn this off.")
            }
            .disabled(batchUnavailableReason != nil)
            .accessibilityIdentifier("ap.settings.batchMode")
            if let reason = batchUnavailableReason {
                Text(reason)
                    .font(.caption2).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.settings.batchModeUnavailable")
            }
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("ap.settings.appearance")
            LabeledContent("This Mac and how you work") {
                Button("Answer the setup questions…") { showGeneralInterview = true }
                    .accessibilityIdentifier("ap.settings.setupQuestions")
            }
            .help("The questions asked at first start: what this Mac has, its plans and keys, spending, how long a batch may run.")
        }
    }
}

/// "N Advanced settings in use — View / Reset" (§5.5): so a setting in the Advanced tab never runs unseen.
struct AdvancedInUseBanner: View {
    var showAdvanced: () -> Void
    @EnvironmentObject private var scope: SettingsScopeModel
    /// Read so a change in the Advanced tab redraws the count.
    @AppStorage(DefaultsKeys.offerExperimentalRoutes) private var offerExperimental = false
    @State private var tick = 0
    @State private var confirmReset = false

    var body: some View {
        let active = SettingsAdvanced.activeGroups(resolver: scope.resolver)
        if !active.isEmpty {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Label("\(active.count) Advanced setting\(active.count == 1 ? "" : "s") in use: "
                          + active.map(\.title).joined(separator: ", "), systemImage: "slider.horizontal.3")
                        .font(.caption).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("View") { showAdvanced() }.controlSize(.small)
                        .accessibilityIdentifier("ap.settings.advancedInUse.view")
                    Button("Reset…") { confirmReset = true }
                        .controlSize(.small)
                        .help("Puts these Advanced settings back to their defaults.")
                        .accessibilityIdentifier("ap.settings.advancedInUse.reset")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ap.settings.advancedInUse")
                .confirmationDialog("Reset \(active.count) Advanced setting\(active.count == 1 ? "" : "s")?",
                                    isPresented: $confirmReset) {
                    Button("Reset", role: .destructive) {
                        for g in active {
                            SettingsAdvanced.reset(g)
                            g.layered.forEach(scope.reset)
                        }
                        tick += 1
                    }
                } message: {
                    Text(active.map(\.title).joined(separator: ", ") + " go back to their defaults, including any text "
                         + "typed in them. A collection's own switches are reset in the layer you are editing.")
                }
            }
            .id(tick)
        }
    }
}
