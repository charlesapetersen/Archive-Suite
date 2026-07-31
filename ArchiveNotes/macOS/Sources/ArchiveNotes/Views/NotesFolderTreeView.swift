import SwiftUI
import ArchiveCore

/// The Notes browser's left pane — the **mutable, id-keyed virtual folder tree** (06-viewers §2,
/// W6-S2). Adapts Reader's `SidebarView` (`ArchiveReader/.../Views/SidebarView.swift`): a
/// `List(selection:)` with an `OutlineGroup`, a two-way `@State` selection sync, a "Smart Folders"
/// section above a "Folders" section, and an "All Notes" pseudo-row that clears the scope. The key
/// differences from Reader are that rows are keyed by **UUID** (not path) and folders are
/// **user-authored + mutable** (create / rename / move / delete), routed through `NotesModel` →
/// `OrganizationStore`'s atomic writes.
///
/// Drag-to-reparent and the batched sole-instance delete confirmation are W6-S5 (replication + delete
/// path, Tier-2); a "Templates" anchor row is W6-S6. This pane ships create / rename / delete +
/// selection now.
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

    private static let allNotesTag = "\u{0}ALL"
    private static let templatesTag = "\u{0}TEMPLATES"
    private static let smartPrefix = "SS:"

    var body: some View {
        List(selection: $selection) {
            if !model.smartFolders.isEmpty {
                Section("Smart Folders") {
                    ForEach(model.smartFolders) { node in
                        row(name: node.name, systemImage: "line.3.horizontal.decrease.circle", count: nil)
                            .tag(Self.smartPrefix + node.id.uuidString)
                            .accessibilityIdentifier("an.sidebar.smart")
                    }
                }
            }
            Section("Folders") {
                row(name: "All Notes", systemImage: "tray.full", count: model.allNotesCount)
                    .tag(Self.allNotesTag)
                    .accessibilityIdentifier("an.sidebar.allNotes")
                OutlineGroup(model.normalTree, children: \.childrenOrNil) { node in
                    row(name: node.name, systemImage: "folder", count: node.itemCount)
                        .tag(node.id.uuidString)
                        .accessibilityIdentifier("an.sidebar.folder")
                        .contextMenu { folderMenu(node) }
                        .dropDestination(for: String.self) { items, _ in
                            handleItemDrop(items, onto: node.id)
                        }
                }
            }
            Section {
                row(name: "Templates", systemImage: "square.on.square", count: model.templates.count)
                    .tag(Self.templatesTag)
                    .accessibilityIdentifier("an.sidebar.templates")
            }
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
    private func handleItemDrop(_ payloads: [String], onto folderId: UUID) -> Bool {
        let ids = payloads.flatMap { NotesItemDrag.decode(string: $0) }
        guard !ids.isEmpty else { return false }
        let replicate = NSEvent.modifierFlags.contains(.option)
        Task {
            if replicate { await nav.replicate(ids, to: folderId) }
            else { await nav.move(ids, to: folderId, from: model.selectedFolderId) }
        }
        return true
    }

    // MARK: Rows & chrome

    private func row(name: String, systemImage: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Label(name, systemImage: systemImage).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let count, count > 0 {
                Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .help(name)
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
