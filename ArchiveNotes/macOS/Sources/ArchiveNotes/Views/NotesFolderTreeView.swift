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

    private static let allNotesTag = "\u{0}ALL"
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
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear { syncSelectionFromModel() }
        .onChange(of: selection) { _, new in applySelection(new) }
        .onChange(of: model.selectedFolderId) { _, _ in syncSelectionFromModel() }
        .onChange(of: model.selectedSmartId) { _, _ in syncSelectionFromModel() }
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
        // Delete
        .confirmationDialog("Delete “\(deleteName)”?", isPresented: boolBinding($deleteID),
                            presenting: deleteID) { id in
            Button("Delete Folder", role: .destructive) { Task { _ = await model.deleteFolder(id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The folder is removed; its notes stay in the library. Any note that was only in this folder moves to All Notes.")
        }
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

    @ViewBuilder private func folderMenu(_ node: NotesFolderNode) -> some View {
        Button("New Subfolder…") { beginNewFolder(parent: node.id) }
        Button("Rename…") { renameText = node.name; renameID = node.id }
        Divider()
        Button("Delete", role: .destructive) { deleteName = node.name; deleteID = node.id }
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
        if let s = model.selectedSmartId { want = Self.smartPrefix + s.uuidString }
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
