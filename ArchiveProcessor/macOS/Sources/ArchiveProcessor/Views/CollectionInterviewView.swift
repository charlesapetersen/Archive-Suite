import SwiftUI
import UniformTypeIdentifiers

/// The collection interview (W46.settings-interviews, `12-settings-design.md` §3.2): asked when a collection or a
/// project is created, and again from Settings. It measures the kinds of document on a sample of the photographs, asks
/// what the classifier cannot see, and writes the answers into the collection's own layer (its document in the output
/// folder) or a project's. Skipping writes nothing, so the collection keeps reading its project and general settings.
struct CollectionInterviewView: View {
    enum Target: Equatable {
        case collection(URL)
        case project(UUID)
    }

    let target: Target
    /// Photographs already chosen for the batch, measured without asking for them again.
    var photos: [URL] = []
    var onDone: () -> Void

    @ObservedObject private var store = SettingsLayerStore.shared
    @State private var answers = CollectionInterviewAnswers()
    @State private var loaded = false
    @State private var measuring = false
    @State private var measuredCount = 0
    @State private var measureTotal = 0
    @State private var measureTask: Task<Void, Never>?
    @State private var problem: String?
    /// The collection's document, read once when the sheet opens rather than on every redraw.
    @State private var doc: CollectionSettingsDocument?

    private var resolver: SettingsResolver {
        switch target {
        case .collection: return store.resolver(for: doc)
        case .project(let id): return SettingsResolver(general: store.general, project: store.project(id))
        }
    }

    /// The layer this interview writes.
    private var own: SettingsLayer? {
        switch target {
        case .collection: return doc?.collection
        case .project(let id): return store.project(id)
        }
    }

    private var title: String {
        switch target {
        case .collection(let folder): return "About the collection “\(folder.lastPathComponent)”"
        case .project(let id): return "About the project “\(store.project(id)?.name ?? "")”"
        }
    }

