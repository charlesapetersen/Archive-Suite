import Foundation

/// A node in the Notes virtual folder tree — **id-keyed (UUID), user-authored and mutable**, unlike
/// Reader's path-derived, read-only `FolderNode` (`NavigationModel.swift:8-16`). Built from
/// `OrganizationStore`'s flat `[VFolder]` adjacency list (grouped by `parentId`). 06-viewers §2, W6-S2.
///
/// The `childrenOrNil` accessor mirrors Reader's `FolderNode.childrenOrNil` so the SwiftUI
/// `OutlineGroup(children:)` shows a disclosure triangle only for non-leaf nodes.
struct NotesFolderNode: Identifiable, Hashable, Sendable {
    let id: UUID                 // VFolder.id — NOT a path (the key difference from Reader)
    var name: String
    var kind: VFolder.Kind
    var queryJSON: String?       // smart-folder encoded NotesFilter (nil for normal folders)
    var itemCount: Int           // DISTINCT items in this subtree (a replicant is counted once)
    var children: [NotesFolderNode]
    var childrenOrNil: [NotesFolderNode]? { children.isEmpty ? nil : children }
}

extension NotesFolderNode {
    /// Build the hierarchical forest of **normal** folders from `OrganizationStore`'s flat adjacency
    /// list. The plan's `buildFolderTree` (06-viewers §2) — a group-by-`parentId` build, distinct from
    /// Reader's path-split `buildFolderTree` (`NavigationModel.swift:662-690`).
    ///
    /// - Groups folders by `parentId`; sorts siblings by `sortOrder`, then `localizedStandardCompare`
    ///   on name (matching Reader's sibling sort at `NavigationModel.swift:687`).
    /// - `itemCount` = number of **distinct** item ids reachable in the subtree, so a note replicated
    ///   into several folders is counted once per subtree (the DevonThink "replicant" model, §1).
    /// - Only `.normal` folders form the tree. Smart folders (including the seeded All-Notes root) are
    ///   surfaced separately by the view (`smartFolderNodes` + the "All Notes" pseudo-row).
    /// - **Orphan-safe:** a folder whose `parentId` is not a known normal folder is attached at the
    ///   root, so an item under it can never vanish from the tree (§2 "never lost from view").
    /// - **Cycle-safe:** a `visited` set stops a corrupt `organization.json` (a `parentId` cycle) from
    ///   spinning the recursion — a defensive backstop on top of `OrganizationStore.moveFolder`'s guard.
    ///
    /// O(F + M) modulo the sibling sorts.
    static func buildNormalForest(folders: [VFolder],
                                  memberships: [Membership]) -> [NotesFolderNode] {
        let normal = folders.filter { $0.kind == .normal }
        let knownIDs = Set(normal.map(\.id))

        // children[parent] — a parent that isn't a known normal folder is remapped to `nil` (root),
        // which keeps orphaned subtrees visible under the root instead of dropping them.
        var childrenByParent: [UUID?: [VFolder]] = [:]
        for f in normal {
            let parent: UUID? = f.parentId.flatMap { knownIDs.contains($0) ? $0 : nil }
            childrenByParent[parent, default: []].append(f)
        }

        var itemsByFolder: [UUID: Set<UUID>] = [:]
        for m in memberships { itemsByFolder[m.folderId, default: []].insert(m.itemId) }

        func sortedSiblings(_ arr: [VFolder]) -> [VFolder] {
            arr.sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        // Returns (node, distinct item ids in this subtree) so counts union up the tree.
        func build(_ f: VFolder, _ visited: inout Set<UUID>) -> (node: NotesFolderNode, items: Set<UUID>) {
            let own = itemsByFolder[f.id] ?? []
            guard !visited.contains(f.id) else {
                // Cycle backstop: render the node as a childless leaf, count only its own items.
                return (NotesFolderNode(id: f.id, name: f.name, kind: f.kind, queryJSON: f.queryJSON,
                                        itemCount: own.count, children: []), own)
            }
            visited.insert(f.id)
            var subtree = own
            var childNodes: [NotesFolderNode] = []
            for child in sortedSiblings(childrenByParent[f.id] ?? []) {
                let (childNode, childItems) = build(child, &visited)
                childNodes.append(childNode)
                subtree.formUnion(childItems)
            }
            let node = NotesFolderNode(id: f.id, name: f.name, kind: f.kind, queryJSON: f.queryJSON,
                                       itemCount: subtree.count, children: childNodes)
            return (node, subtree)
        }

        var visited: Set<UUID> = []
        return sortedSiblings(childrenByParent[nil] ?? []).map { build($0, &visited).node }
    }

    /// The flat list of smart folders for the "Smart Folders" section — every `.smart` folder except
    /// those in `excluding` (the seeded All-Notes root, which the view renders as its own row). Sorted
    /// by `sortOrder` then localized name. `itemCount` is left 0 here: a smart folder's badge is a
    /// *live* query match count, which is served by the index in W6-S4 (search); the view omits the
    /// badge for smart folders until then.
    static func smartFolderNodes(folders: [VFolder],
                                 excluding: Set<UUID>) -> [NotesFolderNode] {
        folders
            .filter { $0.kind == .smart && !excluding.contains($0.id) }
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            .map { NotesFolderNode(id: $0.id, name: $0.name, kind: .smart,
                                   queryJSON: $0.queryJSON, itemCount: 0, children: []) }
    }
}
