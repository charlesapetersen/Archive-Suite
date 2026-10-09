import SwiftUI
import ArchiveCore
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

    private static let allNotesTag = "\u{0}ALL"
    private static let templatesTag = "\u{0}TEMPLATES"
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
        .onChange(of: nav.showingTemplates) { _, _ in syncSelectionFromModel() }
        // Rename
        .alert("Rename Folder", isPresented: boolBinding($renameID), presenting: renameID) { id in
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await model.renameFolder(id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        // New Folder
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderText)
            Button("Create") {
                let parent = newFolderParentID
                Task {
                    if let id = await model.createFolder(name: newFolderText, under: parent) {
                        model.setFolderScope(id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(newFolderParentID == nil ? "Create a top-level folder." : "Create a subfolder.")
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
        }
    }

    /// The delete button's label — names the note-deletion count when the folder strands sole instances.
    private var deleteConfirmLabel: String {
        guard !deleteStranded.isEmpty else { return "Delete Folder" }
        let n = deleteStranded.count
        return "Delete Folder & \(n) Note\(n == 1 ? "" : "s")"
    }

    /// The delete dialog's message. §5 wording for the batched sole-instance case; the reassuring
    /// non-destructive message otherwise. (Deletion is to the Trash — recoverable — despite "permanently".)
    private var deleteMessage: String {
        guard !deleteStranded.isEmpty else {
            return "The folder is removed; its notes stay in the library (they live in other folders or under All Notes)."
        }
        let titles = model.titles(for: deleteStranded)
        let shown = titles.prefix(8).joined(separator: ", ")
        let list = titles.count > 8 ? "\(shown), …" : shown
        let n = deleteStranded.count
        return "Deleting this folder will permanently delete \(n) note\(n == 1 ? "" : "s") that exist nowhere else: \(list)."
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

    /// Handle a folder drag as a reparent into the target. Item drags remain JSON UUID arrays and keep
    /// their existing move/Option-replicate behavior. `moveFolder` owns cycle refusal and its explanation.
    private func handleDrop(_ payloads: [String], onto folderId: UUID, replicate: Bool, source: UUID?) -> Bool {
        if payloads.count == 1, let draggedFolder = UUID(uuidString: payloads[0]),
           model.organization.folders.contains(where: { $0.id == draggedFolder }) {
            let siblingOrders = model.organization.folders.filter {
                $0.kind == .normal && $0.parentId == folderId
            }.map(\.sortOrder)
            let nextIndex = (siblingOrders.max() ?? -1) + 1
            Task { await model.moveFolder(draggedFolder, newParent: folderId, at: nextIndex) }
            return true
        }
        return handleItemDrop(payloads, onto: folderId, replicate: replicate, source: source)
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
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .help(name)
    }

    private func folderRow(_ node: NotesFolderNode) -> some View {
        row(name: node.name, systemImage: "folder", count: node.itemCount)
            .contentShape(Rectangle())
            .tag(node.id.uuidString)
            .accessibilityIdentifier("an.sidebar.folder")
            .contextMenu { folderMenu(node) }
            .onTapGesture {
                nav.showingTemplates = false
                model.setFolderScope(node.id)
            }
            .onDrag { NotesItemDrag.folderProvider(node.id) }
            .modifier(NotesFolderRowDropTarget(
                sourceFolder: { model.selectedFolderId },
                accept: { payload, replicate, source in
                    _ = handleDrop([payload], onto: node.id, replicate: replicate, source: source)
                },
                reorder: { payload, after in placeFolder(payload, beside: node.id, after: after) }))
    }

    /// A folder dropped on a row's top or bottom edge lands beside that row, in its level (W9.e2-fu1).
    /// Removes the dragged folder from wherever it was and renumbers the target level around it, so the
    /// same gesture reorders siblings and moves a folder in from another level. Returns false for a
    /// payload that is not a folder id (a note drag), which the caller files into the row as before.
    private func placeFolder(_ payload: String, beside targetID: UUID, after: Bool) -> Bool {
        guard let dragged = UUID(uuidString: payload),
              model.organization.folders.contains(where: { $0.id == dragged }) else { return false }
        guard dragged != targetID, let (siblings, parentID) = level(containing: targetID) else { return true }
        // A folder can't sit beside one of its own descendants; `moveFolder` explains the refusal.
        if model.wouldCreateCycle(moving: dragged, to: parentID) {
            Task { await model.moveFolder(dragged, newParent: parentID, at: 0) }
            return true
        }
        var ids = siblings.map(\.id).filter { $0 != dragged }
        guard let targetIndex = ids.firstIndex(of: targetID) else { return true }
        ids.insert(dragged, at: after ? targetIndex + 1 : targetIndex)
        Task {
            for (index, id) in ids.enumerated() {
                await model.moveFolder(id, newParent: parentID, at: index)
            }
        }
        return true
    }

    /// Build each level with its own `ForEach.onMove`, retaining nested disclosure rows while giving reorder
    /// gestures the exact sibling list and parent id they must update.
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
            .onMove { offsets, destination in
                reorderFolders(nodes, parentID: parentID, fromOffsets: offsets, toOffset: destination)
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
                    Text(msg).font(.caption).foregroundStyle(.secondary)
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
        nav.showingTemplates = false   // any folder/smart/All-Notes selection leaves templates mode
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
        let want: String
        if nav.showingTemplates { want = Self.templatesTag }
        else if let s = model.selectedSmartId { want = Self.smartPrefix + s.uuidString }
        else if let f = model.selectedFolderId { want = f.uuidString }
        else { want = Self.allNotesTag }
        if selection != want { selection = want }
    }

    /// A `Bool` presentation binding backed by an optional-id `@State` (true while non-nil; setting
    /// false clears it). Keeps the alert/dialog `isPresented` in sync with the target id.
    private func boolBinding(_ id: Binding<UUID?>) -> Binding<Bool> {
        Binding(get: { id.wrappedValue != nil }, set: { if !$0 { id.wrappedValue = nil } })
    }
}

/// Measures the folder row so its drop delegate can tell an edge drop (reorder) from a middle one
/// (re-parent). A row's own `.onDrop` sees every folder drop over it before the level's `ForEach.onMove`
/// does, so the edge band has to be decided here (W9.e2-fu1).
private struct NotesFolderRowDropTarget: ViewModifier {
    let sourceFolder: @MainActor @Sendable () -> UUID?
    let accept: @MainActor @Sendable (String, Bool, UUID?) -> Void
    let reorder: @MainActor @Sendable (String, Bool) -> Bool
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onDrop(of: NotesFolderDropDelegate.types, delegate: NotesFolderDropDelegate(
                rowHeight: height, sourceFolder: sourceFolder, accept: accept, reorder: reorder))
    }
}

/// The AppKit table writes pasteboard bytes, while SwiftUI folder drags carry NSString. Read both
/// explicitly rather than relying on Transferable String decoding. Capture modifiers and source
/// scope at drop time; asynchronous provider loading cannot change the promised move/copy operation.
private struct NotesFolderDropDelegate: DropDelegate {
    static let types = [NotesItemDrag.folderTypeIdentifier, NotesItemDrag.pasteboardType.rawValue,
                        UTType.utf8PlainText.identifier, UTType.plainText.identifier]
    let rowHeight: CGFloat
    // SwiftUI may retain the delegate across selection updates. Resolve the current scope at the
    // drop boundary, then capture the value before any provider callback can run.
    let sourceFolder: @MainActor @Sendable () -> UUID?
    let accept: @MainActor @Sendable (String, Bool, UUID?) -> Void
    /// A payload dropped in the top (`false`) or bottom (`true`) quarter of the row; true if it was a
    /// folder and has been placed beside the row.
    let reorder: @MainActor @Sendable (String, Bool) -> Bool

    /// Which edge band a folder drop at `y` falls in: nil for the middle, or before the row is measured.
    static func edge(y: CGFloat, rowHeight: CGFloat) -> Bool? {
        guard rowHeight > 0 else { return nil }
        let band = rowHeight / 4
        if y <= band { return false }
        if y >= rowHeight - band { return true }
        return nil
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let isFolder = info.hasItemsConforming(to: [NotesItemDrag.folderTypeIdentifier])
        let operation = NotesItemDrag.operation(isFolder: isFolder, optionHeld: NSEvent.modifierFlags.contains(.option))
        return DropProposal(operation: operation == .copy ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: Self.types)
        guard !providers.isEmpty else { return false }
        // The folder type is registered `.ownProcess` and does not survive to the drop side, so an edge
        // drop is told apart by its payload: `reorder` takes a folder id and declines anything else.
        let edge = Self.edge(y: info.location.y, rowHeight: rowHeight)
        let reorder = reorder
        let replicate = NSEvent.modifierFlags.contains(.option)
        let source = MainActor.assumeIsolated { sourceFolder() }
        let accept = accept
        for provider in providers {
            guard let type = Self.types.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else { continue }
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                guard error == nil else { return }
                let payload: String?
                if let data = item as? Data { payload = String(data: data, encoding: .utf8) }
                else { payload = item as? String }
                guard let payload else { return }
                Task { @MainActor in
                    if let after = edge, reorder(payload, after) { return }
                    accept(payload, replicate, source)
                }
            }
        }
        return true
    }
}
