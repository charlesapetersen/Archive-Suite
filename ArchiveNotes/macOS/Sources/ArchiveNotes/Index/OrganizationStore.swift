import Foundation

// MARK: - Value types (Sendable, Codable — cross-actor payloads per §16.9)

/// A virtual folder in the organizational graph (§3, §4).
struct VFolder: Sendable, Equatable, Identifiable, Codable {
    var id: UUID
    var name: String
    var parentId: UUID?
    var sortOrder: Int
    enum Kind: String, Sendable, Codable { case normal, smart }
    var kind: Kind
    /// Encoded `NotesFilter` for smart folders (§16.3); nil for normal folders.
    var queryJSON: String?
}

/// A membership binding an item to a folder (many-to-many replication).
struct Membership: Sendable, Equatable, Codable {
    var itemId: UUID
    var folderId: UUID
    var addedAt: Date
}

/// A template assigned to a folder; W6 resolves via ancestor walk (§16.4).
struct TemplateAssignment: Sendable, Equatable, Codable {
    var folderId: UUID
    var templateId: UUID
}

/// Result of `removeMembership`: `.removed` if the membership was deleted,
/// `.wasLastInstance` if removing would leave the item with zero memberships
/// (caller must show the §3.6 delete-last-instance confirmation).
enum RemoveResult: Sendable { case removed; case wasLastInstance }

// MARK: - OrganizationStore

/// Owns the folder tree, memberships, and template assignments (§16.1).
/// Persists to the index DB **and** `organization.json` (atomic) on every mutation.
/// The DB is a disposable cache; `organization.json` is the durable mirror (§11).
@MainActor final class OrganizationStore: ObservableObject {
    /// Stable system folder IDs (§16.6) — deterministic across launches.
    static let allNotesFolderId  = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let inboxFolderId     = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let extractsFolderId  = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    @Published private(set) var folders: [VFolder] = []
    @Published private(set) var memberships: [Membership] = []
    @Published private(set) var assignments: [TemplateAssignment] = []

    private let index: NotesIndex
    private var storeRoot: URL?

    /// The Extracts system folder ID (§16.1 / §16.6).
    var extractsHomeFolderId: UUID { Self.extractsFolderId }

    init(index: NotesIndex) {
        self.index = index
    }

    /// Load the organizational graph from the DB; if the DB has no folders
    /// but `organization.json` exists, rebuild the DB from the JSON (§4).
    /// Seeds system folders if neither source has data.
    func load(storeRoot: URL) async throws {
        self.storeRoot = storeRoot

        let dbFolders = await index.allFolders()
        if dbFolders.isEmpty {
            if let file = OrganizationFile.load(from: storeRoot) {
                folders = file.folders
                memberships = file.memberships
                assignments = file.assignments
                try await index.replaceOrganization(
                    folders: folders, memberships: memberships, assignments: assignments)
            } else {
                seedSystemFolders()
                for f in folders { try await index.insertFolder(f) }
            }
        } else {
            folders = dbFolders
            memberships = await index.allMemberships()
            assignments = await index.allTemplateAssignments()
        }
    }

    // MARK: - Folder operations

    @discardableResult
    func createFolder(name: String, parent: UUID? = nil, kind: VFolder.Kind = .normal,
                      queryJSON: String? = nil) async throws -> VFolder {
        let folder = VFolder(
            id: UUID(), name: name, parentId: parent,
            sortOrder: nextSortOrder(under: parent), kind: kind, queryJSON: queryJSON)
        try await index.insertFolder(folder)
        folders.append(folder)
        exportOrganization()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) async throws {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var updated = folders[i]
        updated.name = name
        try await index.updateFolder(updated)
        folders[i] = updated
        exportOrganization()
    }

    /// Move a folder to a new parent. Refuses (no-op) if the move would create a cycle.
    func moveFolder(_ id: UUID, newParent: UUID?, sortOrder: Int) async throws {
        guard !wouldCreateCycle(moving: id, to: newParent) else { return }
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var updated = folders[i]
        updated.parentId = newParent
        updated.sortOrder = sortOrder
        try await index.updateFolder(updated)
        folders[i] = updated
        exportOrganization()
    }

    /// Delete a folder. Children are reparented to the deleted folder's parent.
    /// Returns UUIDs of items that became orphaned (zero memberships remaining)
    /// so the caller can show the batch-delete confirmation (§3.6).
    @discardableResult
    func deleteFolder(_ id: UUID) async throws -> [UUID] {
        let deletedParent = folders.first(where: { $0.id == id })?.parentId

        // Reparent children to the deleted folder's parent (or root)
        for i in folders.indices where folders[i].parentId == id {
            folders[i].parentId = deletedParent
            try await index.updateFolder(folders[i])
        }

        let affectedMemberships = memberships.filter { $0.folderId == id }

        try await index.deleteMembershipsForFolder(id)
        try await index.deleteTemplateAssignment(folder: id)
        try await index.deleteFolder(id: id)

        memberships.removeAll { $0.folderId == id }
        assignments.removeAll { $0.folderId == id }
        folders.removeAll { $0.id == id }

        // Find items left with zero memberships
        var orphaned: [UUID] = []
        for m in affectedMemberships {
            if membershipCount(item: m.itemId) == 0 {
                orphaned.append(m.itemId)
            }
        }

        exportOrganization()
        return orphaned
    }

