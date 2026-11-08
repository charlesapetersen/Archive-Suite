import SwiftUI
import UniformTypeIdentifiers

/// The Notes browser's left pane — the **mutable, id-keyed virtual folder tree** (06-viewers §2,
/// W6-S2). Adapts Reader's `SidebarView` (`ArchiveReader/.../Views/SidebarView.swift`): a
/// `List(selection:)` with an `OutlineGroup`, a two-way `@State` selection sync, a "Smart Folders"
/// section above a "Folders" section, and an "All Notes" pseudo-row that clears the scope. The key
/// differences from Reader are that rows are keyed by **UUID** (not path) and folders are
/// **user-authored + mutable** (create / rename / move / delete), routed through `NotesModel` →
/// `OrganizationStore`'s atomic writes.
///
/// Item drops and the batched sole-instance delete confirmation are W6-S5 (replication + delete path,
/// Tier-2); folder reorder / reparent is W9.d1. A "Templates" anchor row is W6-S6.
struct NotesFolderTreeView: View {
    @ObservedObject var model: NotesModel
    /// This window's item-list model — drops route through its `move`/`replicate` so the acting window
    /// refreshes; the delete guard's per-window modal state also lives there (W6-S5).
    @ObservedObject var nav: NotesNavigationModel

    // Real @State, not a computed Binding: OutlineGroup rows don't fire a computed Binding's setter
    // (Reader SidebarView.swift:8-13). Tags: allNotesTag · smartPrefix+uuid · uuid.
    @State private var selection: String?

    // Mutation sheets/dialogs.
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var newFolderParentID: UUID?
    @State private var newFolderText = ""
    @State private var deleteID: UUID?
    @State private var deleteName = ""
    // Sole-instance items (fresh read at delete-tap time) that deleting the folder would delete (§5).
    @State private var deleteStranded: [UUID] = []
    @State private var expandedFolders: Set<UUID> = []
    /// The row a drag is over and where on it the drop would land; the only drop highlight drawn.
    @State private var dropTarget: NotesFolderDropTarget?
    /// The drag pasteboard's change count when the last drop was performed. SwiftUI can still send that
    /// drag's row an update after the drop, which re-lit the highlight and left it on (seen in the VM's
    /// video); a new drag changes the count.
    @State private var finishedDrag: Int?

    private static let allNotesTag = "\u{0}ALL"
    private static let templatesTag = "\u{0}TEMPLATES"
    private static let trashTag = "\u{0}TRASH"
    private static let smartPrefix = "SS:"

