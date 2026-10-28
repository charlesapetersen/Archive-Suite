import SwiftUI
import AppKit

/// The reusable 3-pane browsing shell (folder tree │ item list │ detail), instantiated as the
/// Notes window and the Extracts window (06-viewers §1, W6-S1). W6-S2 swapped in the folder tree;
/// W6-S3 swaps in the item-list table (`NotesTableView`) + kind segmented control; the detail pane
/// hosts the shipped W3 editor (`NoteEditorPane`) with a selected-item header.
///
/// The shared `NotesModel` (org graph + item source, one instance for both windows) is passed in from
/// `ArchiveNotesApp`; each window owns a private `NotesNavigationModel` (@StateObject) seeded with its
/// default kind, so the two windows differ by kind/sort/selection while reading one item source.
///
/// Persistence (W6-S1): panel widths + tree-visibility survive relaunch via `@AppStorage`; window size
/// via `NotesAppSettings`; hidden item-list columns via `NotesAppSettings.hiddenColumns` (W6-S3).
struct NotesBrowserView: View {
    /// The shared UI façade (folder tree + scope + item source), passed from the app.
    @ObservedObject private var model: NotesModel
    /// Per-window item-list state (kind filter, sort, selection, displayed list).
    @StateObject private var nav: NotesNavigationModel

    @AppStorage(NotesLayoutSettingsKey.showTree)    private var showingTree = true
    @AppStorage(NotesLayoutSettingsKey.treeWidth)   private var treeWidth   = NotesLayoutSettings.defaultTreeWidth
    @AppStorage(NotesLayoutSettingsKey.detailWidth) private var detailWidth = NotesLayoutSettings.defaultDetailWidth

    @State private var window: NSWindow?
    @State private var didConfigureWindow = false
    @State private var selectedTemplateID: UUID?
    @EnvironmentObject private var flushRegistry: EditorFlushRegistry

    init(kind: ItemKindShell, model: NotesModel) {
        self._model = ObservedObject(wrappedValue: model)
        // `.standard` ⟹ this window's kind featuring is remembered across launches (W7-S4).
        self._nav = StateObject(wrappedValue: NotesNavigationModel(model: model, defaultKind: kind,
                                                                   persistingKindTo: .standard))
    }