    private var habit: MoneyHabit {
        SettingsResolver(general: store.general).resolve(.moneyHabit).value.string.flatMap(MoneyHabit.init(rawValue:)) ?? .none
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2).fontWeight(.semibold)
                Text("What is specific to this material. Anything you leave comes from "
                     + (resolver.project != nil ? "its project and " : "") + "your general settings, and you can change every answer later.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            Form {
                startingPointSection
                kindsSection
                periodSection
                limitsSection
                prioritiesSection
                switchesSection
                if let problem { Text(problem).foregroundStyle(.red).font(.caption) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Skip") { measureTask?.cancel(); onDone() }
                    .help("Saves nothing; this material uses \(resolver.project != nil ? "its project's and " : "")your general settings.")
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(measuring)
                    .accessibilityIdentifier("ap.collectionInterview.save")
            }
            .padding(16)
        }
        .frame(width: 640, height: 760)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if case .collection(let folder) = target, case .document(let d) = CollectionSettingsFile.read(in: folder) { doc = d }
            answers = CollectionInterviewAnswers(resolver: resolver, own: own)
            if answers.measuredShares.isEmpty, !photos.isEmpty { measure(photos) }
        }
        .onDisappear { measureTask?.cancel() }
    }

    // MARK: Starting points

    private var startingPointSection: some View {
        Section {
            Picker("Start from", selection: Binding(get: { answers.startingPoint },
                                                    set: { if let p = $0 { answers.fill(p) } })) {
                Text("Choose…").tag(SettingsStartingPoint?.none)
                ForEach(SettingsStartingPoint.allCases, id: \.self) { Text($0.name).tag(SettingsStartingPoint?.some($0)) }
            }
            if let point = answers.startingPoint {
                Text(point.summary).font(.caption).foregroundStyle(.secondary)
            }
            if let note = CollectionInterviewAnswers.moneyNote(point: answers.startingPoint, habit: habit) {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        } footer: {
            Text("A starting point only fills in the limits below; change any of them afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Kinds of document

    private var kindsSection: some View {
        Section {
            HStack {
                if measuring {
                    ProgressView(value: Double(measuredCount), total: Double(max(1, measureTotal)))
                    Text("Looking at \(measuredCount) of \(measureTotal)…").font(.caption).monospacedDigit()
                    Button("Stop") { measureTask?.cancel() }
                } else {
                    Text(measurementText).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(answers.measurement == nil ? "Measure from photos…" : "Measure again…") { choosePhotos() }
                        .help("Looks at up to \(KindMeasurement.sampleLimit) of the photographs on this Mac to tell typed, printed, handwritten and form pages apart. Nothing is sent anywhere.")
                }
            }
            ForEach(CollectionInterviewAnswers.measuredKinds, id: \.self) { kind in
                percentRow(PageKindName.label(kind), value: Binding(
                    get: { answers.measuredShares[kind] ?? 0 },
                    set: { answers.measuredShares[kind] = $0; answers.correctedMix = true; answers.touch(.mix) }))
            }
            ForEach(CollectionInterviewAnswers.unmeasuredKinds, id: \.self) { kind in
                percentRow(CollectionInterviewAnswers.unmeasuredLabel(kind), note: "not measured", value: Binding(
                    get: { answers.unmeasuredShares[kind] ?? 0 },
                    set: { answers.unmeasuredShares[kind] = $0; answers.touch(.mix) }))
            }
        } header: {
            Text("Kinds of document")
        } footer: {
            Text("Percent of the pages. The kinds marked “not measured” cannot be told from a photograph by the app, so give your own estimate; registers are judged with forms and tables.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var measurementText: String {
        if let from = answers.mixInheritedFrom {
            return "These shares come from \(from). Measure this collection's own photographs to replace them."
        }
        guard let m = answers.measurement else {
            return answers.measuredShares.isEmpty
                ? "Not measured yet. Measuring tells the kinds apart on a sample of the photographs."
                : "You gave these shares."
        }
        var s = "Measured on \(m.sample) photo\(m.sample == 1 ? "" : "s")"
        if m.unsure > 0 { s += "; \(m.unsure) of them unsure" }
        if m.unknown > 0 { s += "; \(m.unknown) could not be read" }
        s += ". On the app's test pages it named the kind rightly on \(KindMeasurement.ownerRight) of \(KindMeasurement.ownerPages)."
        if answers.correctedMix { s += " You have corrected the shares." }
        return s
    }


    private func percentRow(_ label: String, note: String? = nil, value: Binding<Double>) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 60)
                Text("%")
            }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Period, languages, scripts

    private var periodSection: some View {
        Section {
            LabeledContent("Period") {
                HStack(spacing: 4) {
                    TextField("from", value: derives(\.periodFrom, .period), format: .number.grouping(.never))
                        .labelsHidden().frame(width: 70)
                    Text("to")
                    TextField("to", value: derives(\.periodTo, .period), format: .number.grouping(.never))
                        .labelsHidden().frame(width: 70)
                }
            }
            DisclosureGroup("Languages: \(languageSummary)") {
                ForEach(CollectionInterviewAnswers.languageChoices, id: \.code) { choice in
                    Toggle(choice.label, isOn: Binding(
                        get: { answers.languages.contains(choice.code) },
                        set: { on in
                            answers.languages.removeAll { $0 == choice.code }
                            if on { answers.languages.append(choice.code) }
                            answers.touch(.languages); answers.touch(.mix)
                        }))
                }
            }
            DisclosureGroup("Writing: \(scriptSummary)") {
                ForEach([CollectionScript.kurrent, .fraktur], id: \.self) { s in
                    Toggle(s.label, isOn: Binding(
                        get: { answers.latinForms.contains(s) },
                        set: {
                            if $0 { answers.latinForms.insert(s) } else { answers.latinForms.remove(s) }
                            answers.touch(.scripts); answers.touch(.mix)
                        }))
                }
                ForEach(CollectionScript.allCases.filter { !$0.isLatinForm }, id: \.self) { s in
                    percentRow(s.label, value: Binding(get: { answers.scriptShares[s] ?? 0 },
                                                       set: { answers.scriptShares[s] = $0; answers.touch(.scripts); answers.touch(.mix) }))
                }
            }
            Text(judgedOnText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Period, languages and writing")
        } footer: {
            Text("A photograph cannot show these, and they decide which of the app's public test pages its figures for your material come from.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var languageSummary: String {
        let names = answers.languages.compactMap { c in CollectionInterviewAnswers.languageChoices.first { $0.code == c }?.label }
        return names.isEmpty ? "not given" : names.joined(separator: ", ")
    }

    private var scriptSummary: String {
        var parts = answers.latinForms.sorted { $0.rawValue < $1.rawValue }.map(\.label)
        parts += answers.scriptShares.filter { $0.value > 0 }.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.label) \(String(format: "%g", $0.value))%" }
        return parts.isEmpty ? "the Latin alphabet" : parts.joined(separator: ", ")
    }

    private var judgedOnText: String {
        let strata = answers.mixAndStrata().strata.keys.sorted()
        guard !strata.isEmpty else {
            return "Your pages are judged on the app's own measured pages (English, 20th century, Latin alphabet)."
        }
        return "Some of your pages are judged on public test pages: " + strata.map { PublicStratum.label($0) }.joined(separator: "; ") + "."
    }

    // MARK: Limits

    private var limitsSection: some View {
        Section("This batch") {
            LabeledContent("Most to spend") {
                TextField("Most to spend", value: bind(\.batchCeilingUSD, .batchCeilingUSD), format: .currency(code: "USD"))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 110)
            }
            if habit == .none {
                Text("Your general settings spend nothing, so this limit has no effect until Spending is changed there.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !answers.isAnswered(.batchCeilingUSD) {
                Text(habit == .noCeiling ? "No limit, from your general settings, unless you type one here."
                                         : "From your general settings unless you type one here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper(value: bind(\.hours, .hours), in: 1...168) {
                LabeledContent("How long it may run", value: answers.hours == 1 ? "1 hour" : "\(Int(answers.hours)) hours")
            }
            Stepper(value: bind(\.checkingMinutes, .checkingMinutes), in: 0...600, step: 5) {
                LabeledContent("Minutes you will spend checking where documents begin",
                               value: "\(Int(answers.checkingMinutes))")
            }
            .help("The app asks you to look at the places it is least sure one document ends and the next begins. More minutes, fewer mistakes.")
        }
    }

    // MARK: What matters most

    private var prioritiesSection: some View {
        Section {
            ForEach(Array(answers.order.enumerated()), id: \.element) { i, p in
                HStack {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(CollectionInterviewAnswers.priorityLabel(p))
                    Spacer()
                    TextField("weight", value: Binding(get: { answers.weights[p] ?? 0 },
                                                       set: { answers.weights[p] = max(0, $0); answers.touch(.priorities) }),
                              format: .number.precision(.fractionLength(0)))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 50)
                    Button { answers.move(p, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(i == 0).accessibilityLabel("Move \(CollectionInterviewAnswers.priorityLabel(p)) up")
                    Button { answers.move(p, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(i == answers.order.count - 1)
                        .accessibilityLabel("Move \(CollectionInterviewAnswers.priorityLabel(p)) down")
                }
            }
            Picker("When two choices are close", selection: bind(\.preference, .preference)) {
                Text("Take the better one").tag(SettingsPreference.bestMeasured)
                Text("Take the cheaper one").tag(SettingsPreference.cheapestWithinPoint)
                Text("Take the faster one").tag(SettingsPreference.fastestWithinPoint)
            }
        } header: {
            Text("What matters most")
        } footer: {
            Text("The numbers say how much each one counts when money or time has to be shared out; 0 leaves it out. Names are only looked for when they count.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }


    // MARK: Switches

    private var switchesSection: some View {
        Section {
            Toggle("Straighten the copy you read", isOn: bind(\.straightenReadingCopy, .straightenReadingCopy))
                .help("Turns a page photographed at a slant level in the PDF you read. Nothing on the page is removed.")
            Toggle("Keep these pages on this Mac", isOn: bind(\.staysOnMac, .staysOnMac))
                .help("For sensitive material: every page is read here, even when a key or a plan would read it better.")
        }
    }

    private func bind<T>(_ path: WritableKeyPath<CollectionInterviewAnswers, T>, _ key: SettingsKey) -> Binding<T> {
        Binding(get: { answers[keyPath: path] }, set: { answers[keyPath: path] = $0; answers.touch(key) })
    }

    /// A value the public test sets are derived from: the mix is written with it.
    private func derives<T>(_ path: WritableKeyPath<CollectionInterviewAnswers, T>, _ key: SettingsKey) -> Binding<T> {
        Binding(get: { answers[keyPath: path] }, set: { answers[keyPath: path] = $0; answers.touch(key); answers.touch(.mix) })
    }

    // MARK: Measuring

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        panel.prompt = "Measure"
        panel.message = "Choose photographs from this material, or a folder of them."
        guard panel.runModal() == .OK else { return }
        measure(Self.imageFiles(in: panel.urls))
    }

    /// The image files chosen, a folder's own files included (one level: a box's folder of photographs).
    static func imageFiles(in urls: [URL]) -> [URL] {
        let fm = FileManager.default
        return urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            guard isDir.boolValue else { return [url] }
            return (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        }
    }

    private func measure(_ urls: [URL]) {
        let sample = KindMeasurement.sample(urls)
        guard !sample.isEmpty else {
            problem = "No photographs were found there (JPEG, PNG, HEIC or TIFF)."
            return
        }
        problem = nil
        measuring = true
        measuredCount = 0
        measureTotal = sample.count
        measureTask = Task {
            var kinds: [PageKind?] = []
            for url in sample {
                if Task.isCancelled { break }
                let kind = await Task.detached(priority: .utility) { () -> PageKind? in
                    await PageKindClassifier.classify(url: url)
                }.value
                kinds.append(kind)
                measuredCount = kinds.count
            }
            measuring = false
            guard !Task.isCancelled, !kinds.isEmpty else { return }
            let m = KindMeasurement.tally(kinds)
            if m.counts.isEmpty {
                problem = "The kinds could not be told on this Mac (it needs macOS 26 or later)."
            } else {
                answers.take(m)
            }
        }
    }

    // MARK: Saving

    private func save() {
        var a = answers
        a.periodFrom = a.periodFrom.map { max(0, $0) }
        a.periodTo = a.periodTo.map { max(0, $0) }
        switch target {
        case .collection(let folder):
            if store.updateCollection(in: folder, { a.apply(to: &$0.collection) }) != nil { onDone() }
            else { problem = store.lastProblem ?? "The collection's answers could not be saved." }
        case .project(let id):
            if store.updateProject(id, { a.apply(to: &$0) }) { onDone() }
            else { problem = store.lastProblem ?? "The project's answers could not be saved." }
        }
    }
}

extension CollectionInterviewView.Target: Identifiable {
    var id: String {
        switch self {
        case .collection(let url): return "collection:" + url.path
        case .project(let id): return "project:" + id.uuidString
        }
    }
}
