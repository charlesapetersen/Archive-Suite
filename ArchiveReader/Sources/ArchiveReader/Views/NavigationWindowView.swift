import SwiftUI

/// The file-navigation window — a Finder-Smart-Folder-like browser over the tagged corpus.
struct NavigationWindowView: View {
    @StateObject private var model = NavigationModel()
    @Environment(\.openWindow) private var openWindow
    @State private var showingEditor = false
    @State private var showingHealth = false
    @State private var showingSaveDialog = false
    @State private var newSearchName = ""
    @State private var showingPreview = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            table
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar { toolbarContent }
        .onChange(of: model.filter) { model.recompute() }
        .onChange(of: model.sort) { model.recompute() }
        .sheet(isPresented: $showingEditor) { TagEditorView(model: model) }
        .alert("Save Search", isPresented: $showingSaveDialog) {
            TextField("Name", text: $newSearchName)
            Button("Save") { model.saveCurrentSearch(name: newSearchName) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Save the current filters and text search as a reusable smart folder.")
        }
        .sheet(isPresented: $showingPreview) {
            PreviewSheet(selection: model.documentSelection()) {
                showingPreview = false
                openSelection()   // "Open" → jump to the full document window
            }
        }
        .navigationTitle("Archive Reader")
    }

    // MARK: Table

