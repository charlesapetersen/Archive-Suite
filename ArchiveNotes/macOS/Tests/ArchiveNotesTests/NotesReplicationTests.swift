import Testing
import Foundation
@testable import ArchiveNotes

/// W6-S5 (Tier-2 — the delete path). Exercises the replication + **delete-last-instance guard** end to
/// end on a **scratch** store (`mktemp`-style temp dir, never a real corpus — Prime Directive #1):
/// membership move/replicate, the fresh-read last-instance guard, confirm→Trash, cancel→no-op, the
/// batched folder-delete, and the "show all locations" query. Deleting a note moves its dir to the
/// macOS Trash (recoverable), so even a confirmed delete is reversible.
@Suite("NotesReplication — replicants + delete-last-instance guard")
@MainActor
struct NotesReplicationTests {

    // MARK: Scratch environment

    struct Env {
        let nav: NotesNavigationModel
        let model: NotesModel
        let org: OrganizationStore
        let store: NoteStore
        let index: NotesIndex
        let root: URL
    }

    private func makeEnv() async throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-repl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        return Env(nav: nav, model: model, org: org, store: store, index: index, root: root)
    }

    private func cleanup(_ env: Env) async {
        await env.index.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private func makeItem(_ title: String) -> Item {
        Item(id: UUID(), kind: .note, title: title, authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(), modified: Date(), schema: 1, blocks: [],
             unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    private func summary(_ item: Item) -> ItemSummary {
        ItemSummary(id: item.id, title: item.title, kind: item.kind, date: nil, datePrecision: nil,
                    dateUncertain: false, authors: [], sortDate: nil, quality: nil,
                    created: item.created, modified: item.modified, mtime: 0, managedTags: [])
    }

    /// Create real on-disk notes with the given titles and seed the shared item source; returns ids.
    @discardableResult
    private func makeItems(_ env: Env, _ titles: [String]) async throws -> [UUID] {
        var ids: [UUID] = []
        var summaries: [ItemSummary] = []
        for t in titles {
            let item = makeItem(t)
            _ = try await env.store.create(item)
            ids.append(item.id)
            summaries.append(summary(item))
        }
        env.model.replaceItems(summaries)
        return ids
    }

    private func makeFolder(_ env: Env, _ name: String, kind: VFolder.Kind = .normal) async throws -> UUID {
        try await env.org.createFolder(name: name, parent: nil, kind: kind).id
    }

    private func itemDirExists(_ env: Env, _ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath:
            env.root.appendingPathComponent("items", isDirectory: true)
                .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true).path)
    }

    // MARK: - Single-item membership removal (the guard)

    @Test("removing a replicant is quiet — no confirmation, file kept")
    func replicantRemoveIsQuiet() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["A"]); let a = ids[0]
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: a, folder: f1)
        try await env.org.addMembership(item: a, folder: f2)

        await env.nav.removeMembership(a, from: f1)

        #expect(env.nav.pendingDeletion == nil)                       // no confirmation for a replicant
        #expect(env.org.membershipCount(item: a) == 1)                // removed from F1
        #expect(env.org.foldersContaining(item: a) == [f2])           // still in F2
        #expect(itemDirExists(env, a))                                // file untouched
    }

    @Test("removing the LAST instance sets a pending confirmation WITHOUT mutating")
    func lastInstanceSetsPendingWithoutMutating() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1")
        try await env.org.addMembership(item: b, folder: f1)

        await env.nav.removeMembership(b, from: f1)

        #expect(env.nav.pendingDeletion?.itemId == b)
        #expect(env.nav.pendingDeletion?.folderId == f1)
        #expect(env.nav.pendingDeletion?.title == "B")                // resolved from the shared source
        #expect(env.org.membershipCount(item: b) == 1)                // NOT mutated — guard fired first
        #expect(itemDirExists(env, b))                                // nothing deleted yet
    }

    @Test("confirming the delete-last-instance trashes the note + drops the membership")
    func confirmDeletesToTrash() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1")
        try await env.org.addMembership(item: b, folder: f1)
        await env.nav.removeMembership(b, from: f1)      // → pending

        await env.nav.confirmPendingDeletion()

        #expect(env.nav.pendingDeletion == nil)
        #expect(env.org.membershipCount(item: b) == 0)               // membership gone
        #expect(env.org.foldersContaining(item: b).isEmpty)
        #expect(!itemDirExists(env, b))                              // dir moved to Trash (recoverable)
    }

    @Test("confirmDeletion(pending) still deletes after pendingDeletion is cleared (SwiftUI dismiss race)")
    func confirmDeletionWithCapturedValueDeletes() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1")
        try await env.org.addMembership(item: b, folder: f1)
        await env.nav.removeMembership(b, from: f1)      // → pending
        let pending = try #require(env.nav.pendingDeletion)

        env.nav.pendingDeletion = nil                     // SwiftUI clears the binding the instant a button is tapped
        await env.nav.confirmDeletion(pending)            // the view path acts on the CAPTURED value

        #expect(env.org.membershipCount(item: b) == 0)
        #expect(!itemDirExists(env, b))                   // still deleted despite the cleared @Published
    }

    @Test("confirm re-checks fresh: a concurrent replicate between modal and confirm KEEPS the file")
    func confirmAfterConcurrentReplicateKeepsFile() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: b, folder: f1)
        await env.nav.removeMembership(b, from: f1)      // → pending (last instance at this moment)

        // Simulate the OTHER window replicating B while the modal is open.
        try await env.org.addMembership(item: b, folder: f2)

        await env.nav.confirmPendingDeletion()

        #expect(itemDirExists(env, b))                               // NOT trashed — no longer the last
        #expect(env.org.foldersContaining(item: b) == [f2])         // F1 unlinked, F2 replica survives
    }

    @Test("cancelling the delete-last-instance leaves the note + membership intact")
    func cancelKeepsEverything() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1")
        try await env.org.addMembership(item: b, folder: f1)
        await env.nav.removeMembership(b, from: f1)      // → pending

        env.nav.cancelPendingDeletion()

        #expect(env.nav.pendingDeletion == nil)
        #expect(env.org.membershipCount(item: b) == 1)               // untouched
        #expect(itemDirExists(env, b))                               // file kept
    }

    // MARK: - Move vs replicate

    @Test("MOVE adds to target, removes from source, and never trips the delete guard")
    func moveAddsToTargetRemovesSourceNoModal() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: b, folder: f1)   // sole instance in F1

        await env.nav.move([b], to: f2, from: f1)

        #expect(env.nav.pendingDeletion == nil)                       // moving is not deleting
        #expect(env.org.foldersContaining(item: b) == [f2])           // moved, not duplicated
        #expect(itemDirExists(env, b))
    }

    @Test("MOVE from nil source (All Notes / search) degrades to a pure add")
    func moveFromNilSourceIsPureAdd() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: b, folder: f1)

        await env.nav.move([b], to: f2, from: nil)

        #expect(Set(env.org.foldersContaining(item: b)) == [f1, f2])  // added, source untouched
        #expect(itemDirExists(env, b))
    }

    @Test("REPLICATE adds a membership without removing any (DevonThink replicant)")
    func replicateAddsWithoutRemoving() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: b, folder: f1)

        await env.nav.replicate([b], to: f2)

        #expect(env.org.membershipCount(item: b) == 2)
        #expect(Set(env.org.foldersContaining(item: b)) == [f1, f2])
    }

    @Test("REPLICATE onto a smart folder is refused (smart folders aren't containers)")
    func replicateOntoSmartFolderRefused() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1")
        let smart = try await makeFolder(env, "Saved", kind: .smart)
        try await env.org.addMembership(item: b, folder: f1)

        await env.nav.replicate([b], to: smart)

        #expect(env.org.membershipCount(item: b) == 1)               // unchanged
        #expect(env.org.foldersContaining(item: b) == [f1])
        #expect(env.model.statusMessage != nil)
    }

    @Test("MOVE onto a smart folder is refused and does not remove from source")
    func moveOntoSmartFolderRefused() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["B"]); let b = ids[0]
        let f1 = try await makeFolder(env, "F1")
        let smart = try await makeFolder(env, "Saved", kind: .smart)
        try await env.org.addMembership(item: b, folder: f1)

        await env.nav.move([b], to: smart, from: f1)

        #expect(env.org.foldersContaining(item: b) == [f1])          // still in source
        #expect(env.model.statusMessage != nil)
    }

    // MARK: - Batched folder delete

    @Test("stranded-by-deleting-folder reads fresh; a later replicate un-strands an item")
    func strandedFreshRead() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["A", "B"]); let a = ids[0]; let b = ids[1]
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: a, folder: f1)
        try await env.org.addMembership(item: a, folder: f2)   // A is a replicant (F1 + F2)
        try await env.org.addMembership(item: b, folder: f1)   // B lives only in F1

        #expect(env.model.strandedByDeletingFolder(f1) == [b])       // only B would be lost

        await env.nav.replicate([b], to: f2)                          // B now also in F2
        #expect(env.model.strandedByDeletingFolder(f1) == [])         // nothing stranded anymore
    }

    @Test("deleteFolderDeletingStranded trashes sole-instance notes but keeps replicants")
    func deleteFolderDeletingStrandedTrashesSoleItems() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["A", "C"]); let a = ids[0]; let c = ids[1]
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: a, folder: f1)
        try await env.org.addMembership(item: a, folder: f2)   // replicant
        try await env.org.addMembership(item: c, folder: f1)   // sole instance

        let stranded = env.model.strandedByDeletingFolder(f1)
        #expect(stranded == [c])

        await env.model.deleteFolderDeletingStranded(f1, stranded: stranded)

        #expect(!env.org.folders.contains { $0.id == f1 })           // folder gone
        #expect(!itemDirExists(env, c))                              // sole-instance C trashed
        #expect(env.org.membershipCount(item: c) == 0)
        #expect(itemDirExists(env, a))                               // replicant A survives (still in F2)
        #expect(env.org.foldersContaining(item: a) == [f2])
    }

    @Test("batched delete re-checks fresh: an item replicated after the modal is NOT trashed")
    func batchedDeleteSkipsRescuedItem() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["C"]); let c = ids[0]
        let f1 = try await makeFolder(env, "F1"); let f2 = try await makeFolder(env, "F2")
        try await env.org.addMembership(item: c, folder: f1)

        let stranded = env.model.strandedByDeletingFolder(f1)       // [c] at click time
        #expect(stranded == [c])

        // Simulate the OTHER window replicating C while the confirmation modal is open.
        try await env.org.addMembership(item: c, folder: f2)

        await env.model.deleteFolderDeletingStranded(f1, stranded: stranded)

        #expect(!env.org.folders.contains { $0.id == f1 })          // folder still deleted
        #expect(itemDirExists(env, c))                              // but C survives (it's in F2 now)
        #expect(env.org.foldersContaining(item: c) == [f2])
    }

    @Test("titles(for:) surfaces the batched-delete note names")
    func titlesForBatch() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["First", "Second"])
        #expect(env.model.titles(for: ids) == ["First", "Second"])
        #expect(env.model.titles(for: [UUID()]) == ["Untitled"])     // unknown id → fallback
    }

    // MARK: - Locations inspector

    @Test("locations(of:) lists every folder an item is in, sorted by name")
    func locationsListsAllFoldersSorted() async throws {
        let env = try await makeEnv(); defer { Task { await cleanup(env) } }
        let ids = try await makeItems(env, ["A"]); let a = ids[0]
        let beta = try await makeFolder(env, "Beta")
        let alpha = try await makeFolder(env, "Alpha")
        try await env.org.addMembership(item: a, folder: beta)
        try await env.org.addMembership(item: a, folder: alpha)

        #expect(env.nav.locations(of: a).map(\.name) == ["Alpha", "Beta"])
    }
}