    // MARK: - Replication

    func addMembership(item: UUID, folder: UUID) async throws {
        guard !memberships.contains(where: { $0.itemId == item && $0.folderId == folder }) else { return }
        let m = Membership(itemId: item, folderId: folder, addedAt: Date())
        try await index.insertMembership(m)
        memberships.append(m)
        exportOrganization()
    }

    /// Returns `.removed` if the membership was deleted, or `.wasLastInstance` **without
    /// mutating** if removing would delete the item's only instance (§3.6 guard).
    func removeMembership(item: UUID, folder: UUID) async throws -> RemoveResult {
        if membershipCount(item: item) <= 1 {
            return .wasLastInstance
        }
        try await index.deleteMembership(item: item, folder: folder)
        memberships.removeAll { $0.itemId == item && $0.folderId == folder }
        exportOrganization()
        return .removed
    }

    /// Force-remove the last membership after the caller confirmed the §3.6 guard.
    /// The caller is responsible for also calling `NoteStore.delete(id)` and
    /// `NotesIndex.deleteItems([id])` to complete the deletion.
    func forceRemoveLastMembership(item: UUID, folder: UUID) async throws {
        try await index.deleteMembership(item: item, folder: folder)
        memberships.removeAll { $0.itemId == item && $0.folderId == folder }
        exportOrganization()
    }

    func foldersContaining(item: UUID) -> [UUID] {
        memberships.filter { $0.itemId == item }.map(\.folderId)
    }

    func items(in folder: UUID) -> [UUID] {
        memberships.filter { $0.folderId == folder }.map(\.itemId)
    }

    /// Every item id that is a member of `folder` **or any of its descendant folders** (the subtree
    /// union). Replicated items are counted once (a `Set`). Cycle-safe (a visited guard) and O(F + M).
    /// This is the graph analog of Reader's path-prefix scope; W6-S4 uses it to scope the item list to
    /// a selected folder (06-viewers §4, "Folder scope").
    func subtreeItemIDs(of folder: UUID) -> Set<UUID> {
        // Build the parent→children adjacency once, then walk the subtree from `folder`.
        var childrenOf: [UUID: [UUID]] = [:]
        for f in folders { if let p = f.parentId { childrenOf[p, default: []].append(f.id) } }
        var subtree: Set<UUID> = [folder]
        var stack = [folder]
        while let cur = stack.popLast() {
            for child in childrenOf[cur] ?? [] where subtree.insert(child).inserted {
                stack.append(child)
            }
        }
        var ids = Set<UUID>()
        for m in memberships where subtree.contains(m.folderId) { ids.insert(m.itemId) }
        return ids
    }

    func membershipCount(item: UUID) -> Int {
        memberships.count(where: { $0.itemId == item })
    }

    // MARK: - Templates

    func assignTemplate(_ template: UUID, to folder: UUID) async throws {
        let a = TemplateAssignment(folderId: folder, templateId: template)
        try await index.insertTemplateAssignment(a)
        if let i = assignments.firstIndex(where: { $0.folderId == folder }) {
            assignments[i] = a
        } else {
            assignments.append(a)
        }
        exportOrganization()
    }

    func removeTemplateAssignment(folder: UUID) async throws {
        try await index.deleteTemplateAssignment(folder: folder)
        assignments.removeAll { $0.folderId == folder }
        exportOrganization()
    }

    /// Resolve the template for a folder by walking up ancestors (§16.4).
    func template(for folder: UUID) -> UUID? {
        if let a = assignments.first(where: { $0.folderId == folder }) {
            return a.templateId
        }
        if let f = folders.first(where: { $0.id == folder }), let parent = f.parentId {
            return template(for: parent)
        }
        return nil
    }

    // MARK: - Private helpers

    private func nextSortOrder(under parent: UUID?) -> Int {
        let siblings = folders.filter { $0.parentId == parent }
        return (siblings.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Walk up from `target` via parentId; if we reach `id`, moving would create a cycle.
    private func wouldCreateCycle(moving id: UUID, to target: UUID?) -> Bool {
        guard let target else { return false }
        if target == id { return true }
        var current: UUID? = target
        var visited = Set<UUID>()
        while let c = current {
            if c == id { return true }
            if !visited.insert(c).inserted { break }
            current = folders.first(where: { $0.id == c })?.parentId
        }
        return false
    }

    private func seedSystemFolders() {
        let allNotes = VFolder(
            id: Self.allNotesFolderId, name: "All Notes", parentId: nil,
            sortOrder: 0, kind: .smart, queryJSON: nil)
        let inbox = VFolder(
            id: Self.inboxFolderId, name: "Inbox", parentId: nil,
            sortOrder: 1, kind: .normal, queryJSON: nil)
        let extracts = VFolder(
            id: Self.extractsFolderId, name: "Extracts", parentId: nil,
            sortOrder: 2, kind: .normal, queryJSON: nil)
        folders = [allNotes, inbox, extracts]
    }

    private func exportOrganization() {
        guard let root = storeRoot else { return }
        OrganizationFile.export(
            folders: folders, memberships: memberships,
            assignments: assignments, to: root)
    }
}