    var body: some View {
        List(selection: $selection) {
            smartFolderSection
            normalFolderSection
            templatesSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear { syncSelectionFromModel() }
        .onChange(of: selection) { _, new in applySelection(new) }
        .onChange(of: model.selectedFolderId) { _, _ in syncSelectionFromModel() }
        .onChange(of: model.selectedSmartId) { _, _ in syncSelectionFromModel() }
        .onChange(of: nav.paneMode) { _, _ in syncSelectionFromModel() }
        .onChange(of: model.scopeIsUnsavedSearch) { _, _ in syncSelectionFromModel() }
        // Rename
        .sheet(isPresented: boolBinding($renameID)) {
            let id = renameID
            NameEntrySheet(title: "Rename Folder", confirmLabel: "Rename", name: $renameText) { name in
                guard let id else { return }
                Task { await model.renameFolder(id, to: name) }
            }
        }
        // New Folder
        .sheet(isPresented: $showNewFolder) {
            let parent = newFolderParentID
            NameEntrySheet(title: "New Folder",
                           message: parent == nil ? "Create a top-level folder." : "Create a subfolder.",
                           confirmLabel: "Create", name: $newFolderText) { name in
                Task {
                    if let id = await model.createFolder(name: name, under: parent) {
                        model.setFolderScope(id)
                    }
                }
            }
        }
        // Delete — batched delete-last-instance guard (§3.6, §5). If deleting the folder would strand
        // sole-instance notes, the button + message name the permanent deletion; otherwise it's a plain
        // (non-destructive) folder delete.
        .confirmationDialog("Delete “\(deleteName)”?", isPresented: boolBinding($deleteID),
                            presenting: deleteID) { id in
            Button(deleteConfirmLabel, role: .destructive) {
                let stranded = deleteStranded
                Task {
                    if stranded.isEmpty { _ = await model.deleteFolder(id) }
                    else { await model.deleteFolderDeletingStranded(id, stranded: stranded) }
                    nav.recompute()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text(deleteMessage) }
    }

    @ViewBuilder
    private var smartFolderSection: some View {
        if !model.smartFolders.isEmpty {
            Section("Smart Folders") {
                ForEach(model.smartFolders) { node in
                    row(name: node.name, systemImage: "line.3.horizontal.decrease.circle",
                        count: model.smartFolderCounts[node.id], showZero: true)
                        .tag(Self.smartPrefix + node.id.uuidString)
                        .accessibilityIdentifier("an.sidebar.smart")
                        .contextMenu {
                            Button("Edit Smart Folder\u{2026}") { nav.editSmartFolder(node.id) }
                            Button("Rename\u{2026}") { renameText = node.name; renameID = node.id }
                        }
                }
            }
        }
    }

    private var normalFolderSection: some View {
        Section("Folders") {
            row(name: "All Notes", systemImage: "tray.full", count: model.allNotesCount)
                .tag(Self.allNotesTag)
                .accessibilityIdentifier("an.sidebar.allNotes")
            folderTreeLevel(model.normalTree, parentID: nil)
        }
    }

    private var templatesSection: some View {
        Section {
            row(name: "Templates", systemImage: "square.on.square", count: model.templates.count)
                .tag(Self.templatesTag)
                .accessibilityIdentifier("an.sidebar.templates")
            row(name: "Trash", systemImage: "trash", count: model.trashedNotes.count)
                .tag(Self.trashTag)
                .accessibilityIdentifier("an.sidebar.trash")
        }
    }

    /// The delete button's label — names the note-deletion count when the folder strands sole instances.
    private var deleteConfirmLabel: String {
        guard !deleteStranded.isEmpty else { return "Delete Folder" }
        let n = deleteStranded.count
        return "Delete Folder & \(n) Note\(n == 1 ? "" : "s")"
    }

    /// The delete dialog's message. §5 wording for the batched sole-instance case; the reassuring
    /// non-destructive message otherwise. The notes go to the sidebar's Trash, where Put Back finds them.
    private var deleteMessage: String {
        guard !deleteStranded.isEmpty else {
            return "The folder is removed; its notes stay in the library (they live in other folders or under All Notes)."
        }
        let titles = model.titles(for: deleteStranded)
        let shown = titles.prefix(8).joined(separator: ", ")
        let list = titles.count > 8 ? "\(shown), …" : shown
        let n = deleteStranded.count
        let noun = n == 1 ? "1 note that exists" : "\(n) notes that exist"
        return "Deleting this folder will move to the Trash \(noun) nowhere else: \(list). "
            + "Put Back in the Trash returns them under All Notes."
    }

    /// Handle a table→folder drop: plain = MOVE (from the current scope), ⌥ = REPLICATE. Reads the
    /// modifier at drop time (`NSEvent.modifierFlags`); the ids-only payload decodes to `[]` for a
    /// foreign/stray drop (an inert no-op). `move`/`replicate` refuse a non-normal target (§5).
    private func handleItemDrop(_ payloads: [String], onto folderId: UUID, replicate: Bool, source: UUID?) -> Bool {
        let ids = payloads.flatMap { NotesItemDrag.decode(string: $0) }
        guard !ids.isEmpty else { return false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ANUITestStorePath") {
            model.statusMessage = "Drop \(replicate ? "copy" : "move") from \(source?.uuidString ?? "all") to \(folderId.uuidString)"
        }
        #endif
        Task {
            if replicate { await nav.replicate(ids, to: folderId) }
            else { await nav.move(ids, to: folderId, from: source) }
        }
        return true
    }

    /// The displayed sibling level that holds `id`, with that level's parent id (nil = top level).
    private func level(containing id: UUID) -> (siblings: [NotesFolderNode], parentID: UUID?)? {
        func search(_ nodes: [NotesFolderNode], parent: UUID?) -> (siblings: [NotesFolderNode], parentID: UUID?)? {
            if nodes.contains(where: { $0.id == id }) { return (nodes, parent) }
            for node in nodes { if let hit = search(node.children, parent: node.id) { return hit } }
            return nil
        }
        return search(model.normalTree, parent: nil)
    }

    /// Swap a folder with its neighbour one place up (`-1`) or down (`+1`) within its own level.
    private func shiftFolder(_ id: UUID, by delta: Int) {
        guard let (siblings, parentID) = level(containing: id),
              let from = siblings.firstIndex(where: { $0.id == id }),
              siblings.indices.contains(from + delta) else { return }
        reorderFolders(siblings, parentID: parentID, fromOffsets: IndexSet(integer: from),
                       toOffset: delta > 0 ? from + delta + 1 : from + delta)
    }

    /// Re-parent a nested folder to the root, after the existing top-level folders.
    private func moveToTopLevel(_ id: UUID) {
        let topOrders = model.organization.folders.filter { $0.kind == .normal && $0.parentId == nil }
            .map(\.sortOrder)
        let nextIndex = (topOrders.max() ?? -1) + 1
        Task { await model.moveFolder(id, newParent: nil, at: nextIndex) }
    }

    /// Renumber the moved sibling level in its existing parent; descendant membership and parent links stay put.
    private func reorderFolders(_ siblings: [NotesFolderNode], parentID: UUID?,
                                fromOffsets: IndexSet, toOffset: Int) {
        var reordered = siblings
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        Task {
            for (index, folder) in reordered.enumerated() {
                await model.moveFolder(folder.id, newParent: parentID, at: index)
            }
        }
    }

    // MARK: Rows & chrome

    private func row(name: String, systemImage: String, count: Int?, showZero: Bool = false) -> some View {
        HStack(spacing: 6) {
            Label(name, systemImage: systemImage).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let count, count > 0 || showZero {
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.primary)
            }
        }
        .help(name)
    }

    private func folderRow(_ node: NotesFolderNode) -> some View {
        row(name: node.name, systemImage: "folder", count: node.itemCount)
            .contentShape(Rectangle())
            .accessibilityIdentifier("an.sidebar.folder")
            .contextMenu { folderMenu(node) }
            .modifier(NotesFolderRowDropTarget(
                folderID: node.id,
                target: $dropTarget,
                resolve: { y, height in dropTarget(onto: node.id, y: y, rowHeight: height) },
                finish: { finishedDrag = NSPasteboard(name: .drag).changeCount },
                sourceFolder: { model.selectedFolderId },
                dropFolder: { dragged, target in dropFolder(dragged, on: target) },
                acceptItems: { payload, replicate, source in
                    _ = handleItemDrop([payload], onto: node.id, replicate: replicate, source: source)
                }))
            .background { dropHighlight(for: node.id) }
            // Register the payload on the native List row, including its blank area and nested rows.
            // An inner onDrag + tap handler competed with the outline's mouse-down selection (W40).
            // Click selection goes through List's binding and applySelection, just like the other rows.
            .itemProvider { NotesItemDrag.folderProvider(node.id) }
            // Outermost, so the List matches the selection to this row through the drag/drop wrappers.
            .tag(node.id.uuidString)
    }

    /// Where a drag over `folderID`'s row at `y` would land, or nil when the drop would do nothing or be
    /// refused: a folder onto itself, into one of its own descendants, or beside a row inside itself; or
    /// a drag from outside the app. The row draws exactly this and the drop performs exactly this, so
    /// the highlighted row is always the one the drop lands in (W40.fix-notes-folder-drag).
    private func dropTarget(onto folderID: UUID, y: CGFloat, rowHeight: CGFloat) -> NotesFolderDropTarget? {
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != finishedDrag else { return nil }
        switch NotesItemDrag.dragKind(on: pasteboard) {
        case .other:
            return nil
        case .items:
            return NotesFolderDropTarget(row: folderID, folder: folderID, zone: .into, dragged: nil)
        case .folder(let dragged):
            guard model.organization.folders.contains(where: { $0.id == dragged }),
                  dragged != folderID else { return nil }
            let zone = NotesItemDrag.dropZone(y: y, rowHeight: rowHeight, isFolder: true)
            // Below an open folder the next row is its first child, so the line there means "first
            // child", whichever of the two rows the pointer is on.
            if zone == .after, expandedFolders.contains(folderID),
               let first = level(containing: folderID)?.siblings.first(where: { $0.id == folderID })?.children.first {
                guard first.id != dragged, !model.wouldCreateCycle(moving: dragged, to: folderID) else { return nil }
                return NotesFolderDropTarget(row: folderID, folder: first.id, zone: .before, dragged: dragged)
            }
            let newParent = zone == .into ? folderID : level(containing: folderID)?.parentID
            if model.wouldCreateCycle(moving: dragged, to: newParent) { return nil }
            return NotesFolderDropTarget(row: folderID, folder: folderID, zone: zone, dragged: dragged)
        }
    }

    /// Perform a folder drop that `dropTarget` resolved: nest it, or place it beside the row.
    private func dropFolder(_ dragged: UUID, on target: NotesFolderDropTarget) {
        switch target.zone {
        case .into:
            let siblingOrders = model.organization.folders.filter {
                $0.kind == .normal && $0.parentId == target.folder
            }.map(\.sortOrder)
            let nextIndex = (siblingOrders.max() ?? -1) + 1
            expandedFolders.insert(target.folder)   // show where it went
            Task { await model.moveFolder(dragged, newParent: target.folder, at: nextIndex) }
        case .before, .after:
            placeFolder(dragged, beside: target.folder, after: target.zone == .after)
        }
    }

    /// A folder dropped on a row's top or bottom edge lands beside that row, in its level (W9.e2-fu1).
    /// Removes the dragged folder from wherever it was and renumbers the target level around it, so the
    /// same gesture reorders siblings and moves a folder in from another level.
    private func placeFolder(_ dragged: UUID, beside targetID: UUID, after: Bool) {
        guard dragged != targetID, let (siblings, parentID) = level(containing: targetID) else { return }
        // A folder can't sit beside one of its own descendants; `moveFolder` explains the refusal.
        if model.wouldCreateCycle(moving: dragged, to: parentID) {
            Task { await model.moveFolder(dragged, newParent: parentID, at: 0) }
            return
        }
        var ids = siblings.map(\.id).filter { $0 != dragged }
        guard let targetIndex = ids.firstIndex(of: targetID) else { return }
        ids.insert(dragged, at: after ? targetIndex + 1 : targetIndex)
        Task {
            for (index, id) in ids.enumerated() {
                await model.moveFolder(id, newParent: parentID, at: index)
            }
        }
    }

    /// The drop highlight, drawn by the app rather than the List: a filled outline when the drop goes into
    /// this folder, a line along the top or bottom edge when it goes beside it.
    @ViewBuilder private func dropHighlight(for folderID: UUID) -> some View {
        if let target = dropTarget, target.folder == folderID {
            switch target.zone {
            case .into:
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2))
                    .padding(.horizontal, -4).padding(.vertical, -2)
                    .accessibilityHidden(true)
            case .before, .after:
                VStack(spacing: 0) {
                    if target.zone == .after { Spacer(minLength: 0) }
                    Capsule().fill(Color.accentColor).frame(height: 2)
                    if target.zone == .before { Spacer(minLength: 0) }
                }
                .padding(.vertical, -6)   // in the gap between the rows
                .accessibilityHidden(true)
            }
        }
    }