    var body: some View {
        HStack(spacing: 0) {
            if showingTree {
                NotesFolderTreeView(model: model, nav: nav)
                    .frame(width: treeWidth)
                    .transition(.move(edge: .leading))
                PanelDivider(width: $treeWidth, panelOnLeft: true,
                             range: NotesLayoutSettings.treeWidthRange, label: "Folder list width",
                             id: "an.divider.tree")
            }
            ItemListPane(model: model, nav: nav, selectedTemplateID: $selectedTemplateID)
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider(width: $detailWidth, panelOnLeft: false,
                         range: NotesLayoutSettings.detailWidthRange, label: "Detail pane width",
                         id: "an.divider.detail")
            DetailPane(nav: nav, selectedTemplateID: $selectedTemplateID)
                .frame(width: detailWidth)
        }
        // The list needs 527 pt for its fixed filter controls in the VM; reserve 540 so its
        // minimum proposal agrees with what it actually draws. Without that floor SwiftUI reports
        // a 1053 pt window minimum but centres 1121 pt of panes inside it, clipping both edges.
        // Keep the floor on the LIST: the shell's minimum then follows the current sidebar/detail
        // widths and whether the sidebar is visible, rather than understating their total again.
        .frame(minHeight: 560)
        .animation(.easeInOut(duration: 0.18), value: showingTree)
        .background(indexReadyProbe)                               // hidden XCUITest index-ready signal (§3.4)
        .background(NotesWindowAccessor { configureWindow($0) })   // restore/remember window size (DV-1)
        .task { await model.bootstrap() }   // open the store + load organization + items (idempotent)
        .toolbar { toolbar }
        .onDisappear {
            if let w = window {
                NotesAppSettings.persistWindowSizeOnDisappear(
                    w.frame.size,
                    isUITestHarness: Self.isUITestHarness
                )
            }
        }
        // The mandatory delete confirmation (§3.6, W6-S5). Set by a guarded membership removal or
        // the whole-item context action; no note is deleted until the user confirms.
        .alert("Delete “\(nav.pendingDeletion?.title ?? "")”?",
               isPresented: Binding(get: { nav.pendingDeletion != nil },
                                    set: { if !$0 { nav.pendingDeletion = nil } }),
               presenting: nav.pendingDeletion) { pending in
            // Capture `pending` from the presentation value: SwiftUI clears the binding (→
            // pendingDeletion = nil) the instant a button is tapped, before this async Task runs.
            Button("Delete Note", role: .destructive) { Task { await nav.confirmDeletion(pending) } }
                .accessibilityIdentifier("an.dialog.deleteLastInstance.confirm")
            Button("Cancel", role: .cancel) { }
                .accessibilityIdentifier("an.dialog.deleteLastInstance.cancel")
        } message: { pending in
            if pending.allInstances {
                Text("This removes every folder placement for “\(pending.title)” and moves the note to the Trash.")
            } else {
                Text("This is the only remaining instance of “\(pending.title)” — deleting it moves the note to the Trash.")
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation { showingTree.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(showingTree ? "Hide Folders" : "Show Folders")
            .accessibilityIdentifier("an.toggleTree")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                // ⌘N: new item using the nearest-ancestor template of the current scope (§6), else blank.
                Button("New \(kindLabel)") {
                    newItem(from: model.effectiveTemplate(for: model.selectedFolderId)?.id)
                }
                .keyboardShortcut("n", modifiers: .command)
                Divider()
                Menu("New from Template") {
                    Button("Blank") { newItem(from: nil) }
                    let offered = model.templates(matching: nav.windowKind)
                    if !offered.isEmpty { Divider() }
                    ForEach(offered) { t in Button(t.name) { newItem(from: t.id) } }
                }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New \(kindLabel.lowercased())")
            .accessibilityIdentifier("an.toolbar.new")
        }
    }

#if DEBUG
    /// Live key-window state behind `keyWindowProbe` (W14.4 b). DEBUG-only, like the probe it backs.
    @State private var isKeyWindow = false

    /// XCUITest index-ready signal (08-testing §3.4). Present ONLY under the UITest harness
    /// (`-ANUITestStorePath`), mirroring `NoteEditorPane`'s control strip — a normal DEBUG run and
    /// Release carry no probe at all. Sits in `.background(...)` behind the opaque 3-pane content, so it
    /// is occluded (never visible to the user) yet stays in the accessibility tree.
    ///
    /// Its `accessibilityValue` is empty until the initial index build settles, then the completion
    /// token; the label mirrors the same state (`building` → `ready:<gen>`) so the harness can read
    /// either. Was a 1×1 `Color.clear` + `allowsHitTesting(false)` that XCUITest could NOT resolve —
    /// its value stayed empty across a 30 s poll (W8-S8). A normally-rendered `Text` with a stable,
    /// non-empty label reliably enters the a11y tree.
    @ViewBuilder
    private var indexReadyProbe: some View {
        if Self.isUITestHarness {
            Text(verbatim: model.isIndexReady ? "ready:\(model.indexGeneration)" : "building")
                .accessibilityIdentifier("an.status.indexReady")
                .accessibilityValue(model.isIndexReady ? String(model.indexGeneration) : "")
                .frame(height: 16)
            keyWindowProbe
        }
    }

    /// Hidden UITest probe for **which window is key** (W14.4 b — the jump/create-extract raise+focus).
    /// Both windows carry one under the same identifier, so a query scoped to a window
    /// (`win.descendants(…)["an.status.keyWindow"]`) answers *about that window*: `key:<Note|Extract>` when
    /// it holds key status, `notkey:<…>` otherwise. There is no other accessibility signal for front-ness —
    /// XCUITest exposes no `isMainWindow`/`isKeyWindow` on a window element — so without this a raise check
    /// can only assert the *selection* half and call the raise proven, which it would not be.
    /// Same shape as `indexReadyProbe` above (a normally-rendered `Text`, occluded behind the panes) for
    /// the same reason: a 1×1 clear view does not reliably resolve in the a11y tree.
    @ViewBuilder
    private var keyWindowProbe: some View {
        Text(verbatim: "\(isKeyWindow ? "key" : "notkey"):\(kindLabel)")
            .accessibilityIdentifier("an.status.keyWindow")
            .accessibilityValue(isKeyWindow ? "key" : "notkey")
            .frame(height: 16)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let w = note.object as? NSWindow, w === window { isKeyWindow = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if let w = note.object as? NSWindow, w === window { isKeyWindow = false }
            }
    }

    /// True when launched by the UITest harness (`-ANUITestStorePath`), mirroring the
    /// `NoteEditorPane` / `RootFolderStore` / `NotesTagProjector` gate.
    private static var isUITestHarness: Bool {
        if let p = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !p.isEmpty { return true }
        return false
    }
#else
    /// Release / non-UITest builds carry no probe (the harness is DEBUG-only).
    private var indexReadyProbe: some View { EmptyView() }
    private static var isUITestHarness: Bool { false }
#endif

    private var kindLabel: String { nav.windowKind == .extract ? "Extract" : "Note" }

    /// Create a new item in the current folder scope (system default when unscoped, §16.6), from
    /// `templateId` when given, then select it (leaving templates mode if active).
    private func newItem(from templateId: UUID?) {
        Task {
            if let templateId {
                await flushRegistry.flushAll()
                guard !model.hasFailedTemplateBodySave(templateId) else { return }
            }
            if let id = await model.newItem(kind: nav.windowKind, in: model.selectedFolderId, from: templateId) {
                nav.showingTemplates = false
                nav.selection = [id]
            }
        }
    }

    /// Restore the saved window frame on first appearance (centered on the active screen). Runs once
    /// per window (guarded), then keeps the handle so `onDisappear` persists the final size (DV-1).
    private func configureWindow(_ window: NSWindow) {
        guard !didConfigureWindow else { return }
        didConfigureWindow = true
        self.window = window
#if DEBUG
        // Seed the key-window probe: the first window is already key before the notification observers
        // attach, so waiting for a transition would report a permanent "notkey" for it (W14.4 b).
        isKeyWindow = window.isKeyWindow
#endif
        guard var size = NotesAppSettings.windowSize else { return }
        // A remembered frame may predate wider panes. Programmatic setFrame can bypass the drag
        // minimum; keep restoration inside the window's current content constraints as well.
        size.width = max(size.width, window.minSize.width)
        size.height = max(size.height, window.minSize.height)
        if abs(window.frame.width - size.width) > 2 || abs(window.frame.height - size.height) > 2 {
            var frame = window.frame
            frame.size = size
            if let vis = (window.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin = CGPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2)
            }
            window.setFrame(frame, display: true)
        }
    }
}

// MARK: - Item-list pane (W6-S3 · filter bar W6-S4)

/// Center pane: the filter bar (kind · keyword FTS · quality · tags · date range · Save/Clear, W6-S4)
/// above the virtualized item table — or, in templates mode (sidebar "Templates" row / a folder's
/// "Template ▸ Manage…"), the templates manager (W6-S6).
private struct ItemListPane: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var nav: NotesNavigationModel
    @AppStorage(DisplayCalendarSettings.enabledKey) private var calendarsEnabled = false
    @Binding var selectedTemplateID: UUID?

