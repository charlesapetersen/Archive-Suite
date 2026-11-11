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
///
/// Two layouts (W48.notes-stacked-layout, View menu): side by side, or the list above the note with a horizontal
/// divider. The tree stays on the left in both. The list, divider and detail sit in one `AnyLayout`, so a switch
/// changes only how they are arranged: the editor is not rebuilt, and its selection, unsaved text and scroll
/// position stay.
///
/// The inspector (W40.notes-detail-layout; owner session notes-1 rows 20, 21, 32) is a panel at the window's right,
/// outside that layout, so in the stacked layout it runs the full height beside the list and the note. View ▸ Show
/// Inspector (⌥⌘I) and the toolbar's right-hand button open and close it; open or closed and its width are
/// remembered, like the folder list's.
struct NotesBrowserView: View {
    /// The shared UI façade (folder tree + scope + item source), passed from the app.
    @ObservedObject private var model: NotesModel
    /// Per-window item-list state (kind filter, sort, selection, displayed list).
    @StateObject private var nav: NotesNavigationModel

    @AppStorage(NotesLayoutSettingsKey.showTree)    private var showingTree = true
    @AppStorage(NotesLayoutSettingsKey.treeWidth)   private var treeWidth   = NotesLayoutSettings.defaultTreeWidth
    @AppStorage(NotesLayoutSettingsKey.detailWidth) private var detailWidth = NotesLayoutSettings.defaultDetailWidth
    @AppStorage(NotesLayoutSettingsKey.layoutMode)  private var layoutMode: NotesLayoutMode = .sideBySide
    @AppStorage(NotesLayoutSettingsKey.listHeight)  private var listHeight  = NotesLayoutSettings.defaultListHeight
    @AppStorage(NotesLayoutSettingsKey.showInspector)  private var showingInspector = true
    @AppStorage(NotesLayoutSettingsKey.inspectorWidth) private var inspectorWidth = NotesLayoutSettings.defaultInspectorWidth