    /// Build each level, retaining nested disclosure rows. Deliberately no `ForEach.onMove`: it made the gaps
    /// between rows the List's own reorder targets, drawn by the List, so most of a row's height reordered and
    /// only a band in its middle nested (W40.fix-notes-folder-drag). The row's own drop area now covers the
    /// row, reordering on its edges and nesting in its middle, and the app draws the only highlight.
    private func folderTreeLevel(_ nodes: [NotesFolderNode], parentID: UUID?) -> AnyView {
        AnyView(
            ForEach(nodes) { node in
                if node.children.isEmpty {
                    folderRow(node)
                } else {
                    DisclosureGroup(isExpanded: expandedBinding(for: node.id)) {
                        folderTreeLevel(node.children, parentID: node.id)
                    } label: {
                        folderRow(node)
                    }
                    .tag(node.id.uuidString)
                }
            }
        )
    }

    private func expandedBinding(for folderID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedFolders.contains(folderID) },
            set: { isExpanded in
                if isExpanded { expandedFolders.insert(folderID) }
                else { expandedFolders.remove(folderID) }
            })
    }

    /// The per-folder context menu. Rename and Delete are **disabled** on the fixed-ID system folders
    /// (Inbox / Extracts, §16.6) rather than hidden — greyed-out says "not allowed here", a missing
    /// item reads as a broken menu (W23.m15). Deleting one used to be permanent: nothing recreated it
    /// while the app kept filing new notes and extracts under its id. Subfolders and templates stay
    /// available; neither destroys the folder.
    @ViewBuilder private func folderMenu(_ node: NotesFolderNode) -> some View {
        let isSystem = OrganizationStore.isSystemFolder(node.id)
        Button("New Subfolder…") { beginNewFolder(parent: node.id) }
        Button("Rename…") { renameText = node.name; renameID = node.id }
            .disabled(isSystem)
        Divider()
        // Menu twins of the drag gestures (W9.e2-folders, D1): a drop on a row's edge reorders, and on a
        // top-level row's edge un-nests (W9.e2-fu1), but the menu needs no aim at a few-point band.
        let place = level(containing: node.id)
        let index = place?.siblings.firstIndex { $0.id == node.id }
        Button("Move Up") { shiftFolder(node.id, by: -1) }
            .disabled(index == nil || index == 0)
        Button("Move Down") { shiftFolder(node.id, by: 1) }
            .disabled(index == nil || index == (place?.siblings.count ?? 0) - 1)
        Button("Move to Top Level") { moveToTopLevel(node.id) }
            .disabled(place == nil || place?.parentID == nil)
        Divider()
        templateAssignmentMenu(node)
        Divider()
        Button("Delete", role: .destructive) {
            deleteName = node.name
            deleteStranded = model.strandedByDeletingFolder(node.id)   // fresh read at click time (§5)
            deleteID = node.id
        }
        .disabled(isSystem)
    }

    /// "Template ▸ (None / …each template… / Manage…)" — sets THIS folder's direct assignment (§16.4:
    /// template↔folder lives only in `template_assignments`). A ✓ marks the folder's own assignment;
    /// child folders inherit via the nearest-ancestor resolver, not shown here.
    @ViewBuilder private func templateAssignmentMenu(_ node: NotesFolderNode) -> some View {
        let assigned = assignedTemplateId(node.id)
        Menu("Template") {
            Button { Task { await model.assignTemplate(nil, to: node.id) } } label: {
                checkableLabel("None", checked: assigned == nil)
            }
            if !model.templates.isEmpty {
                Divider()
                ForEach(model.templates) { t in
                    Button { Task { await model.assignTemplate(t.id, to: node.id) } } label: {
                        checkableLabel(t.name, checked: assigned == t.id)
                    }
                }
            }
            Divider()
            Button("Manage…") { showTemplates() }
        }
    }

    /// A menu label that shows a ✓ only when `checked` (no empty SF Symbol when unchecked).
    @ViewBuilder private func checkableLabel(_ title: String, checked: Bool) -> some View {
        Label { Text(title) } icon: { if checked { Image(systemName: "checkmark") } }
    }

    /// The template assigned directly to `folderId` (not inherited); nil if none.
    private func assignedTemplateId(_ folderId: UUID) -> UUID? {
        model.organization.assignments.first { $0.folderId == folderId }?.templateId
    }

    /// Enter the per-window templates-manager mode and reflect it in the sidebar selection.
    private func showTemplates() {
        nav.showingTemplates = true
        selection = Self.templatesTag
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let msg = model.statusMessage {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(msg).font(.caption).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture { model.statusMessage = nil }
                .accessibilityIdentifier("an.sidebar.status")
            }
            Divider()
            HStack {
                Button { beginNewFolder(parent: nil) } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless).help("New Folder")
                .accessibilityIdentifier("an.sidebar.newFolder")
                Spacer()
                #if DEBUG
                // UI-test seam: the drop highlight's state, so a test can see none is left after a drop.
                if ProcessInfo.processInfo.arguments.contains("-ANUITestStorePath") {
                    Text(dropTarget.map { "\($0.zone) \($0.folder.uuidString)" } ?? "none")
                        .font(.system(size: 2)).opacity(0.05)
                        .accessibilityIdentifier("an.sidebar.test.dropTarget")
                }
                #endif
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .background(.bar)
    }

    private func beginNewFolder(parent: UUID?) {
        newFolderParentID = parent
        newFolderText = "New Folder"
        showNewFolder = true
    }

    // MARK: Selection sync (mirrors SidebarView.applySelection / syncSelectionFromModel)

    private func applySelection(_ new: String?) {
        if new == Self.templatesTag { nav.showingTemplates = true; return }
        if new == Self.trashTag { nav.showingTrash = true; return }
        // An unsaved Advanced Search selects no row; the sync to nil must not undo it (W40.notes-advanced-search).
        if new == nil, model.scopeIsUnsavedSearch { return }
        nav.showingTemplates = false   // any folder/smart/All-Notes selection leaves templates or Trash mode
        guard let new, new != Self.allNotesTag else { model.setAllNotesScope(); return }
        if new.hasPrefix(Self.smartPrefix) {
            if let id = UUID(uuidString: String(new.dropFirst(Self.smartPrefix.count))) {
                model.applySmartScope(id)
            }
        } else if let id = UUID(uuidString: new) {
            model.setFolderScope(id)
        }
    }

    private func syncSelectionFromModel() {
        let want: String?
        if nav.showingTemplates { want = Self.templatesTag }
        else if nav.showingTrash { want = Self.trashTag }
        else if let s = model.selectedSmartId { want = Self.smartPrefix + s.uuidString }
        else if let f = model.selectedFolderId { want = f.uuidString }
        else if model.scopeIsUnsavedSearch { want = nil }
        else { want = Self.allNotesTag }
        if selection != want { selection = want }
    }

    /// A `Bool` presentation binding backed by an optional-id `@State` (true while non-nil; setting
    /// false clears it). Keeps the alert/dialog `isPresented` in sync with the target id.
    private func boolBinding(_ id: Binding<UUID?>) -> Binding<Bool> {
        Binding(get: { id.wrappedValue != nil }, set: { if !$0 { id.wrappedValue = nil } })
    }
}