    var body: some View {
        Group {
            if nav.showingTemplates {
                TemplatesManagerView(model: model, nav: nav, selected: $selectedTemplateID)
            } else {
                VStack(spacing: 0) {
                    NotesFilterBar(nav: nav)
                    Divider()
                    NotesTableView(
                        model: nav,
                        selection: $nav.selection,
                        onDoubleClick: { /* focus/open in detail — dedicated editor window is a future step */ },
                        buildContextMenu: { sel in NotesItemContextMenu.make(nav: nav, selection: sel) },  // W6-S5
                        calendarsEnabled: calendarsEnabled
                    )
                    .accessibilityLabel("Notes")
                    .accessibilityIdentifier("an.list.table")
                    .overlay {
                        // Wait for the first index pass so an empty table during startup does not
                        // announce an empty library. The table stays mounted for stable selection
                        // and column state when the result set changes. An unopenable index still
                        // gets one: the list then comes from disk, so its emptiness is real, except
                        // for a keyword search, which says why it found nothing (W40.fix-notes-index-
                        // failure-empty). An incomplete index keeps the table bare, as before.
                        if model.isIndexReady && nav.displayed.isEmpty && showsEmptyStateForIndexHealth {
                            emptyState
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(nsColor: .textBackgroundColor))
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var indexUnavailable: Bool {
        if case .unavailable = model.indexFailure { return true }
        return false
    }

    private var showsEmptyStateForIndexHealth: Bool { model.indexFailure == nil || indexUnavailable }

    @ViewBuilder private var emptyState: some View {
        if indexUnavailable && !nav.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView("Search is unavailable", systemImage: "exclamationmark.magnifyingglass",
                                   description: Text("The search index can't be opened, so a keyword search "
                                                     + "finds nothing. Clear the search to see your notes."))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("an.list.empty.searchUnavailable")
        } else if model.allItems.isEmpty {
            ContentUnavailableView("No notes or extracts yet", systemImage: "note.text",
                                   description: Text("Press ⌘N, or click the pencil button in the toolbar, to create one."))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("an.list.empty.library")
        } else if let folder = selectedNormalFolder, folder.itemCount == 0 {
            ContentUnavailableView("Nothing in this folder", systemImage: "folder",
                                   description: Text("Create an item here or move one into this folder."))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("an.list.empty.folder")
        } else {
            ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Change the folder, kind, filters, or search to see more items."))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("an.list.empty.matches")
        }
    }

    private var selectedNormalFolder: NotesFolderNode? {
        guard let id = model.selectedFolderId else { return nil }
        func find(_ nodes: [NotesFolderNode]) -> NotesFolderNode? {
            for node in nodes {
                if node.id == id { return node }
                if let child = find(node.children) { return child }
            }
            return nil
        }
        return find(model.normalTree)
    }
}

// MARK: - Detail pane

/// Right pane: a compact header, the locations inspector, and the metadata inspector (date front-matter
/// plus the front-matter-backed Q1...Q3 mirror) for the currently-selected item, above the W3 editor.
/// They follow `nav.detailItemID`, not the selection, so they change in the same pass as the editor's body.
/// The header is the visible "selection → detail" signal (W6-S3). The editor is bound to the selected
/// item's body and autosaves through `NoteStore` (W7-S1a — `NoteEditorPane` + `NoteBodyEditorModel`).
private struct DetailPane: View {
    @ObservedObject var nav: NotesNavigationModel
    @AppStorage(DisplayCalendarSettings.enabledKey) private var calendarsEnabled = false
    @AppStorage(NotesLayoutSettingsKey.metadataCollapsed) private var metadataCollapsed = false
    @Binding var selectedTemplateID: UUID?

    var body: some View {
        Group {
            if nav.showingTemplates {
                VStack(spacing: 0) {
                    if let template = nav.model.templates.first(where: { $0.id == selectedTemplateID }) {
                        HStack {
                            Image(systemName: template.kind == .extract ? "quote.opening" : "doc.text")
                            Text(template.name).font(.headline).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    } else {
                        Text("No template selected")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    Divider()
                    TemplateBodyEditorPane(model: nav.model, templateID: selectedTemplateID)
                }
            } else {
                noteDetail
            }
        }
    }

    private var noteDetail: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                selectedHeader
                if let id = nav.detailItemID {
                    Divider()
                    LocationsInspector(nav: nav, itemId: id)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                if let summary = nav.detailSummary {
                    Divider()
                    metadataToggle
                    if !metadataCollapsed {
                        // Keep the editor the larger share at every window height (W40.fix-notes-editor-squeezed).
                        ScrollView {
                            NoteMetadataInspector(nav: nav, item: summary)
                        }
                        .frame(maxHeight: DetailPaneLayout.metadataMaxHeight(paneHeight: geo.size.height))
                        .accessibilityIdentifier("an.detail.metadataScroll")
                    }
                }
                Divider()
                NoteEditorPane(nav: nav)
            }
        }
    }

    /// Folds the metadata inspector away so the editor gets the whole pane below the locations.
    private var metadataToggle: some View {
        Button {
            metadataCollapsed.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: metadataCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 10)
                Text("Details").font(.caption.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .help(metadataCollapsed ? "Show the note's details" : "Hide the note's details to give the editor more room")
        .accessibilityLabel(metadataCollapsed ? "Show details" : "Hide details")
        .accessibilityIdentifier("an.detail.metadataToggle")
    }

    @ViewBuilder private var selectedHeader: some View {
        if let item = nav.detailSummary {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .extract ? "quote.opening" : "doc.text")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)   // decorative
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    ItemHeaderDates(item: item, calendarsEnabled: calendarsEnabled)
                    if item.quality != nil { Text(item.qualityStars).foregroundStyle(.yellow) }
                    if !item.authors.isEmpty {
                        Label(item.authors.joined(separator: ", "), systemImage: "person")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .accessibilityIdentifier("an.detail.header")
        } else {
            Text(nav.selection.count > 1 ? "\(nav.selection.count) items selected" : "No note selected")
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(nav.detailSwitchPending ? 0 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }
}

/// The detail header's date labels — the own date and the sent-with date, each in the item's display
/// calendar when Settings allows it (W24.cal1-toggle). Its own view so a headless render test can draw
/// exactly what the header draws.
struct ItemHeaderDates: View {
    let item: ItemSummary
    let calendarsEnabled: Bool

    var body: some View {
        if let d = item.displayDate(calendarsEnabled: calendarsEnabled) {
            Label(d, systemImage: "calendar").labelStyle(.titleAndIcon)
                .accessibilityIdentifier("an.detail.header.date")
        }
        if let s = item.displaySentWith(calendarsEnabled: calendarsEnabled) {
            Label("Sent with: \(s)", systemImage: "envelope").labelStyle(.titleAndIcon)
                .accessibilityIdentifier("an.detail.header.sentWith")
        }
    }
}