    private var table: some View {
        Table(model.displayed, selection: $model.selection) {
            TableColumn("⚑") { file in
                Button {
                    model.notes.setFlag(!model.notes.isFlagged(file.url.path), for: file.url.path)
                } label: {
                    Image(systemName: model.notes.isFlagged(file.url.path) ? "flag.fill" : "flag")
                        .foregroundStyle(model.notes.isFlagged(file.url.path) ? Color.orange : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Flag (app-only; never written to the file)")
            }
            .width(26)

            TableColumn("Document date") { file in
                Text(file.tags.displayDate ?? "—")
                    .italic(file.dateIsSpeculative)          // Date Uncertain → italic
                    .foregroundStyle(file.sortDate == nil ? .secondary : .primary)
            }
            .width(min: 110, ideal: 130)

            TableColumn("File name") { file in
                HStack(spacing: 6) {
                    if let color = file.color {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(color == .box ? .red : .purple)
                            .font(.system(size: 8))
                    }
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 320)

            TableColumn("Type") { file in Text(file.fileType).foregroundStyle(.secondary) }
                .width(min: 44, ideal: 56)

            TableColumn("File tags") { file in
                Text(displaySubjects(file)).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
            }
            .width(min: 160, ideal: 300)

            TableColumn("Priority") { file in
                Text(file.priority.map { "P\($0)" } ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 54, ideal: 64)

            TableColumn("Read") { file in
                Text(file.readState?.rawValue ?? "—")
                    .foregroundStyle(file.readState == .unread ? Color.accentColor : .secondary)
            }
            .width(min: 60, ideal: 74)
        }
        .contextMenu(forSelectionType: ArchiveFile.ID.self) { _ in
            Button("Open in Document View") { openSelection() }
            Button("Quick Look") { showingPreview = true }
            Button("Copy Link(s)") { model.copyLinks() }
            Divider()
            Button("Mark Read") { model.mark(.read) }
            Button("Mark Unread") { model.mark(.unread) }
            Button("Toggle Flag") { model.toggleFlagSelection() }
            Button("Edit Tags…") { showingEditor = true }
            Divider()
            Button("Select Document Run") { model.extendSelectionToDocumentRun() }
        } primaryAction: { _ in
            openSelection()   // double-click opens
        }
        .overlay { tableOverlay }
        // Focus-scoped Space → preview (fires only when the list has key focus, so Space still types
        // into the filter text fields).
        .onKeyPress(.space) {
            guard !model.selection.isEmpty else { return .ignored }
            showingPreview = true
            return .handled
        }
    }

    /// Status overlay on the results area so the user always knows what's happening — most importantly
    /// a spinner while Spotlight is finding/loading the tagged files for display.
    @ViewBuilder private var tableOverlay: some View {
        if model.rootStore.root == nil {
            ContentUnavailableView("No archive folder chosen", systemImage: "folder.badge.questionmark",
                                   description: Text("Choose a folder in the toolbar to browse its tagged PDFs."))
        } else if model.library.isGathering {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Finding tagged documents…").font(.headline).foregroundStyle(.secondary)
                Text("in \(model.library.scopeDescription)").font(.callout).foregroundStyle(.tertiary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else if model.displayed.isEmpty && !model.library.files.isEmpty {
            ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("No files match the current filters or search. Use Clear to reset."))
        } else if model.displayed.isEmpty {
            ContentUnavailableView("No tagged documents", systemImage: "tray",
                                   description: Text("No Read/Unread-tagged PDFs were found in this folder."))
        }
    }

    /// Subject tags plus date/priority tokens, comma-joined for the "File tags" column.
    private func displaySubjects(_ file: ArchiveFile) -> String {
        file.tags.raw
            .filter { $0.caseInsensitiveCompare("Read") != .orderedSame
                   && $0.caseInsensitiveCompare("Unread") != .orderedSame }
            .joined(separator: ", ")
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Read state", selection: $model.filter.read) {
                Text("All").tag(ReadFilter.all)
                Text("Unread").tag(ReadFilter.unread)
                Text("Read").tag(ReadFilter.read)
                Text("No read-state").tag(ReadFilter.noReadState)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .help("Filter the list by read state")

            HStack(spacing: 4) {
                ForEach([10, 9, 8, 7], id: \.self) { p in
                    Toggle("P\(p)", isOn: Binding(
                        get: { model.filter.priorities.contains(p) },
                        set: { on in
                            if on { model.filter.priorities.insert(p) } else { model.filter.priorities.remove(p) }
                        }))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Show only documents at priority P\(p)")
                }
            }

            subjectFilterField

            TextField("Filter file name…", text: $model.filter.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
                .help("Filter the list by file name")

            HStack(spacing: 3) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(model.ftsPaths != nil ? Color.accentColor : .secondary)
                TextField("Search OCR text…", text: $model.fullTextQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit { model.runFullTextSearch() }
                    .help("Search the full OCR text of documents (press Return)")
                if model.ftsPaths != nil {
                    Button { model.fullTextQuery = ""; model.runFullTextSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear full-text search")
                }
            }

            Spacer()

            if model.filter.isActive || model.ftsPaths != nil {
                Button("Clear") {
                    model.filter = LibraryFilter()
                    model.fullTextQuery = ""
                    model.runFullTextSearch()
                }
                .help("Clear all filters and searches")
            }
        }
        .padding(8)
    }

    @State private var subjectDraft = ""
    private var subjectFilterField: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.filter.subjects).sorted(), id: \.self) { subj in
                Button {
                    model.filter.subjects.remove(subj)
                } label: {
                    Label(subj, systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .help("Remove this subject filter")
            }
            TextField("Add subject filter…", text: $subjectDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit {
                    let s = subjectDraft.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { model.filter.subjects.insert(s) }
                    subjectDraft = ""
                }
                .help("Add a subject tag to filter by (press Return)")
            if model.filter.subjects.count > 1 {
                Picker("Match", selection: $model.filter.subjectCombine) {
                    Text("All").tag(SubjectCombine.all)
                    Text("Any").tag(SubjectCombine.any)
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .help("Match documents having all, or any, of the chosen subjects")
            }
        }
    }

    // MARK: Toolbar + status

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.chooseRoot()
            } label: { Label(rootLabel, systemImage: "folder") }
                .help("Choose which archive folder to browse")

            Menu {
                sortButton("Document date", .date)
                sortButton("File name", .name)
                sortButton("Priority", .priority)
                sortButton("Read state", .readState)
                Divider()
                Button("Default (date, then name)") { model.sort = LibrarySort.default }
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                .help("Choose how the document list is sorted")

            Menu {
                if model.savedSearches.searches.isEmpty {
                    Text("No saved searches")
                } else {
                    ForEach(model.savedSearches.searches) { s in
                        Button(s.name) { model.applySaved(s) }
                    }
                    Divider()
                    Menu("Delete") {
                        ForEach(model.savedSearches.searches) { s in
                            Button(s.name, role: .destructive) { model.savedSearches.delete(s.id) }
                        }
                    }
                }
                Divider()
                Button("Save Current Search…") { newSearchName = ""; showingSaveDialog = true }
            } label: { Label("Saved", systemImage: "bookmark") }
                .help("Apply, save, or delete a saved search (smart folder)")

            Button { openSelection() } label: { Label("Open", systemImage: "square.split.2x1") }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.selection.isEmpty)
                .help("Open the selected documents for reading (⌘O)")

            Button { showingPreview = true } label: { Label("Preview", systemImage: "eye") }
                .keyboardShortcut("y", modifiers: .command)   // also Space when the list has focus (see .onKeyPress)
                .disabled(model.selection.isEmpty)
                .help("Preview the selection 2-up without opening it (Space or ⌘Y)")

            Button { model.copyLinks() } label: { Label("Copy Links", systemImage: "link") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
                .help("Copy links to the selected files (⌘⇧C)")

            Button { model.mark(.read) } label: { Label("Mark Read", systemImage: "checkmark.circle") }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selection.isEmpty)
                .help("Mark the selected documents as read (⌘R)")

            Button { model.mark(.unread) } label: { Label("Mark Unread", systemImage: "circle") }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model.selection.isEmpty)
                .help("Mark the selected documents as unread (⌘U)")

            Button { showingEditor = true } label: { Label("Edit Tags", systemImage: "tag") }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.selection.isEmpty)
                .help("Edit tags for the selected documents (⌘I)")

            Button { model.toggleFlagSelection() } label: { Label("Flag", systemImage: "flag") }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.selection.isEmpty)
                .help("Flag or unflag the selection — app-only, never written to the file (⌘⇧F)")

            Button { model.undoLast() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.undoDepth == 0)
                .help("Undo the last tag change (⌘Z)")
        }
    }