/// A drop resolved over a folder row: the row under the pointer, the folder the drop lands on or beside
/// (usually the same row), where, and the folder being dragged (nil for notes).
struct NotesFolderDropTarget: Equatable {
    let row: UUID
    let folder: UUID
    let zone: NotesItemDrag.DropZone
    let dragged: UUID?
}

/// Measures the folder row so its drop delegate can tell an edge drop (reorder) from a middle one
/// (re-parent), and keeps the tree's one drop highlight on the row the drop would land in.
private struct NotesFolderRowDropTarget: ViewModifier {
    let folderID: UUID
    @Binding var target: NotesFolderDropTarget?
    let resolve: @MainActor (CGFloat, CGFloat) -> NotesFolderDropTarget?
    let finish: @MainActor () -> Void
    let sourceFolder: @MainActor @Sendable () -> UUID?
    let dropFolder: @MainActor (UUID, NotesFolderDropTarget) -> Void
    let acceptItems: @MainActor @Sendable (String, Bool, UUID?) -> Void
    @State private var height: CGFloat = 0
    /// How far the drop area reaches past the label, above and below. A sidebar row's label is about half
    /// the row's height (16 of 32 pt in the VM), so without this, half of every row took no drop and the
    /// highlight went out between rows (W40.fix-notes-folder-drag). 8 pt meets the next row's area at the
    /// default row size; at a smaller one the areas overlap, and the row holding the drag decides. It does
    /// not change the layout.
    static let reach: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Self.reach)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onDrop(of: NotesFolderDropDelegate.types, delegate: NotesFolderDropDelegate(
                folderID: folderID, rowHeight: height, target: $target, resolve: resolve, finish: finish,
                sourceFolder: sourceFolder, dropFolder: dropFolder, acceptItems: acceptItems))
            .padding(.vertical, -Self.reach)
    }
}

