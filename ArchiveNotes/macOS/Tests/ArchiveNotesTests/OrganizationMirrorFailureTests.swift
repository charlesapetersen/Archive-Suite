import Testing
import Foundation
@testable import ArchiveNotes

/// W23.m10 — `organization.json` is the documented durable mirror (§4/§11): the graph is rebuilt from
/// it after a DB wipe or a move to another Mac. Before this item, `OrganizationFile.export` swallowed
/// both its encode and its atomic write, so on a full, read-only or vanished volume every folder /
/// membership / template change was reported as saved while the mirror stayed **stale**.
///
/// These tests are all **scratch only** — `temporaryDirectory` fixtures, never the real notes store.
///
/// The unwritable-volume fixture is a directory chmod'd to `0555`. That is the finding's literal
/// scenario and it reproduces its nastiest property: a failed atomic write leaves the PREVIOUS
/// `organization.json` bytes in place, so the mirror doesn't go missing — it goes quietly *wrong*.
/// Permissions are always restored before cleanup (`defer` is LIFO: restore is declared last, so it
/// runs first), otherwise the fixture directory could not be removed.
@MainActor
struct OrganizationMirrorFailureTests {

    // MARK: - Fixtures

    private func makeEnv() async throws
        -> (store: OrganizationStore, index: NotesIndex, root: URL, scratch: URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-mirror-test-\(UUID().uuidString)")
        let dbDir = scratch.appendingPathComponent("db")
        let root = scratch.appendingPathComponent("store")
        for dir in [dbDir, root] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // The index lives OUTSIDE the store root on purpose. Making the store root read-only must
        // break the mirror write and nothing else — with the DB in the same directory, SQLite could
        // not create its journal/WAL sidecars either and the mutation would fail *before* the export,
        // which would test the wrong thing entirely.
        let index = NotesIndex(url: dbDir.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index)
        try await store.load(storeRoot: root)
        return (store, index, root, scratch)
    }