    /// The right-hand panes' height, so the stacked list gives way before the note is squeezed.
    @State private var panesHeight = 0.0
    @State private var window: NSWindow?
    @State private var didConfigureWindow = false
    @State private var selectedTemplateID: UUID?
    @EnvironmentObject private var flushRegistry: EditorFlushRegistry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

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
                PanelDivider(size: $treeWidth, panelBefore: true,
                             range: NotesLayoutSettings.treeWidthRange, label: "Folder list width",
                             id: "an.divider.tree")
            }
            let stacked = layoutMode == .stacked
            let panes = stacked ? AnyLayout(StackedPanesLayout(listHeight: listHeight))
                                : AnyLayout(HStackLayout(spacing: 0))
            panes {
                ItemListPane(model: model, nav: nav, selectedTemplateID: $selectedTemplateID)
                    .frame(minWidth: NotesLayoutSettings.listMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()   // never drawn outside its share, under the toolbar or the note
                PanelDivider(size: stacked ? $listHeight : $detailWidth, panelBefore: stacked,
                             axis: stacked ? .vertical : .horizontal,
                             range: stacked ? NotesLayoutSettings.stackedListRange(paneHeight: panesHeight)
                                            : NotesLayoutSettings.detailWidthRange,
                             label: stacked ? "Item list height" : "Detail pane width",
                             id: stacked ? "an.divider.list" : "an.divider.detail")
                DetailPane(nav: nav, selectedTemplateID: $selectedTemplateID)
                    // Opaque, like the list: stacked, the shell's centre (where the UITest probes sit) is here.
                    .background(Color(nsColor: .windowBackgroundColor))
                    .frame(width: stacked ? nil : detailWidth)
            }
            // Only the divider's range reads this; the stacked height itself is cut by `StackedPanesLayout` while
            // it places the panes, so no state written here feeds back into layout (a feedback loop through the
            // list's frame crashed AppKit's layout pass on an animated tree toggle).
            .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { panesHeight = $0 }
            if showingInspector {
                PanelDivider(size: $inspectorWidth, panelBefore: false,
                             range: NotesLayoutSettings.inspectorWidthRange, label: "Inspector width",
                             id: "an.divider.inspector")
                NoteInspectorPanel(nav: nav, selectedTemplateID: selectedTemplateID)
                    .frame(width: inspectorWidth)
            }
        }
        // The list needs 527 pt for its fixed filter controls in the VM; reserve 540 so its
        // minimum proposal agrees with what it actually draws. Without that floor SwiftUI reports
        // a 1053 pt window minimum but centres 1121 pt of panes inside it, clipping both edges.
        // Keep the floor on the LIST: the shell's minimum then follows the current sidebar/detail
        // widths and whether the sidebar is visible, rather than understating their total again.
        // Stacked, the list's floor and the note's must both fit (W48.notes-stacked-layout); since the note's fields
        // moved to the inspector that is less than the side-by-side floor, which then holds (W40.notes-detail-layout).
        .frame(minHeight: max(560, layoutMode == .stacked ? NotesLayoutSettings.stackedMinHeight : 0))
        .overlay(alignment: .top) { TitleBarBackdrop() }   // W40.fix-notes-titlebar-label
        .animation(.easeInOut(duration: 0.18), value: showingTree)
        // Open the inspector in one layout pass. Animating the shell repeatedly resizes/reflows TextKit and
        // triggers its resize scroll restoration, making the note move rapidly (especially when stacked).
        .animation(nil, value: showingInspector)
        .background(indexReadyProbe)                               // hidden XCUITest index-ready signal (§3.4)
        .background(NotesWindowAccessor { configureWindow($0) })   // restore/remember window size (DV-1)
        .task { await model.bootstrap() }   // open the store + load organization + items (idempotent)
        .task(id: model.isIndexReady) {
            // A second window can finish bootstrap() while the first is still loading. Sweep only
            // after a settled snapshot, never permanently consume the sweep on that empty list.
            guard model.isIndexReady else { return }
            await flushRegistry.sweepSavedCopies(noteIDs: model.allItems.map(\.id)) { await model.loadBody(for: $0) }
        }
        .toolbar { toolbar }
        .focusedSceneValue(\.newItemAction, NewItemAction(perform: { newItem(kind: $0, from: .folderDefault) },
                                                           newTemplate: { showNewTemplate() }))
        .focusedSceneValue(\.advancedSearchAction, AdvancedSearchAction(open: { openAdvancedSearch() }))
        .focusedSceneValue(\.deleteItemAction, nav.deletableSelection.map { id in
            DeleteItemAction(perform: { nav.requestDeleteItem(id) })
        })
        .sheet(item: $nav.advancedSearchRequest) { request in
            NotesAdvancedSearchSheet(nav: nav, request: request)
        }
        // File ▸ New Template… with no window open opened this one for it; the Extracts window leaves it alone.
        .onReceive(model.$pendingNewTemplate) { pending in
            guard pending, nav.windowKind == .note else { return }
            DispatchQueue.main.async {
                guard model.pendingNewTemplate else { return }
                model.pendingNewTemplate = false
                showNewTemplate()
            }
        }
        // Templates mode mounts no `NoteEditorPane`, so nothing in this window would act on an open
        // request; handle it here instead (W40.fix-notes-jump-pending-template). The delivered value,
        // since `@Published` emits in `willSet`; an initial pending value covers a window just opened.
        .onReceive(model.$pendingOpen) { handleOpenWhileShowingTemplates($0) }
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
            Button("Delete Note", role: .destructive) {
                Task {
                    // Edit ▸ Undo puts the note back, only once it is really in the Trash, and Redo deletes
                    // it again (W40.fix-notes-delete-undo, -redo). The window's manager, which the note
                    // table answers to.
                    guard await nav.confirmDeletion(pending), let undo = window?.undoManager ?? undoManager else { return }
                    nav.registerUndoOfDelete(pending.itemId, title: pending.title, with: undo)
                }
            }
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
        // Which window this is, in words: the kind picker can show notes in the Extracts window, which then
        // looks like the Notes window (W40.fix-notes-new-note, notes-1 row 39).
        ToolbarItem(placement: .navigation) {
            Label(nav.windowKind == .extract ? "Extracts" : "Notes",
                  systemImage: nav.windowKind == .extract ? "quote.opening" : "doc.text")
                .labelStyle(.titleAndIcon)
                .font(.headline)
                // A bare label ran to the edge of the toolbar's pill on macOS 26+ (notes-2 row 3); the inset gives it
                // the room a button's own padding gives the sidebar button beside it.
                .padding(.horizontal, 8)
                .help(nav.windowKind == .extract ? "The Extracts window" : "The Notes window")
                .accessibilityIdentifier("an.toolbar.windowKind")
        }
        ToolbarItem(placement: .primaryAction) {
            // Both kinds from either window, the window's own first. The menu bar's File ▸ New Note (⌘N) and
            // New Extract (⌥⌘N) carry the keys, so none is bound here (it never fired from a toolbar menu).
            Menu {
                ForEach(kindsOwnFirst, id: \.self) { kind in
                    Button("New \(Self.label(kind))") { newItem(kind: kind, from: .folderDefault) }
                }
                Divider()
                Menu("New from Template") {
                    ForEach(kindsOwnFirst, id: \.self) { kind in
                        Section {
                            Button("Blank \(Self.label(kind))") { newItem(kind: kind, from: .blank) }
                            ForEach(model.templates(matching: kind)) { t in
                                Button(t.name) { newItem(kind: kind, from: .template(t.id)) }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New note or extract")
            .accessibilityIdentifier("an.toolbar.new")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingInspector.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help(showingInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            .accessibilityLabel(showingInspector ? "Hide Inspector" : "Show Inspector")
            .accessibilityIdentifier("an.inspector.toggle")
        }
    }

    /// This window's kind first, then the other.
    private var kindsOwnFirst: [Item.Kind] { nav.windowKind == .extract ? [.extract, .note] : [.note, .extract] }

    private static func label(_ kind: Item.Kind) -> String { kind == .extract ? "Extract" : "Note" }

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
    /// An open request while this window's panes show the templates manager. A target this window
    /// selects leaves templates mode, one main-loop turn later so the request is stored by then: the
    /// note editor pane mounts and its `onAppear` handles and consumes it. A deleted target is
    /// reported here and the other kind's window is opened from here, so neither leaves the template
    /// being edited. Outside templates mode the mounted `NoteEditorPane` handles every request.
    private func handleOpenWhileShowingTemplates(_ req: NotesModel.OpenRequest?) {
        // The Trash shows no note editor either, so it takes the same path (W40.fix-notes-delete-undo).
        guard nav.paneMode != .notes, let req else { return }
        let action = NotePassageResolve.openAction(forItemID: req.id, block: req.block,
                                                   among: model.allItems, windowKind: nav.windowKind)
        if NotePassageResolve.leavesTemplatesMode(for: action) {
            DispatchQueue.main.async { nav.showingTemplates = false }
            return
        }
        switch action {
        case .reportSourceMissing:
            model.statusMessage = NotePassageResolve.sourceMissingStatus
            DispatchQueue.main.async { model.consumeOpen() }
        case let .openFeaturingWindow(kind):
            let windowID = kind == .extract ? NotesWindowID.extracts : NotesWindowID.notes
            DispatchQueue.main.async { openWindow(id: windowID) }
        case .selectAndScroll, .ignore:
            break
        }
    }

    /// The templates manager, with its New Template sheet open (W40.fix-notes-templates).
    /// Edit ▸ Advanced Search… and the filter bar's Advanced Search button (W40.notes-advanced-search).
    private func openAdvancedSearch() { nav.openAdvancedSearch() }

    private func showNewTemplate() {
        nav.showingTemplates = true
        nav.newTemplateRequested = true
    }

    /// What a new item starts from: the folder's template of its kind (§6), Blank, or a chosen template.
    enum NewItemSource { case folderDefault, blank, template(UUID) }

    /// Create a `kind` item in the current folder scope (system default when unscoped, §16.6). This window's kind
    /// is selected here, leaving templates mode if active; the other kind goes through the open channel to the
    /// window featuring it, opened if closed (`NoteEditorPane.handleOpen`).
    private func newItem(kind: Item.Kind, from source: NewItemSource) {
        let templateId: UUID?
        switch source {
        case .folderDefault: templateId = model.defaultTemplateID(for: kind, in: model.selectedFolderId)
        case .blank: templateId = nil
        case let .template(id): templateId = id
        }
        Task {
            guard let id = await NewItemFlow.create(kind: kind, from: templateId, model: model,
                                                    flushing: flushRegistry) else { return }
            if kind == nav.windowKind {
                nav.showingTemplates = false
                nav.selection = [id]
            } else {
                model.openItem(id: id, block: nil)
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

/// One even background behind the window title, as in the Reader (W40.fix-notes-titlebar-label; notes-2 row 3, after
/// W40.fix-reader-titlebar-gradient). On macOS 27 the title bar is see-through and the folder list's sidebar material
/// runs up under it, so "Archive Notes" sat half on grey and half on the window's white. This fills the window's top
/// safe-area inset (the title bar) with the window background, over the content and under the title, traffic lights
/// and toolbar. On macOS 26, whose bar is opaque, nothing shows.
private struct TitleBarBackdrop: View {
    var body: some View {
        // The reader respects the safe area, so its proxy reports the inset (one that ignores it reports none); the colour is
        // then drawn that far above the content, over the title bar.
        GeometryReader { g in
            Color(nsColor: .windowBackgroundColor)
                .frame(width: g.size.width, height: g.safeAreaInsets.top)
                .offset(y: -g.safeAreaInsets.top)
        }
        .allowsHitTesting(false)   // the title bar still drags the window
        .accessibilityHidden(true)
    }
}

// MARK: - Stacked panes (W48.notes-stacked-layout)

/// The stacked arrangement of the list, the divider and the note: the list on top at its remembered height, cut while
/// placing so the note keeps `stackedDetailMinHeight` (`NotesLayoutSettings.stackedListHeight`), the divider, then the
/// note in the rest. A `Layout` rather than a frame fed from measured state, so nothing it decides writes back into
/// the layout that measured it.
struct StackedPanesLayout: Layout {
    var listHeight: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // The panes are never measured here. The list holds an AppKit table whose fitting size comes from the Auto
        // Layout engine over its cells, so it changes while the table relays out; measuring it made every constraint
        // change inside the table invalidate this layout, which measured it again, placed it again, and so on until
        // AppKit threw "more Update Constraints passes than there are views in the window" (the folder tree's
        // animated toggle, stacked, at a wide window: VM runs 9 and 10). The width is what is offered, never under
        // the list's floor (the widest pane's); the height is the stored list height plus the note's floor.
        let width = max(NotesLayoutSettings.listMinWidth, proposal.width ?? NotesLayoutSettings.listMinWidth)
        let ideal = NotesLayoutSettings.clampedListHeight(listHeight) + NotesLayoutSettings.stackedDividerHeight
            + NotesLayoutSettings.stackedDetailMinHeight
        let height = max(NotesLayoutSettings.stackedMinHeight, proposal.height ?? ideal)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let list = CGFloat(NotesLayoutSettings.stackedListHeight(stored: listHeight, paneHeight: Double(bounds.height)))
        let divider = CGFloat(NotesLayoutSettings.stackedDividerHeight)
        // Whole points. The folder tree's animated toggle hands this layout fractional widths; the list's AppKit
        // table then fitted its columns to a fractional clip and came out one point too wide, which showed the
        // horizontal scroller, which (the stacked table being short, its rows within a scroller's height of its
        // clip) flipped the vertical one, which changed the clip width back, and so on — AppKit threw after too
        // many constraint passes in one display cycle (W48.notes-stacked-layout, the stacked tours' crash, caught
        // by LayoutLoopProbe in run 15: clip 1219 ↔ 1202, document 1202 ↔ 1203, scroller shown ↔ hidden).
        let width = bounds.width.rounded(.down)
        let x = bounds.minX.rounded(.down), y = bounds.minY.rounded(.down)
        subviews[0].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: list))
        subviews[1].place(at: CGPoint(x: x, y: y + list), proposal: ProposedViewSize(width: width, height: divider))
        subviews[2].place(at: CGPoint(x: x, y: y + list + divider),
                          proposal: ProposedViewSize(width: width,
                                                     height: max(0, (bounds.height - list - divider).rounded(.down))))
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
            } else if nav.showingTrash {
                NotesTrashView(model: model, nav: nav)
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

/// Right pane: a compact header for the currently-selected item, the W3 editor, and the tag bar under it
/// (W40.notes-detail-layout). They follow `nav.detailItemID`, not the selection, so they change in the same pass
/// as the editor's body.
/// The header is the visible "selection → detail" signal (W6-S3). The editor is bound to the selected
/// item's body and autosaves through `NoteStore` (W7-S1a — `NoteEditorPane` + `NoteBodyEditorModel`).
private struct DetailPane: View {
    @ObservedObject var nav: NotesNavigationModel
    @AppStorage(DisplayCalendarSettings.enabledKey) private var calendarsEnabled = false
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
                            .font(.callout).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    Divider()
                    TemplateBodyEditorPane(model: nav.model, templateID: selectedTemplateID)
                }
            } else if nav.showingTrash {
                Text("Select deleted notes and choose Put Back to return them to their folders.")
                    .font(.callout).foregroundStyle(.primary).multilineTextAlignment(.center)
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noteDetail
            }
        }
    }

    /// The header, the editor and the tag bar under it. The fields and locations are in the inspector
    /// (`NoteInspectorPanel`), so the editor takes the whole height between the header and the tags.
    private var noteDetail: some View {
        VStack(spacing: 0) {
            selectedHeader
            Divider()
            NoteEditorPane(nav: nav)
            if let summary = nav.detailSummary {
                Divider()
                // Keyed by the note, so a tag still saving finishes on the note it was typed for.
                NoteTagBar(model: nav.model, item: summary)
                    .id(summary.id)
            }
        }
    }

    @ViewBuilder private var selectedHeader: some View {
        if let item = nav.detailSummary {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: item.kind == .extract ? "quote.opening" : "doc.text")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)   // decorative
                    DetailHeaderTitle(item: item) { [model = nav.model] id, title in
                        await model.renameNote(id, to: title)
                    }
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
                .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // A container, so the title keeps its own identifier (an outer one replaced it).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("an.detail.header")
        } else {
            Text(nav.selection.count > 1 ? "\(nav.selection.count) items selected" : "No note selected")
                .font(.callout)
                .foregroundStyle(.primary)
                .opacity(nav.detailSwitchPending ? 0 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }
}

/// The inspector panel at the window's right (W40.notes-detail-layout): the selected item's fields and locations,
/// `NoteMetadataInspector`, in a scroll view. It reads `nav.detailItemID` as the note pane does, so it follows the
/// selection in the same pass as the editor; with nothing or several items selected it says so, as the header does.
private struct NoteInspectorPanel: View {
    @ObservedObject var nav: NotesNavigationModel
    /// The template the templates manager has selected, whose inspector shows in templates mode.
    let selectedTemplateID: UUID?
    /// With a mouse, macOS shows always-on ("legacy") scroll bars, and the scroll bar sat over the right edge of the
    /// fields, where the Locations rows' remove buttons are: a click there hit the scroll bar (VM run 4).
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    var body: some View {
        VStack(spacing: 0) {
            if nav.paneMode == .notes, let summary = nav.detailSummary {
                // No identifier of its own: as the panel's one child, the scroll area takes the panel's `an.inspector`.
                ScrollView {
                    NoteMetadataInspector(nav: nav, item: summary)
                        .padding(.trailing, scrollerTrailing)
                }
            } else if nav.showingTemplates,
                      let template = nav.model.templates.first(where: { $0.id == selectedTemplateID }) {
                // A template's folders and the fields its notes start with (W40.fix-notes-template-fields).
                ScrollView {
                    TemplateInspector(model: nav.model, template: template)
                        .padding(.trailing, scrollerTrailing)
                }
            } else if nav.paneMode == .notes, nav.selection.isEmpty,
                      let folder = selectedFolder {
                // With no note selected, the folder's template, where a user looks for it (notes-2 row 18).
                ScrollView {
                    FolderTemplateInspector(model: nav.model, folder: folder) { nav.showingTemplates = true }
                        .padding(.trailing, scrollerTrailing)
                }
            } else {
                Text(placeholder)
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .opacity(nav.detailSwitchPending ? 0 : 1)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
        .accessibilityIdentifier("an.inspector")
    }

    private var scrollerTrailing: CGFloat {
        scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    /// The normal folder the sidebar has selected, if any (a smart folder or All Notes has no template).
    private var selectedFolder: NotesFolderNode? {
        guard nav.model.selectedSmartId == nil, let id = nav.model.selectedFolderId else { return nil }
        return nav.model.assignableFolders.first { $0.node.id == id }?.node
    }

    private var placeholder: String {
        if nav.showingTemplates { return nav.model.templates.isEmpty ? "No templates yet" : "No template selected" }
        if nav.paneMode != .notes { return "No details to show" }
        return nav.selection.count > 1 ? "\(nav.selection.count) items selected" : "No note selected"
    }
}

/// The detail header's title. A click starts an edit; Return or a click elsewhere saves, Escape does not
/// (W40.fix-notes-list-rename, notes-1 row 6). It is the list's inline title field, so both behave alike, and an
/// edit saves to the item it began on even if the selection moves meanwhile.
struct DetailHeaderTitle: NSViewRepresentable {
    let item: ItemSummary
    let rename: @MainActor (UUID, String) async -> Bool

    final class Coordinator {
        var latest: DetailHeaderTitle?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NoteTitleTextField {
        let field = NoteTitleTextField(labelWithString: "")
        field.beginsOnClick = true
        field.font = .preferredFont(forTextStyle: .headline)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.toolTip = "Click to rename"
        field.setAccessibilityIdentifier("an.detail.title")
        // A draft is never replaced while it is being edited. If the selection moved meanwhile, the item now
        // shown is applied once it closes; otherwise the typed title stays until the saved one arrives.
        field.onEnd = { [weak field, coordinator = context.coordinator] in
            guard let field, let latest = coordinator.latest else { return }
            Task { @MainActor in
                if !field.isRenaming, field.itemID != latest.item.id { latest.apply(to: field) }
            }
        }
        return field
    }

    func updateNSView(_ field: NoteTitleTextField, context: Context) {
        context.coordinator.latest = self
        if !field.isRenaming { apply(to: field) }
    }

    @MainActor
    fileprivate func apply(to field: NoteTitleTextField) {
        field.noteTitle = item.title
        field.itemID = item.id
        field.stringValue = item.title.isEmpty ? "Untitled" : item.title
        let id = item.id
        let rename = rename
        field.onCommit = { title, completion in
            Task { @MainActor in completion(await rename(id, title)) }
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