    private func sortButton(_ title: String, _ field: SortField) -> some View {
        Button {
            // Toggle direction if already the primary field; else make it primary, name as tiebreak.
            if model.sort.first?.field == field {
                model.sort[0].ascending.toggle()
            } else {
                model.sort = [ARSortDescriptor(field: field, ascending: true),
                              ARSortDescriptor(field: .name, ascending: true)]
            }
        } label: {
            let arrow = model.sort.first?.field == field ? (model.sort.first!.ascending ? " ↑" : " ↓") : ""
            Text(title + arrow)
        }
    }

    private var rootLabel: String {
        model.rootStore.root?.lastPathComponent ?? "Choose Folder…"
    }

    private var statusBar: some View {
        HStack {
            if model.library.isGathering { ProgressView().controlSize(.small); Text("Searching…") }
            Text("\(model.displayed.count) shown · \(model.library.files.count) total in \(model.library.scopeDescription)")
                .foregroundStyle(.secondary)
            if let p = model.indexingProgress {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 70)
                Text("Indexing \(p.done)/\(p.total)").foregroundStyle(.secondary)
            }
            Button { showingHealth = true } label: { Image(systemName: "stethoscope") }
                .buttonStyle(.borderless)
                .help("Library health")
                .popover(isPresented: $showingHealth) { DataQualityView(q: model.dataQuality) }
            Spacer()
            if !model.statusMessage.isEmpty { Text(model.statusMessage).foregroundStyle(.secondary) }
            if !model.selection.isEmpty { Text("\(model.selection.count) selected").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func openSelection() {
        let sel = model.documentSelection()
        guard !sel.filePaths.isEmpty else { return }
        openWindow(id: WindowID.document, value: sel)
    }
}

/// A small library-health readout (data-quality counts).
private struct DataQualityView: View {
    let q: NavigationModel.DataQuality
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Library health").font(.headline)
            row("Total files", q.total)
            row("No date", q.noDate)
            row("No priority", q.noPriority)
            row("Date Uncertain", q.dateUncertain)
            row("Box/folder markers", q.markers)
            row("Both Read + Unread (corrupt)", q.bothReadUnread, warn: q.bothReadUnread > 0)
        }
        .padding(14)
        .frame(width: 260)
    }
    private func row(_ label: String, _ value: Int, warn: Bool = false) -> some View {
        HStack {
            Text(label); Spacer()
            Text("\(value)").foregroundStyle(warn ? .orange : .secondary).monospacedDigit()
        }
    }
}
