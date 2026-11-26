import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

/// W49.notes-org-export-async — a mutation no longer encodes and rewrites the whole `organization.json`
/// on the main actor. It marks the mirror dirty; a short debounce gathers a burst into one write,
/// which is encoded and written on a serial background queue. These tests pin what that must keep:
/// every committed change still reaches the file, the newest outcome is the one reported, and quitting
/// writes what is still pending. Scratch directories only, never the real notes store.
@MainActor
struct OrganizationMirrorCoalescingTests {

    private func makeEnv(debounce: Duration) async throws
        -> (store: OrganizationStore, index: NotesIndex, root: URL, scratch: URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-mirror-coalesce-\(UUID().uuidString)")
        let dbDir = scratch.appendingPathComponent("db")
        let root = scratch.appendingPathComponent("store")
        for dir in [dbDir, root] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // The index lives outside the store root, so making the root read-only fails only the mirror.
        let index = NotesIndex(url: dbDir.appendingPathComponent("index.db"))
        try await index.open()
        let store = OrganizationStore(index: index, mirrorDebounce: debounce)
        try await store.load(storeRoot: root)
        await store.flushPendingMirror()
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

    private func mirrored(_ root: URL)
        -> (folders: [VFolder], memberships: [Membership], assignments: [TemplateAssignment])? {
        OrganizationFile.load(from: root)
    }

    /// The file on disk holds exactly the graph in memory.
    private func expectMirrorMatchesMemory(_ store: OrganizationStore, _ root: URL,
                                           sourceLocation: SourceLocation = #_sourceLocation) {
        guard let file = mirrored(root) else {
            Issue.record("organization.json is missing or unreadable", sourceLocation: sourceLocation)
            return
        }
        #expect(Set(file.folders.map(\.id)) == Set(store.folders.map(\.id)),
                sourceLocation: sourceLocation)
        #expect(Set(file.folders.map(\.name)) == Set(store.folders.map(\.name)),
                sourceLocation: sourceLocation)
        #expect(file.memberships.count == store.memberships.count, sourceLocation: sourceLocation)
        #expect(Set(file.memberships.map { "\($0.folderId)/\($0.itemId)" })
                == Set(store.memberships.map { "\($0.folderId)/\($0.itemId)" }),
                sourceLocation: sourceLocation)
        #expect(file.assignments.count == store.assignments.count, sourceLocation: sourceLocation)
    }

    @Test("a mutation returns before the mirror is written, and the write follows")
    func mutationDoesNotWaitForTheMirror() async throws {
        let (store, index, root, scratch) = try await makeEnv(debounce: .seconds(30))
        defer { Task { await cleanup(scratch, index) } }

        let before = store.mirrorWriteCount
        try await store.createFolder(name: "Ledgers")
        #expect(store.folders.contains { $0.name == "Ledgers" }, "the change is live at once")
        #expect(store.mirrorWriteCount == before, "no whole-graph write on the mutation's own path")
        #expect(mirrored(root)?.folders.contains { $0.name == "Ledgers" } != true,
                "the file is written after the debounce, not inside the mutation")

        await store.flushPendingMirror()
        #expect(store.mirrorWriteCount == before + 1)
        #expect(store.mirrorFailure == nil)
        expectMirrorMatchesMemory(store, root)
    }

    @Test("a burst of 500 mutations is written once, and the file holds all of them")
    func burstIsCoalescedIntoOneWrite() async throws {
        let (store, index, root, scratch) = try await makeEnv(debounce: .seconds(30))
        defer { Task { await cleanup(scratch, index) } }

        let folder = try await store.createFolder(name: "Bulk").id
        let before = store.mirrorWriteCount
        let items = (0..<500).map { _ in UUID() }
        for item in items { try await store.addMembership(item: item, folder: folder) }
        await store.flushPendingMirror()

        #expect(store.mirrorWriteCount == before + 1, "500 changes, one whole-graph write")
        #expect(store.mirrorFailure == nil)
        let filed = Set(mirrored(root)?.memberships.filter { $0.folderId == folder }.map(\.itemId) ?? [])
        #expect(filed == Set(items), "every change in the burst reached the durable mirror")
        expectMirrorMatchesMemory(store, root)
    }

    @Test("the debounce fires by itself: a mutation reaches the file with nobody flushing")
    func debounceWritesWithoutAFlush() async throws {
        let (store, index, root, scratch) = try await makeEnv(debounce: .milliseconds(20))
        defer { Task { await cleanup(scratch, index) } }

        try await store.createFolder(name: "Unprompted")
        let deadline = ContinuousClock.now + .seconds(10)
        while mirrored(root)?.folders.contains(where: { $0.name == "Unprompted" }) != true,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mirrored(root)?.folders.contains { $0.name == "Unprompted" } == true)
    }

    @Test("mutations interleaved with running writes end with the file equal to memory")
    func interleavedMutationsConverge() async throws {
        let (store, index, root, scratch) = try await makeEnv(debounce: .zero)
        defer { Task { await cleanup(scratch, index) } }

        var made: [UUID] = []
        for n in 0..<60 {
            let f = try await store.createFolder(name: "F\(n)")
            made.append(f.id)
            try await store.addMembership(item: UUID(), folder: f.id)
            if n % 3 == 0, let doomed = made.first, made.count > 2 {
                _ = try await store.deleteFolder(doomed)
                made.removeFirst()
            }
            if n % 5 == 0 { await Task.yield() }          // let a write start mid-burst
        }
        await store.flushPendingMirror()

        #expect(store.mirrorFailure == nil)
        #expect(store.mirrorWriteCount > 1, "fixture: writes really did run during the burst")
        expectMirrorMatchesMemory(store, root)
    }

    @Test("quitting writes a change still waiting for its debounce")
    func terminateFlushesThePendingWrite() async throws {
        let (store, index, root, scratch) = try await makeEnv(debounce: .seconds(30))
        defer { Task { await cleanup(scratch, index) } }

        let center = NotificationCenter()
        let model = NotesModel(organization: store, notificationCenter: center)
        _ = await model.createFolder(name: "Last minute", under: nil)
        #expect(mirrored(root)?.folders.contains { $0.name == "Last minute" } != true,
                "precondition: the write is still pending")

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        // Synchronously, before the notification returns: the process may end right after it.
        #expect(mirrored(root)?.folders.contains { $0.name == "Last minute" } == true,
                "the next launch inherits this file; a pending change must not be lost on quit")
        #expect(store.mirrorFailure == nil)
        #expect(model.statusMessage == nil)
        expectMirrorMatchesMemory(store, root)
    }

    @Test("a mutation does not re-post the previous write's warning before its own write lands")
    func mutationWaitsForItsOwnOutcome() async throws {
        let (store, index, root, scratch) = try await makeEnv(debounce: .seconds(30))
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        let model = NotesModel(organization: store, notificationCenter: NotificationCenter())
        try setWritable(root, false)
        _ = await model.createFolder(name: "Missed", under: nil)
        await store.flushPendingMirror()
        #expect(model.statusMessage?.isEmpty == false, "precondition: the stale mirror was reported")

        let other = "The search index is unavailable."
        model.statusMessage = other
        try setWritable(root, true)
        _ = await model.createFolder(name: "Heals it", under: nil)
        #expect(model.statusMessage == other, "the old warning must not come back while the write is pending")

        await store.flushPendingMirror()
        #expect(store.mirrorFailure == nil)
        #expect(model.statusMessage == other, "recovery retracts only the mirror's own line")
        expectMirrorMatchesMemory(store, root)
    }

    @Test("the outcome of a later write is never overwritten by an earlier one's")
    func newestOutcomeWins() async throws {
        let (store, index, root, scratch) = try await makeEnv(debounce: .seconds(30))
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        try setWritable(root, false)
        try await store.createFolder(name: "Missed")
        await store.flushPendingMirror()
        #expect(store.isMirrorStale, "fixture: the first write failed")

        // A retry starts a write in the background; the synchronous quit flush is queued behind it
        // on the same serial queue, so it writes last. Its success must be what stays reported,
        // even though the background write's outcome is applied after it.
        #expect(store.retryStaleMirrorExport())
        try setWritable(root, true)
        store.flushMirrorSynchronously()
        #expect(store.mirrorFailure == nil, "the last write succeeded")
        await store.flushPendingMirror()
        #expect(store.mirrorFailure == nil, "an older write's outcome must not replace the newer one")
        expectMirrorMatchesMemory(store, root)
    }

    @Test("a write still pending for one store root lands there before the store loads another")
    func loadFlushesThePreviousRoot() async throws {
        let (store, index, root, scratch) = try await makeEnv(debounce: .seconds(30))
        defer { Task { await cleanup(scratch, index) } }

        try await store.createFolder(name: "Belongs to the first store")
        let other = scratch.appendingPathComponent("other-store")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await store.load(storeRoot: other)
        await store.flushPendingMirror()

        #expect(mirrored(root)?.folders.contains { $0.name == "Belongs to the first store" } == true,
                "the pending write went to the root it was made under")
        #expect(mirrored(other)?.folders.contains { $0.name == "Belongs to the first store" } != true,
                "and never into the next store's mirror")
    }
}
