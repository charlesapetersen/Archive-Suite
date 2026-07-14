import SwiftUI
import AppKit
import ArchiveCore

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
    let kind: ItemKindShell

    /// The shared UI façade (folder tree + scope + item source), passed from the app.
    @ObservedObject private var model: NotesModel
    /// Per-window item-list state (kind filter, sort, selection, displayed list).
    @StateObject private var nav: NotesNavigationModel

    @AppStorage(NotesLayoutSettingsKey.showTree)    private var showingTree = true
    @AppStorage(NotesLayoutSettingsKey.treeWidth)   private var treeWidth   = NotesLayoutSettings.defaultTreeWidth
    @AppStorage(NotesLayoutSettingsKey.detailWidth) private var detailWidth = NotesLayoutSettings.defaultDetailWidth

    @State private var window: NSWindow?
    @State private var didConfigureWindow = false

    init(kind: ItemKindShell, model: NotesModel) {
        self.kind = kind
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
                             range: NotesLayoutSettings.treeWidthRange, id: "an.divider.tree")
            }
            ItemListPane(model: model, nav: nav)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider(width: $detailWidth, panelOnLeft: false,
                         range: NotesLayoutSettings.detailWidthRange, id: "an.divider.detail")
            DetailPane(nav: nav)
                .frame(width: detailWidth)
        }
        .frame(minWidth: 900, minHeight: 560)
        .animation(.easeInOut(duration: 0.18), value: showingTree)
        .background(indexReadyProbe)                               // hidden XCUITest index-ready signal (§3.4)
        .background(NotesWindowAccessor { configureWindow($0) })   // restore/remember window size (DV-1)
        .task { await model.bootstrap() }   // open the store + load organization + items (idempotent)
        .toolbar { toolbar }
        .onDisappear { if let w = window { NotesAppSettings.setWindowSize(w.frame.size) } }
        // The mandatory delete-last-instance confirmation (§3.6, W6-S5). Set by a guarded membership
        // removal (Remove-from-folder / MOVE source-removal); no note is deleted until the user
        // confirms here. "Permanently" is the spec wording — the note actually moves to the Trash.
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
            Text("This is the only remaining instance of “\(pending.title)” — deleting it removes the note permanently.")
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

    /// A zero-footprint, visually-invisible accessibility probe the XCUITest harness polls (08-testing
    /// §3.4): its `accessibilityValue` is empty until the initial index build settles, then the
    /// completion token. Kept in the a11y tree (never `.accessibilityHidden`) and non-interactive so it
    /// resolves for tests without affecting users. The live poll runs under W8-S8 (GUI on).
    private var indexReadyProbe: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityIdentifier("an.status.indexReady")
            .accessibilityValue(model.isIndexReady ? String(model.indexGeneration) : "")
    }

    private var kindLabel: String { nav.windowKind == .extract ? "Extract" : "Note" }

    /// Create a new item in the current folder scope (system default when unscoped, §16.6), from
    /// `templateId` when given, then select it (leaving templates mode if active).
    private func newItem(from templateId: UUID?) {
        Task {
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
        guard let size = NotesAppSettings.windowSize else { return }
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

    var body: some View {
        Group {
            if nav.showingTemplates {
                TemplatesManagerView(model: model, nav: nav)
            } else {
                VStack(spacing: 0) {
                    NotesFilterBar(nav: nav)
                    Divider()
                    NotesTableView(
                        model: nav,
                        selection: $nav.selection,
                        onDoubleClick: { /* focus/open in detail — dedicated editor window is a future step */ },
                        buildContextMenu: { sel in NotesItemContextMenu.make(nav: nav, selection: sel) }  // W6-S5
                    )
                    .accessibilityIdentifier("an.list.table")
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Detail pane

/// Right pane: a compact header, the locations inspector, and the metadata inspector (date + quality,
/// W6-S7 — front-matter only, never a Finder tag) for the currently-selected item, above the W3 editor.
/// The header is the visible "selection → detail" signal (W6-S3). The editor is bound to the selected
/// item's body and autosaves through `NoteStore` (W7-S1a — `NoteEditorPane` + `NoteBodyEditorModel`).
private struct DetailPane: View {
    @ObservedObject var nav: NotesNavigationModel

    var body: some View {
        VStack(spacing: 0) {
            selectedHeader
            if let id = nav.selectedItemID {
                Divider()
                LocationsInspector(nav: nav, itemId: id)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            if let summary = nav.selectedSummary {
                Divider()
                NoteMetadataInspector(nav: nav, item: summary)   // date + quality (front-matter only, W6-S7)
            }
            Divider()
            NoteEditorPane(nav: nav)
        }
    }

    @ViewBuilder private var selectedHeader: some View {
        if let item = nav.selectedSummary {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .extract ? "quote.opening" : "doc.text")
                        .foregroundStyle(.secondary)
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let d = item.displayDate { Label(d, systemImage: "calendar").labelStyle(.titleAndIcon) }
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
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }
}