    private func cleanup(_ scratch: URL, _ index: NotesIndex) async {
        await index.close()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func setWritable(_ dir: URL, _ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555],
                                              ofItemAtPath: dir.path)
    }

    /// Folder names recorded in the `organization.json` **on disk** (not in memory) — the only honest
    /// way to ask what a future DB rebuild would actually restore.
    private func mirroredFolderNames(at root: URL) -> [String] {
        (OrganizationFile.load(from: root)?.folders ?? []).map(\.name).sorted()
    }

    // MARK: - The seam itself

    @Test("export propagates an unwritable destination instead of swallowing it")
    func exportThrowsOnUnwritableRoot() async throws {
        let (_, index, _, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        let gone = scratch.appendingPathComponent("volume-went-away")

        #expect(throws: (any Error).self) {
            try OrganizationFile.export(folders: [], memberships: [], assignments: [], to: gone)
        }
    }

    @Test("a healthy mutation leaves the mirror in sync and says nothing")
    func healthyMutationLeavesMirrorInSync() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }

        try await store.createFolder(name: "Ledgers")

        #expect(store.mirrorFailure == nil, "a working export must not raise a false warning")
        #expect(store.isMirrorStale == false)
        #expect(mirroredFolderNames(at: root).contains("Ledgers"),
                "the durable mirror must actually hold the new folder")
    }

    // MARK: - The finding: a failed export, and a mirror that really is stale

    @Test("a failed export is reported — and the mirror on disk really is stale")
    func failedExportIsReportedAndMirrorIsStale() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        try await store.createFolder(name: "Before")
        #expect(store.mirrorFailure == nil, "precondition: the mirror starts in sync")

        try setWritable(root, false)                    // the volume goes read-only / full
        try await store.createFolder(name: "After")

        // The mutation itself committed — that is exactly why the silence was dangerous.
        #expect(store.folders.contains { $0.name == "After" },
                "the change commits in memory + SQLite regardless; only the mirror failed")
        #expect(store.isMirrorStale, "…and the app must now say the durable mirror is behind")
        if case .writeFailed = store.mirrorFailure {} else {
            Issue.record("expected .writeFailed, got \(String(describing: store.mirrorFailure))")
        }
        #expect(store.mirrorFailure?.message.isEmpty == false, "the sidebar needs a line to show")

        // The heart of the finding: the mirror is not missing, it is WRONG. A DB wipe here restores
        // an organization that no longer matches what the operator was told was saved.
        let onDisk = mirroredFolderNames(at: root)
        #expect(onDisk.contains("Before"), "a failed atomic write leaves the previous bytes behind")
        #expect(!onDisk.contains("After"), "the new folder never reached the durable mirror")
    }

    @Test("a later successful export clears the warning AND recovers the change that missed the mirror")
    func laterSuccessRecoversTheMissedChange() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        try await store.createFolder(name: "Before")
        try setWritable(root, false)
        try await store.createFolder(name: "Missed")       // export fails
        #expect(store.isMirrorStale)

        try setWritable(root, true)                        // the volume comes back
        try await store.createFolder(name: "After")

        #expect(store.mirrorFailure == nil, "a working export must clear a stale warning")
        let onDisk = mirroredFolderNames(at: root)
        // The export is whole-graph, not incremental — so one working write re-syncs everything,
        // including the folder whose own export failed. Nothing has to be replayed.
        #expect(onDisk.contains("Missed"),
                "the whole-graph re-export must recover the change that missed the mirror")
        #expect(onDisk.contains("Before") && onDisk.contains("After"))
    }

    @Test("with no store root there is nowhere to mirror, and that is reported too")
    func noStoreRootIsReported() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-mirror-noroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let index = NotesIndex(url: scratch.appendingPathComponent("index.db"))
        try await index.open()
        defer { Task { await cleanup(scratch, index) } }

        let store = OrganizationStore(index: index)        // never `load`ed: no store root
        #expect(store.mirrorFailure == nil, "nothing has been committed yet, so nothing is unmirrored")

        try await store.createFolder(name: "Nowhere")

        #expect(store.mirrorFailure == .noStoreRoot)
        #expect(store.folders.contains { $0.name == "Nowhere" })
    }

    // MARK: - Every mutation kind, attributed individually

    /// Run `mutate` with the store root unwritable, having proved the mirror was in sync first — so a
    /// stale verdict afterwards is attributable to *that* mutation and not to leftover setup state.
    private func expectReportsStaleMirror(
        _ label: String,
        setup: (OrganizationStore) async throws -> Void = { _ in },
        mutate: (OrganizationStore) async throws -> Void
    ) async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        try await setup(store)
        #expect(store.mirrorFailure == nil, "\(label): setup must leave the mirror in sync")

        try setWritable(root, false)
        try await mutate(store)

        #expect(store.isMirrorStale, "\(label): a mutation whose mirror write failed must report it")
    }

    @Test("every organization mutation reports a mirror it could not write")
    func everyMutationReportsAStaleMirror() async throws {
        let item = UUID(), template = UUID()

        // Each case gets its own fresh store; the setup runs while the root is still writable.
        try await expectReportsStaleMirror("createFolder") { store in
            try await store.createFolder(name: "New")
        }
        try await expectReportsStaleMirror("renameFolder", setup: { store in
            _ = try await store.createFolder(name: "Old")
        }, mutate: { store in
            let id = store.folders.first { $0.name == "Old" }!.id
            try await store.renameFolder(id, to: "Renamed")
        })
        try await expectReportsStaleMirror("moveFolder", setup: { store in
            _ = try await store.createFolder(name: "Parent")
            _ = try await store.createFolder(name: "Child")
        }, mutate: { store in
            let parent = store.folders.first { $0.name == "Parent" }!.id
            let child = store.folders.first { $0.name == "Child" }!.id
            try await store.moveFolder(child, newParent: parent, sortOrder: 0)
        })
        try await expectReportsStaleMirror("deleteFolder", setup: { store in
            _ = try await store.createFolder(name: "Doomed")
        }, mutate: { store in
            let id = store.folders.first { $0.name == "Doomed" }!.id
            _ = try await store.deleteFolder(id)
        })
        try await expectReportsStaleMirror("addMembership") { store in
            try await store.addMembership(item: item, folder: OrganizationStore.inboxFolderId)
        }
        // A removal only mutates when the item is a replicant (≥2 memberships) — a sole membership
        // returns `.wasLastInstance` without touching anything, so it must NOT be the fixture here.
        try await expectReportsStaleMirror("removeMembership", setup: { store in
            try await store.addMembership(item: item, folder: OrganizationStore.inboxFolderId)
            try await store.addMembership(item: item, folder: OrganizationStore.extractsFolderId)
        }, mutate: { store in
            let r = try await store.removeMembership(item: item,
                                                     folder: OrganizationStore.extractsFolderId)
            if case .removed = r {} else {
                Issue.record("fixture must exercise the mutating branch, got \(r)")
            }
        })
        try await expectReportsStaleMirror("removeConfirmedLastMembership", setup: { store in
            try await store.addMembership(item: item, folder: OrganizationStore.inboxFolderId)
        }, mutate: { store in
            _ = try await store.removeConfirmedLastMembership(
                item: item, folder: OrganizationStore.inboxFolderId)
        })
        try await expectReportsStaleMirror("assignTemplate") { store in
            try await store.assignTemplate(template, to: OrganizationStore.inboxFolderId)
        }
        try await expectReportsStaleMirror("removeTemplateAssignment", setup: { store in
            try await store.assignTemplate(template, to: OrganizationStore.inboxFolderId)
        }, mutate: { store in
            try await store.removeTemplateAssignment(folder: OrganizationStore.inboxFolderId)
        })
    }

    // MARK: - What the operator actually sees

    @Test("the façade still completes the change AND stops calling it saved")
    func modelCompletesTheChangeAndSaysTheMirrorFailed() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        let model = NotesModel(organization: store)
        try setWritable(root, false)

        let id = await model.createFolder(name: "Correspondence", under: nil)

        // Anti-regression for the shape of this fix: the export is the LAST step, so the folder DOES
        // exist. Turning the failure into a thrown error would make this `nil` and skip the rebuild —
        // reporting "Couldn't create the folder" about a folder the user can see next launch.
        #expect(id != nil, "the folder was created; the façade must not pretend otherwise")
        #expect(model.normalTree.contains { $0.name == "Correspondence" },
                "the tree must still be rebuilt so the committed change is visible")
        // …and the actual finding: it is no longer reported as a plain success.
        #expect(model.statusMessage?.isEmpty == false,
                "the sidebar must say the durable mirror wasn't written")
        #expect(model.statusMessage == store.mirrorFailure?.message)
    }

    @Test("a healthy façade mutation posts no warning")
    func modelHealthyMutationIsSilent() async throws {
        let (store, index, _, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }

        let model = NotesModel(organization: store)
        let id = await model.createFolder(name: "Correspondence", under: nil)

        #expect(id != nil)
        #expect(model.statusMessage == nil, "no false warning on a working volume")
    }

    @Test("the navigation model's replicate and move surface it too")
    func navigationSurfacesTheStaleMirror() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        let target = try await store.createFolder(name: "Filed").id
        let model = NotesModel(organization: store)
        let nav = NotesNavigationModel(model: model, defaultKind: .note)
        let item = UUID()

        try setWritable(root, false)
        await nav.replicate([item], to: target)
        #expect(model.statusMessage?.isEmpty == false, "replicate must report the unwritten mirror")
        #expect(store.memberships.contains { $0.itemId == item && $0.folderId == target })

        model.statusMessage = nil
        await nav.move([item], to: OrganizationStore.inboxFolderId, from: target)
        #expect(model.statusMessage?.isEmpty == false, "move must report the unwritten mirror")
    }
}
