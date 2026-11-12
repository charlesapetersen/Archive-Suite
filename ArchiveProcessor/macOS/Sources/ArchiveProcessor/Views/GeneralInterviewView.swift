import SwiftUI

/// The general interview (W46.settings-interviews, `12-settings-design.md` §3.1): shown once at the app's first start
/// and again from Settings. It shows what it found on this Mac, then asks what it cannot read. Skipping it keeps
/// "Free, on this Mac": the keys found are listed, nothing is spent (owner call 3).
struct GeneralInterviewView: View {
    var onDone: () -> Void

    @ObservedObject private var store = SettingsLayerStore.shared
    @State private var answers = GeneralInterviewAnswers(from: SettingsLayerStore.shared.general)
    /// Read once when the sheet opens (seven Keychain queries), not on every redraw.
    @State private var inventory = MacInventory(chip: "this Mac", memoryGB: SettingsLayerStore.thisMacMemoryGB, keys: [],
                                                claudePath: nil, claudeSignedIn: nil, chatGPTSignedIn: false)
    @State private var readOnce = false
    /// Run again from Settings after it was answered: Cancel then leaves the answers as they are.
    @State private var rerun = GeneralInterviewAnswers.hasAnswers(SettingsLayerStore.shared.general)
    @State private var checkingClaude = false
    @State private var claudeMessage: String?
    @State private var showKeyWizard = false
    @State private var problem: String?

