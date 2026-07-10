import SwiftUI

/// The file-navigation window — a Finder-Smart-Folder-like browser over the tagged corpus.
struct NavigationWindowView: View {
    @StateObject private var model = NavigationModel()
    @Environment(\.openWindow) private var openWindow
    @State private var showingHealth = false
    @AppStorage("ar.showTagCloud") private var showingTagCloud = false
    @AppStorage("ar.showSidebar") private var showingSidebar = true
    @AppStorage("ar.sidebarWidth") private var sidebarWidth = 210.0
    @AppStorage("ar.tagCloudWidth") private var tagCloudWidth = 240.0
    @AppStorage("ar.listFontSize") private var listFontSize = 13.0   // C3 row density / readability
    @State private var newSearchName = ""
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool     // C5: ⌥⌘F focuses OCR search
    @State private var tagFilterFocusToken = 0       // C5: ⌘L focuses the tag filter

    var body: some View {
        HStack(spacing: 0) {
            if showingSidebar {
                SidebarView(model: model)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))
                PanelDivider(width: $sidebarWidth, panelOnLeft: true, range: 140...350)
            }
            VStack(spacing: 0) {
                filterBar
                Divider()
                HStack(spacing: 0) {
                    table
                    if showingTagCloud {
                        PanelDivider(width: $tagCloudWidth, panelOnLeft: false, range: 160...400)
                        tagCloudPanel
                            .transition(.move(edge: .trailing))
                    }
                }
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .animation(.easeInOut(duration: 0.2), value: showingSidebar)
        .animation(.easeInOut(duration: 0.2), value: showingTagCloud)
        .toolbar { toolbarContent }
        .onChange(of: model.filter) { model.recompute() }
        .onChange(of: model.sort) { model.recompute() }
        .sheet(isPresented: $model.showingEditor) { TagEditorView(model: model) }
        .sheet(isPresented: Binding(get: { model.renamingTag != nil },
                                    set: { if !$0 { model.renamingTag = nil } })) {
            if let t = model.renamingTag { RenameTagSheet(model: model, oldTag: t) }
        }
        .sheet(isPresented: $model.showingSimilarTags) { SimilarTagsSheet(model: model) }
        .alert("Save Search", isPresented: $model.showingSaveDialog) {
            TextField("Name", text: $newSearchName)
            Button("Save") { model.saveCurrentSearch(name: newSearchName) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Save the current filters and text search as a reusable smart folder.")
        }
        // Pre-fill the save name from the active filters whenever the dialog opens.
        .onChange(of: model.showingSaveDialog) { _, showing in
            if showing { newSearchName = model.suggestedSmartFolderName }
        }
        .alert("Rename Smart Folder", isPresented: Binding(
            get: { model.renamingSearch != nil },
            set: { if !$0 { model.renamingSearch = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let s = model.renamingSearch { model.savedSearches.rename(s.id, to: renameText) }
                model.renamingSearch = nil
            }
            Button("Cancel", role: .cancel) { model.renamingSearch = nil }
        }
        .onChange(of: model.renamingSearch) { _, s in if let s { renameText = s.name } }
        .onChange(of: model.focusSearchRequest) { searchFocused = true }              // C5 ⌥⌘F
        .onChange(of: model.focusTagFilterRequest) { tagFilterFocusToken &+= 1 }       // C5 ⌘L
        .sheet(isPresented: $model.showingPreview) {
            PreviewSheet(selection: model.documentSelection(), nav: model) {
                model.showingPreview = false
                openSelection()   // "Open" → jump to the full document window
            }
        }
        .navigationTitle("Archive Reader")
        .focusedSceneObject(model)
        .focusedSceneValue(\.openSelection) { openSelection() }
    }

    // MARK: Table (AppKit NSTableView for virtualized, high-performance scrolling at scale)

    private var table: some View {
        AppKitTableView(
            model: model,
            selection: $model.selection,
            fontSize: listFontSize,
            scrollRequest: model.scrollRequest,
            scrollTargetID: model.scrollTargetID,
            onDoubleClick: { openSelection() },
            buildContextMenu: { _ in buildNSContextMenu() }
        )
        .overlay { tableOverlay }
        // Focus-scoped Space → preview (fires only when the list has key focus, so Space still types
        // into the filter text fields).
        .onKeyPress(.space) {
            guard !model.selection.isEmpty else { return .ignored }
            model.showingPreview = true
            return .handled
        }
        // G4 keyboard triage — a focus-scoped key cluster (fires only when the list has key focus, so it
        // never triggers while typing in the filter / search fields, and bare keys don't shadow the ⌘
        // menu accelerators). Physical cluster on a US layout: [ = previous unread, ] = next unread,
        // \ = mark read & advance.
        .onKeyPress(characters: CharacterSet(charactersIn: "[]\\"), phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            switch press.characters {
            case "]":  model.selectNextUnread();     return .handled
            case "[":  model.selectPreviousUnread(); return .handled
            case "\\": model.markReadAndAdvance();    return .handled
            default:   return .ignored
            }
        }
    }

    /// Build an NSMenu for the table's right-click context menu (bridges SwiftUI actions to AppKit).
    private func buildNSContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open in Document View", action: #selector(ContextMenuActions.openInDocView), keyEquivalent: "")
        menu.addItem(withTitle: "Preview", action: #selector(ContextMenuActions.preview), keyEquivalent: "")
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(ContextMenuActions.revealInFinder), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Default App", action: #selector(ContextMenuActions.openInDefaultApp), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Link(s)", action: #selector(ContextMenuActions.copyLinks), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Mark Read", action: #selector(ContextMenuActions.markRead), keyEquivalent: "")
        menu.addItem(withTitle: "Mark Unread", action: #selector(ContextMenuActions.markUnread), keyEquivalent: "")
        menu.addItem(withTitle: "Toggle Flag", action: #selector(ContextMenuActions.toggleFlag), keyEquivalent: "")
        menu.addItem(withTitle: "Edit Tags…", action: #selector(ContextMenuActions.editTags), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select Document Run", action: #selector(ContextMenuActions.selectDocRun), keyEquivalent: "")

        // Wire each item's target to a trampoline that captures the model.
        let trampoline = ContextMenuActions(model: model, openSelection: { openSelection() })
        // Prevent deallocation during menu tracking by retaining via objc association.
        objc_setAssociatedObject(menu, "trampoline", trampoline, .OBJC_ASSOCIATION_RETAIN)
        for item in menu.items where !item.isSeparatorItem {
            item.target = trampoline
        }
        return menu
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
    // MARK: Tag cloud (right margin)

    private var tagCloudPanel: some View {
        let cloud = model.tagCloud
        let maxCount = max(1, cloud.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tags in view").font(.headline)
                Spacer()
                Text("\(cloud.count)").foregroundStyle(.secondary).font(.caption)
            }
            .padding(10)
            Divider()
            if cloud.isEmpty {
                Text("No tags in the current view.")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    FlowLayout(spacing: 8) {
                        ForEach(cloud, id: \.tag) { item in
                            let active = model.filter.subjects.contains(item.tag)
                            Button {
                                if active { model.filter.subjects.remove(item.tag) }
                                else { model.filter.subjects.insert(item.tag) }
                            } label: {
                                Text(item.tag)
                                    .font(.system(size: tagCloudFontSize(item.count, max: maxCount)))
                                    .foregroundStyle(active ? Color.accentColor : .primary)
                            }
                            .buttonStyle(.plain)
                            .help("\(item.count) file\(item.count == 1 ? "" : "s") · click to \(active ? "remove" : "add") as a tag filter")
                            .contextMenu {
                                Button(active ? "Remove from tag filter" : "Add to tag filter") {
                                    if active { model.filter.subjects.remove(item.tag) }
                                    else { model.filter.subjects.insert(item.tag) }
                                }
                                Button("Filter to only this tag") { model.filter.subjects = [item.tag] }
                                Button("Rename tag…") { model.renamingTag = item.tag }
                                Button("Find similar tags…") { model.showingSimilarTags = true }
                                if model.filter.subjects.count > 1 {
                                    Picker("Match tags", selection: $model.filter.subjectCombine) {
                                        Text("All").tag(SubjectCombine.all)
                                        Text("Any").tag(SubjectCombine.any)
                                    }
                                }
                                Divider()
                                Button("Select files with this tag") { model.selectFiles(withTag: item.tag) }
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: tagCloudWidth)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Map a tag's file-count to a font size (11…26 pt) using **logarithmic** scaling so high-count
    /// outliers don't crush mid-range tags into uniformly tiny text.
    /// Gradient at maxCount=1000: count 1→11pt, 10→16pt, 100→21pt, 1000→26pt.
    private func tagCloudFontSize(_ count: Int, max maxCount: Int) -> CGFloat {
        guard maxCount > 1 else { return 14 }
        let ratio = log(Double(max(1, count))) / log(Double(maxCount))
        return 11 + CGFloat(ratio) * 15
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Read state", selection: $model.filter.read) {
                Text("All").tag(ReadFilter.all)
                Text("Unread").tag(ReadFilter.unread)
                Text("Read").tag(ReadFilter.read)
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

            TextField("Filter file name…", text: $model.filterSearchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
                .help("Filter the list by file name")

            HStack(spacing: 3) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(model.ftsPaths != nil ? Color.accentColor : .secondary)
                TextField("Search OCR text…", text: $model.fullTextQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .focused($searchFocused)
                    .help("Search the full OCR text of documents")
                if model.ftsPaths != nil {
                    Button { model.fullTextQuery = ""; model.runFullTextSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear full-text search")
                }
            }

            if model.needsAttentionCount > 0 {
                Toggle(isOn: $model.filter.needsAttentionOnly) {
                    Label("\(model.needsAttentionCount) need attention", systemImage: "exclamationmark.triangle")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show only non-standard PDFs — files that couldn't be opened, or have no selectable text")
            }

            Spacer()

            if model.filter.isActive || model.filterSearchText.trimmingCharacters(in: .whitespaces) != "" || model.ftsPaths != nil {
                Button("Save as Smart Folder") { model.showingSaveDialog = true }
                    .help("Save these filters as a smart folder in the sidebar")
                Button("Clear") { model.clearUserFilters() }
                    .help(model.scope != nil ? "Clear user filters (return to smart folder)" : "Clear all filters and searches")
            }
        }
        .padding(8)
    }

    /// Existing tags offered for autocomplete — the library's distinct topical tags, minus any already
    /// chosen. (`allSubjects` is the deduped topical-tag set the model already maintains.)
    private var tagSuggestions: [String] {
        model.allSubjects.filter { !model.filter.subjects.contains($0) && !DocumentTags.isDateFacetLike($0) }
    }
    private var subjectFilterField: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.filter.subjects).sorted(), id: \.self) { subj in
                Button {
                    model.filter.subjects.remove(subj)
                } label: {
                    Label(subj, systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .help("Remove this tag filter")
            }
            TagFilterField(placeholder: "Add tag filter…", suggestions: tagSuggestions,
                           focusToken: tagFilterFocusToken) { tag in
                model.filter.subjects.insert(tag)
            }
            .frame(width: 160)
            .help("Filter by tag — type to autocomplete existing tags; Return adds it")
            if model.filter.subjects.count > 1 {
                Picker("Match", selection: $model.filter.subjectCombine) {
                    Text("All").tag(SubjectCombine.all)
                    Text("Any").tag(SubjectCombine.any)
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                .help("Match documents having all, or any, of the chosen tags")
            }
        }
    }

    // MARK: Toolbar + status

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { showingSidebar.toggle() } label: {
                Label("Sidebar", systemImage: "sidebar.left")
            }
            .help("Show or hide the folder sidebar")

            Button {
                model.chooseRoot()
            } label: { Label(rootLabel, systemImage: "folder") }
                .help("Choose which archive folder to browse")

            Menu {
                if model.savedSearches.searches.isEmpty {
                    Text("No saved searches")
                } else {
                    ForEach(model.savedSearches.searches) { s in
                        Button(s.name) { model.applyScope(s) }
                    }
                    Divider()
                    Menu("Delete") {
                        ForEach(model.savedSearches.searches) { s in
                            Button(s.name, role: .destructive) { model.savedSearches.delete(s.id) }
                        }
                    }
                }
                Divider()
                Button("Save Current Search…") { newSearchName = ""; model.showingSaveDialog = true }
            } label: { Label("Saved", systemImage: "bookmark") }
                .help("Apply, save, or delete a saved search (smart folder)")

            Button { showingTagCloud.toggle() } label: {
                Label("Tag Cloud", systemImage: "tag.square")
            }
            .help("Show a tag cloud of the visible files — larger tags appear on more files (click to filter)")

            Button { openSelection() } label: { Label("Open", systemImage: "square.split.2x1") }
                .disabled(model.selection.isEmpty)
                .help("Open the selected documents for reading (⌘O)")

            Button { model.showingPreview = true } label: { Label("Preview", systemImage: "eye") }
                .disabled(model.selection.isEmpty)
                .help("Preview the selection 2-up without opening it (Space or ⌘Y)")

            Button { model.copyLinks() } label: { Label("Copy Links", systemImage: "link") }
                .disabled(model.selection.isEmpty)
                .help("Copy links to the selected files (⌘⇧C)")

            Button { model.mark(.read) } label: { Label("Mark Read", systemImage: "checkmark.circle") }
                .disabled(model.selection.isEmpty)
                .help("Mark the selected documents as read (⌘R)")

            Button { model.mark(.unread) } label: { Label("Mark Unread", systemImage: "circle") }
                .disabled(model.selection.isEmpty)
                .help("Mark the selected documents as unread (⌘U)")

            Button { model.showingEditor = true } label: { Label("Edit Tags", systemImage: "tag") }
                .disabled(model.selection.isEmpty)
                .help("Edit tags for the selected documents (⌘I)")

            Button { model.toggleFlagSelection() } label: { Label("Flag", systemImage: "flag") }
                .disabled(model.selection.isEmpty)
                .help("Flag or unflag the selection — app-only, never written to the file (⌘⇧F)")

            Button { model.undoLast() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(model.undoDepth == 0)
                .help("Undo the last tag change (⌘Z)")
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
            if let summary = model.activeFilterSummary {
                Text("· \(summary)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help("Active filter")
            }
            if let p = model.indexingProgress {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 70)
                Text("Indexing \(p.done)/\(p.total)").foregroundStyle(.secondary)
            }
            Button { showingHealth = true } label: { Image(systemName: "stethoscope") }
                .buttonStyle(.borderless)
                .help("Library health")
                .popover(isPresented: $showingHealth) { DataQualityView(q: model.dataQuality, needsAttention: model.needsAttentionCount) }
            Spacer()
            if !model.statusMessage.isEmpty { Text(model.statusMessage).foregroundStyle(.secondary) }
            if !model.selection.isEmpty { Text("\(model.selection.count) selected").foregroundStyle(.secondary) }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func openSelection() {
        // Always dismiss the preview sheet first, so the single ⌘O owner is this path whether it was
        // triggered by the Selection-menu ⌘O (which stays enabled over the sheet) or the sheet's own
        // Open button — otherwise the menu shortcut opens the doc window but orphans the sheet.
        model.showingPreview = false
        let sel = model.documentSelection()
        guard !sel.filePaths.isEmpty else { return }
        openWindow(id: WindowID.document, value: sel)
    }
}

/// A thin divider that can be dragged to resize an adjacent panel.
private struct PanelDivider: View {
    @Binding var width: Double
    /// `true` when the resizable panel is to the left of this divider (sidebar).
    let panelOnLeft: Bool
    let range: ClosedRange<CGFloat>

    @State private var startWidth: CGFloat?

    var body: some View {
        Color(nsColor: .separatorColor)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if startWidth == nil { startWidth = CGFloat(width) }
                        let delta = panelOnLeft
                            ? value.translation.width
                            : -value.translation.width
                        let clamped = min(range.upperBound, max(range.lowerBound,
                                          (startWidth ?? CGFloat(width)) + delta))
                        width = Double(clamped)
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// A small library-health readout (data-quality counts).
private struct DataQualityView: View {
    let q: NavigationModel.DataQuality
    let needsAttention: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Library health").font(.headline)
            row("Total files", q.total)
            row("No date", q.noDate)
            row("No priority", q.noPriority)
            row("Date Uncertain", q.dateUncertain)
            row("Box/folder markers", q.markers)
            row("Both Read + Unread (corrupt)", q.bothReadUnread, warn: q.bothReadUnread > 0)
            row("Non-standard PDFs (need attention)", needsAttention, warn: needsAttention > 0)
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

/// A simple wrapping flow layout (left-aligned, wraps to the next row when the width is exceeded).
/// Used by the tag cloud (word-cloud) and the inline tag-editor popover (removable chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : x, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// NSObject trampoline for the AppKit context menu — routes `NSMenuItem` actions to
/// `NavigationModel` methods. Retained by the `NSMenu` via `objc_setAssociatedObject`.
@MainActor
final class ContextMenuActions: NSObject {
    let model: NavigationModel
    let openSelection: () -> Void
    init(model: NavigationModel, openSelection: @escaping () -> Void) {
        self.model = model; self.openSelection = openSelection
    }
    @objc func openInDocView()    { openSelection() }
    @objc func preview()          { model.showingPreview = true }
    @objc func revealInFinder()   { model.revealInFinder() }
    @objc func openInDefaultApp() { model.openInDefaultApp() }
    @objc func copyLinks()        { model.copyLinks() }
    @objc func markRead()         { model.mark(.read) }
    @objc func markUnread()       { model.mark(.unread) }
    @objc func toggleFlag()       { model.toggleFlagSelection() }
    @objc func editTags()         { model.showingEditor = true }
    @objc func selectDocRun()     { model.extendSelectionToDocumentRun() }
}
