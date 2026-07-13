import Testing
import Foundation
@testable import ArchiveNotes

/// Pure tests for the W6-S2 folder-tree build (`NotesFolderNode.buildNormalForest` /
/// `smartFolderNodes`) — no live store, just hand-built `[VFolder]` + `[Membership]`.
struct NotesFolderTreeTests {

    private func f(_ name: String, id: UUID = UUID(), parent: UUID? = nil, order: Int = 0,
                   kind: VFolder.Kind = .normal, query: String? = nil) -> VFolder {
        VFolder(id: id, name: name, parentId: parent, sortOrder: order, kind: kind, queryJSON: query)
    }
    private func m(_ item: UUID, in folder: UUID) -> Membership {
        Membership(itemId: item, folderId: folder, addedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func emptyInputsYieldEmptyForest() {
        #expect(NotesFolderNode.buildNormalForest(folders: [], memberships: []).isEmpty)
        #expect(NotesFolderNode.smartFolderNodes(folders: [], excluding: []).isEmpty)
    }

    @Test func siblingsSortBySortOrderThenLocalizedName() {
        // Same sortOrder → localized name order; different sortOrder → sortOrder wins.
        let folders = [
            f("Zebra", order: 0),
            f("apple", order: 0),
            f("First", order: -5),
        ]
        let forest = NotesFolderNode.buildNormalForest(folders: folders, memberships: [])
        #expect(forest.map(\.name) == ["First", "apple", "Zebra"])
    }

    @Test func nestingFollowsParentId() {
        let root = UUID(), child = UUID(), grandchild = UUID()
        let folders = [
            f("Root", id: root),
            f("Child", id: child, parent: root),
            f("Grandchild", id: grandchild, parent: child),
        ]
        let forest = NotesFolderNode.buildNormalForest(folders: folders, memberships: [])
        #expect(forest.count == 1)
        #expect(forest[0].id == root)
        #expect(forest[0].children.map(\.id) == [child])
        #expect(forest[0].children[0].children.map(\.id) == [grandchild])
        // Leaves have nil childrenOrNil (no disclosure triangle); parents don't.
        #expect(forest[0].childrenOrNil != nil)
        #expect(forest[0].children[0].children[0].childrenOrNil == nil)
    }

    @Test func distinctSubtreeCountCountsReplicantsOnce() {
        let parent = UUID(), child = UUID()
        let x = UUID(), y = UUID()
        let folders = [f("Parent", id: parent), f("Child", id: child, parent: parent)]
        // X is replicated into BOTH parent and child; Y lives only in child.
        let memberships = [m(x, in: parent), m(x, in: child), m(y, in: child)]
        let forest = NotesFolderNode.buildNormalForest(folders: folders, memberships: memberships)
        let p = forest[0]
        #expect(p.itemCount == 2)               // {X, Y} — X counted once despite two memberships
        #expect(p.children[0].itemCount == 2)   // child has {X, Y}
    }

    @Test func smartFoldersAreNotInNormalForest() {
        let folders = [f("Real", kind: .normal), f("Saved Search", kind: .smart)]
        let forest = NotesFolderNode.buildNormalForest(folders: folders, memberships: [])
        #expect(forest.map(\.name) == ["Real"])
    }

    @Test func orphanedFolderSurfacesAtRoot() {
        // A folder whose parent isn't a known normal folder must still appear (never lost from view).
        let missingParent = UUID()
        let folders = [f("Stranded", parent: missingParent)]
        let forest = NotesFolderNode.buildNormalForest(folders: folders, memberships: [])
        #expect(forest.map(\.name) == ["Stranded"])
    }

    @Test func parentCycleDoesNotHang() {
        // Corrupt graph: A↔B point at each other. Neither reaches a nil root, so the forest is empty,
        // and — critically — the build terminates (the visited-set backstop).
        let a = UUID(), b = UUID()
        let folders = [f("A", id: a, parent: b), f("B", id: b, parent: a)]
        let forest = NotesFolderNode.buildNormalForest(folders: folders, memberships: [])
        #expect(forest.isEmpty)
    }

    @Test func smartFolderNodesExcludeGivenRoots() {
        let all = UUID()                    // stands in for the seeded All-Notes root
        let userSmart = UUID()
        let folders = [
            f("All Notes", id: all, kind: .smart),
            f("My Query", id: userSmart, kind: .smart, query: "{}"),
            f("Normal", kind: .normal),
        ]
        let smart = NotesFolderNode.smartFolderNodes(folders: folders, excluding: [all])
        #expect(smart.map(\.id) == [userSmart])
        #expect(smart[0].queryJSON == "{}")
    }
}