    static func readMac() -> MacInventory {
        let d = UserDefaults.standard
        let override = LocalAgentTool(rawValue: d.string(forKey: DefaultsKeys.localAgentTool) ?? "") == .claude
            ? d.string(forKey: DefaultsKeys.localAgentBinaryPath) ?? "" : ""
        return MacInventory.read(exists: KeychainHelper.exists(account:),
                                 claudePath: LocalAgentClient.resolveBinaryPath(tool: .claude, override: override))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Archive Processor").font(.title2).fontWeight(.semibold)
                Text("A few questions about this Mac and how you like to work. Every answer can be changed later in Settings, and each collection can answer for itself.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            Form {
                foundSection
                startingPointSection
                questionsSection
                if let problem { Text(problem).foregroundStyle(.red).font(.caption) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Skip: free, on this Mac") { skip() }
                    .help("Saves only what was found on this Mac and clears any earlier answers. Nothing is spent and no page leaves it until you choose otherwise.")
                Spacer()
                if rerun { Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction) }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ap.generalInterview.save")
            }
            .padding(16)
        }
        .frame(width: 600, height: 700)
        .onAppear {
            guard !readOnce else { return }
            readOnce = true
            inventory = Self.readMac()
        }
        .sheet(isPresented: $showKeyWizard) {
            ProviderKeyWizard {
                showKeyWizard = false
                inventory = Self.readMac().keepingClaudeCheck(of: inventory)
            }
        }
    }

    // MARK: Found on this Mac

    private var foundSection: some View {
        Section("Found on this Mac") {
            LabeledContent("Computer", value: "\(inventory.chip), \(Int(inventory.memoryGB)) GB of memory")
            LabeledContent("Keys for online readers") {
                Text(inventory.keys.isEmpty ? "None" : inventory.keys.map(MacInventory.keyLabel).joined(separator: ", "))
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("A key lets the app send pages to that company's models, which they charge for. Keys stay in your Keychain; only their presence is checked.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Add a key…") { showKeyWizard = true }
            }
            LabeledContent("Claude subscription") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(claudeText).multilineTextAlignment(.trailing)
                    if inventory.claudePath != nil && inventory.claudeSignedIn == nil {
                        Button(checkingClaude ? "Checking…" : "Check the sign-in") { checkClaude() }
                            .disabled(checkingClaude)
                            .help("Sends one very short message through your Claude plan to see that it answers. It costs no money.")
                    }
                }
            }
            if let claudeMessage {
                Text(claudeMessage).font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("ChatGPT subscription", value: inventory.chatGPTSignedIn ? "Signed in on this Mac" : "Not signed in")
        }
    }

    private var claudeText: String {
        guard inventory.claudePath != nil else { return "The Claude app for the command line is not installed" }
        switch inventory.claudeSignedIn {
        case true?: return "Installed and signed in"
        case false?: return "Installed, but not signed in"
        case nil: return "Installed; sign-in not checked yet"
        }
    }

    // MARK: Starting points

    private var startingPointSection: some View {
        Section {
            ForEach(SettingsStartingPoint.allCases, id: \.self) { point in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.name)
                        Text(point.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if answers.startingPoint == point && !answers.filled.isEmpty {
                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                            .accessibilityLabel("Filled in")
                    }
                    Button("Fill in") { answers.fill(point) }
                }
            }
        } header: {
            Text("Start from")
        } footer: {
            Text("A starting point only fills in the answers below. You can change any of them afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: The month's ledger (W46.settings-ledger)

    /// This month's spending against the limit being set, and the batches behind it.
    private var monthLedger: some View {
        let month = store.monthSpend()
        let left = max(0, answers.monthCeilingUSD - month.usd)
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Spent this month", value: month.summary)
            if !month.entries.isEmpty {
                Text(String(format: "$%.2f", left) + " left of " + String(format: "$%.2f", max(0, answers.monthCeilingUSD))
                     + " for the rest of the month. The settings sheet chooses within what is left; Process Files"
                     + " does not yet stop a batch at the limit.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(month.entries.prefix(Self.ledgerLines).enumerated()), id: \.offset) { _, e in
                    Text(Self.ledgerLine(e)).font(.caption).foregroundStyle(.secondary)
                }
                if month.batches > Self.ledgerLines {
                    Text("and \(month.batches - Self.ledgerLines) earlier this month").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Each batch counts at the list prices the app estimates when it finishes; a provider's bill may differ a little.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ap.interview.monthLedger")
    }

    static let ledgerLines = 5

    /// "12 Nov · Letters, 40 files · $1.20".
    static func ledgerLine(_ e: SettingsLedgerEntry) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        var what = e.collectionName ?? "a batch"
        if let n = e.files { what += ", \(n) \(n == 1 ? "file" : "files")" }
        return f.string(from: e.date) + " · " + what + " · " + String(format: "$%.2f", e.usd)
    }

    // MARK: The questions

    private var questionsSection: some View {
        Section("Your answers") {
            Picker("Spending", selection: Binding(get: { answers.moneyHabit }, set: { answers.setMoneyHabit($0) })) {
                Text("Spend nothing").tag(MoneyHabit.none)
                Text("A limit for each batch").tag(MoneyHabit.perBatch)
                Text("A limit for each month").tag(MoneyHabit.perMonth)
                Text("No limit").tag(MoneyHabit.noCeiling)
            }
            .help("Online readers charge by the page. The app never spends past the limit you set here.")
            switch answers.moneyHabit {
            case .perBatch:
                dollars("Most to spend on one batch", bind(\.batchCeilingUSD, .batchCeilingUSD))
            case .perMonth:
                dollars("Most to spend in a month", bind(\.monthCeilingUSD, .monthCeilingUSD))
                Text("What each batch spends is added up for the month, and the next batch gets what is left.")
                    .font(.caption).foregroundStyle(.secondary)
                monthLedger
            case .none, .noCeiling:
                EmptyView()
            }
            Stepper(value: bind(\.hours, .hours), in: 1...168, step: 1) {
                LabeledContent("How long a batch may usually run", value: hoursText(answers.hours))
            }
            .help("A batch that may run overnight can use half-price overnight rates from some online readers.")
            Toggle("Pages may leave this Mac", isOn: Binding(get: { !answers.staysOnMac },
                                                            set: { answers.staysOnMac = !$0; answers.staysOnMacChosen = true; answers.touch(.staysOnMac) }))
                .help("Off: every page is read here, even when a key or a plan would read it better. Each collection can still be kept on this Mac by itself.")
            Picker("When two choices are close", selection: bind(\.preference, .preference)) {
                Text("Take the better one").tag(SettingsPreference.bestMeasured)
                Text("Take the cheaper one").tag(SettingsPreference.cheapestWithinPoint)
                Text("Take the faster one").tag(SettingsPreference.fastestWithinPoint)
            }
            .help("“Close” means within a point of accuracy on the app's own tests.")
            Toggle("Models may be downloaded to this Mac", isOn: bind(\.downloadsAllowed, .downloadsAllowed))
                .help("Some of the best free readers run on this Mac but need a download of a few gigabytes first.")
            Toggle("I can use a computing cluster", isOn: bind(\.cluster, .cluster))
                .help("Shared computers with graphics cards, such as a university's, that take jobs through a queue (most use one called Slurm). The app prepares the job; you send it.")
            if answers.cluster {
                Stepper(value: bind(\.gpusPerJob, .gpusPerJob), in: 1...16) {
                    LabeledContent("Graphics cards one job may use", value: "\(answers.gpusPerJob)")
                }
            }
            Picker("Training a model on your corrections", selection: bind(\.fineTuning, .fineTuning)) {
                Text("No").tag(FineTuningAnswer.no)
                Text("Yes, with a coding assistant on this Mac").tag(FineTuningAnswer.codingAgent)
                Text("Yes, on a computing cluster").tag(FineTuningAnswer.cluster)
            }
            .help("Once you have corrected enough pages, a reader can be taught your material. It takes setup work, so most people answer No.")
        }
    }

    private func dollars(_ label: String, _ value: Binding<Double>) -> some View {
        LabeledContent(label) {
            TextField(label, value: value, format: .currency(code: "USD"))
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 110)
        }
    }

    private func hoursText(_ h: Double) -> String {
        h == 1 ? "1 hour" : h >= 8 && h <= 12 ? "\(Int(h)) hours (overnight)" : "\(Int(h)) hours"
    }

    /// A binding that marks the answer as the user's own once changed.
    private func bind<T>(_ path: WritableKeyPath<GeneralInterviewAnswers, T>, _ key: SettingsKey) -> Binding<T> {
        Binding(get: { answers[keyPath: path] }, set: { answers[keyPath: path] = $0; answers.touch(key) })
    }

    // MARK: Actions

    private func checkClaude() {
        guard let path = inventory.claudePath else { return }
        checkingClaude = true
        claudeMessage = nil
        Task {
            let status = await LocalAgentValidator.detectAndVerify(config: LocalAgentConfig(tool: .claude, binaryPath: path))
            checkingClaude = false
            switch status {
            case .works: inventory.claudeSignedIn = true
            case .cliNotLoggedIn, .cliEntitlementMissing, .cliNotFound: inventory.claudeSignedIn = false
            default: claudeMessage = "The check could not finish just now; try again later. The plan is not used until it passes."
            }
        }
    }

    private func save() {
        var layer = store.general
        answers.apply(to: &layer, inventory: inventory)
        write(layer)
    }

    private func skip() {
        var layer = store.general
        GeneralInterviewAnswers.skip(inventory, layer: &layer)
        write(layer)
    }

    private func write(_ layer: SettingsLayer) {
        if store.replaceGeneral(layer) { onDone() } else {
            problem = store.lastProblem ?? "Your answers could not be saved."
        }
    }
}

private extension MacInventory {
    /// A fresh read after a key was added, keeping the sign-in check already made.
    func keepingClaudeCheck(of old: MacInventory) -> MacInventory {
        var m = self
        if m.claudePath == old.claudePath { m.claudeSignedIn = old.claudeSignedIn }
        return m
    }
}