/// The AppKit table writes pasteboard bytes, while SwiftUI folder drags carry NSString. Every pointer
/// move re-resolves the target from the drag pasteboard (`NotesItemDrag.dragKind`) and the pointer's
/// band of the row, and the drop performs the same resolution, so what is highlighted is what happens.
/// Item drops still read their ids from the providers; modifiers and source scope are captured at drop
/// time, since asynchronous provider loading cannot change the promised move/copy operation.
private struct NotesFolderDropDelegate: DropDelegate {
    static let types = [NotesItemDrag.folderTypeIdentifier, NotesItemDrag.pasteboardType.rawValue,
                        UTType.utf8PlainText.identifier, UTType.plainText.identifier]
    let folderID: UUID
    let rowHeight: CGFloat
    @Binding var target: NotesFolderDropTarget?
    let resolve: @MainActor (CGFloat, CGFloat) -> NotesFolderDropTarget?
    /// Marks the drag as dropped, so no late update for it lights a row again.
    let finish: @MainActor () -> Void
    // SwiftUI may retain the delegate across selection updates. Resolve the current scope at the
    // drop boundary, then capture the value before any provider callback can run.
    let sourceFolder: @MainActor @Sendable () -> UUID?
    let dropFolder: @MainActor (UUID, NotesFolderDropTarget) -> Void
    let acceptItems: @MainActor @Sendable (String, Bool, UUID?) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }

    func dropEntered(info: DropInfo) { track(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let resolved = track(info) else { return DropProposal(operation: .forbidden) }
        let operation = NotesItemDrag.operation(isFolder: resolved.dragged != nil,
                                                optionHeld: NSEvent.modifierFlags.contains(.option))
        return DropProposal(operation: operation == .copy ? .copy : .move)
    }

    /// Leaving this row clears the highlight only if it is still this row's; the next row may already
    /// have taken it.
    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { if target?.row == folderID { target = nil } }
    }

    @discardableResult
    private func track(_ info: DropInfo) -> NotesFolderDropTarget? {
        MainActor.assumeIsolated {
            let resolved = resolve(info.location.y, rowHeight)
            if resolved != nil || target?.row == folderID, target != resolved { target = resolved }
            return resolved
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let resolved = MainActor.assumeIsolated { () -> NotesFolderDropTarget? in
            let resolved = resolve(info.location.y, rowHeight)
            finish()
            target = nil
            return resolved
        }
        guard let resolved else { return false }
        if let dragged = resolved.dragged {
            MainActor.assumeIsolated { dropFolder(dragged, resolved) }
            return true
        }
        let providers = info.itemProviders(for: [NotesItemDrag.pasteboardType.rawValue,
                                                 UTType.utf8PlainText.identifier, UTType.plainText.identifier])
        guard !providers.isEmpty else { return false }
        let replicate = NSEvent.modifierFlags.contains(.option)
        let source = MainActor.assumeIsolated { sourceFolder() }
        let acceptItems = acceptItems
        for provider in providers {
            guard let type = Self.types.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { continue }
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                guard error == nil else { return }
                let payload: String?
                if let data = item as? Data { payload = String(data: data, encoding: .utf8) }
                else { payload = item as? String }
                guard let payload else { return }
                Task { @MainActor in acceptItems(payload, replicate, source) }
            }
        }
        return true
    }
}
