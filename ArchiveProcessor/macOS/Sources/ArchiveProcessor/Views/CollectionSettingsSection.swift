import SwiftUI

/// Settings' "This collection" section (W46.settings-layers), in place of the named profiles: the collection is the
/// output folder, it keeps only the values answered for it, and everything else comes from its project and then the
/// general settings when a batch runs. Shows each value the collection holds with its source and a reset, and the
/// project it belongs to. The interviews and the settings sheet (W46.settings-interviews, W46.settings-sheet) fill and
/// show the rest.
struct CollectionSettingsSection: View {
    enum Focus: Hashable { case project }
    var focus: FocusState<Focus?>.Binding

    @ObservedObject private var store = SettingsLayerStore.shared
    @AppStorage(DefaultsKeys.outputDirectory) private var outputPath: String = ""
    @State private var doc: CollectionSettingsDocument?
    @State private var runCount = 0
    @State private var problem: String?
    @State private var showNewProject = false
    @State private var newProjectName = ""

    /// The folder Process Files writes into, resolved exactly as it resolves it (the saved folder, else Downloads; the
    /// UI suite's own folder under test). `outputPath` is read so a change of folder redraws the section.
    private var outputFolder: URL? {
        _ = outputPath
        #if DEBUG
        if let folder = ProcessorUITestConfiguration.outputDirectory { return folder }
        #endif
        return ModelSelectionStore.savedOutputDirectory()
    }

    private var resolver: SettingsResolver { store.resolver(for: doc) }

    private var heldKeys: [SettingsKey] {
        guard let doc else { return [] }
        return doc.collection.entries.keys.map(SettingsKey.init(rawValue:))
            .filter { doc.collection.entry($0) != nil }
            .sorted { $0.label < $1.label }
    }

    var body: some View {
        Section {
            if let folder = outputFolder {
                LabeledContent("Collection", value: folder.lastPathComponent)
                HStack {
                    Picker("Project", selection: projectBinding(folder)) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.projects) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .focused(focus, equals: .project)
                    newProjectButton
                }
                if let id = doc?.projectID, store.project(id) == nil {
                    Text("The project “\(doc?.projectName ?? "")” is not on this Mac, so your general settings apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if heldKeys.isEmpty {
                    Text("This collection has no settings of its own yet. Everything comes from "
                         + (resolver.project != nil ? "its project and " : "") + "your general settings.")
                        .font(.caption).foregroundStyle(.primary)
                } else {
                    ForEach(heldKeys, id: \.self) { key in
                        heldRow(key, folder: folder)
                    }
                }
                if runCount > 0 {
                    Text("\(runCount) batch\(runCount == 1 ? "" : "es") recorded with the settings each one used.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Choose an output folder in Process Files. Each output folder is a collection with its own settings.")
                    .font(.caption).foregroundStyle(.primary)
                HStack { Spacer(); newProjectButton.focused(focus, equals: .project) }
            }
            if let message = problem ?? store.lastProblem {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("This collection")
                HelpButton(text: "A collection is the output folder its PDFs go to. It keeps only the settings you answer for it; everything else comes from its project, if it has one, and then from your general settings at the moment a batch runs, so a key you add later is used by older collections too. Each value says where it comes from, and Reset goes back to the inherited one.\n\nThe collection's settings, and the settings each batch used, are kept with the collection in a hidden “.archivesuite” folder inside the output folder, so the Reader, Notes or another Mac can see what produced it. API keys are never written there.")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: outputPath) { _, _ in reload() }
        .sheet(isPresented: $showNewProject) {
            NameEntrySheet(title: "New Project",
                           message: "A project groups similar collections so they can share answers. A collection in it uses the project's answers unless it has its own.",
                           placeholder: "Project name",
                           confirmLabel: "Create", name: $newProjectName) { name in
                guard let project = store.addProject(named: name), let folder = outputFolder else { return }
                update(folder) { $0.projectID = project.id }
            }
        }
    }

    private var newProjectButton: some View {
        Button("New project…") {
            newProjectName = ""
            showNewProject = true
        }
    }

    private func heldRow(_ key: SettingsKey, folder: URL) -> some View {
        let own = resolver.resolve(key)
        var inherited = resolver
        inherited.collection = nil
        let above = inherited.resolve(key)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(key.label)
                Text("\(key.describe(own.value)) — \(own.sourceText)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset") { update(folder) { $0.collection.reset(key) } }
                .help("Go back to \(key.describe(above.value)), \(above.sourceText)")
        }
    }

    private func projectBinding(_ folder: URL) -> Binding<UUID?> {
        Binding(get: { doc?.projectID.flatMap { store.project($0) != nil ? $0 : nil } },
                set: { id in update(folder) { $0.projectID = id } })
    }

    private func update(_ folder: URL, _ change: (inout CollectionSettingsDocument) -> Void) {
        if let written = store.updateCollection(in: folder, change) {
            doc = written
            problem = nil
        } else {
            problem = store.lastProblem
        }
    }

    private func reload() {
        guard let folder = outputFolder else { doc = nil; problem = nil; runCount = 0; return }
        runCount = CollectionSettingsFile.runCount(in: folder)
        switch CollectionSettingsFile.read(in: folder) {
        case .document(let d): doc = d; problem = nil
        case .missing: doc = nil; problem = nil
        case .unreadable:
            doc = nil
            problem = "This collection's settings file could not be read. It will be set aside, not deleted, when the collection's settings are next saved."
        case .refused(let e): doc = nil; problem = "This collection's settings were left alone: \(e.description)."
        }
    }
}
