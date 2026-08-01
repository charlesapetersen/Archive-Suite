import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

/// W23.m10-fu — a durable mirror that went stale must be RE-TRIED, not just re-reported.
///
/// W23.m10 made a failed `organization.json` export observable and clears it on the next *successful*
/// export — but the only thing that exports is an organization mutation. So the operator who hits a
/// full disk (or unplugs the volume), sees the warning, dismisses it and then simply stops touching
/// folders keeps a stale durable mirror for the whole session; and since the DB wins at startup, the
/// next launch inherits it too. The recovery window is real — the disk frees up, the volume returns —
/// and nothing was watching for it.
///
/// The fix is an export retry that runs only while the mirror is known stale, hung off app activation
/// and app terminate. These tests pin the four properties that make that safe, each of which is a way
/// the obvious implementation goes wrong: it must not rewrite a HEALTHY mirror (or every app switch
/// writes the user's file), it must actually recover the changes that missed the mirror, it must keep
/// saying so while the volume is still bad, and its retraction must not swallow another subsystem's
/// status line.
///
/// All scratch: `temporaryDirectory` fixtures and a private `NotificationCenter`, never the real notes
/// store and never the shared centre. The unwritable-volume fixture is a `0555` directory (as in
/// `OrganizationMirrorFailureTests`); permissions are always restored before cleanup, otherwise the
/// fixture directory could not be removed.
@MainActor
struct OrganizationMirrorRetryTests {

    // MARK: - Fixtures

    private func makeEnv() async throws
        -> (store: OrganizationStore, index: NotesIndex, root: URL, scratch: URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-mirror-retry-\(UUID().uuidString)")
        let dbDir = scratch.appendingPathComponent("db")
        let root = scratch.appendingPathComponent("store")
        for dir in [dbDir, root] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // The index lives OUTSIDE the store root so that making the root read-only breaks the mirror
        // write and nothing else — co-located, SQLite could not write its journal and the mutation
        // would fail before the export ever ran (see the W23.m10 suite).
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

    private func mirrorURL(_ root: URL) -> URL { root.appendingPathComponent("organization.json") }

    /// Folder names in the `organization.json` **on disk** — what a future DB rebuild would restore.
    private func mirroredFolderNames(at root: URL) -> [String] {
        (OrganizationFile.load(from: root)?.folders ?? []).map(\.name).sorted()
    }

    /// Drive a store to a stale mirror without leaving the volume broken: one folder reaches the
    /// mirror, the volume goes away, a second folder commits but misses it, the volume comes back.
    /// Returns with the mirror stale and the root writable — the exact state a retry should heal.
    private func makeRecoverableStaleMirror(_ store: OrganizationStore, root: URL) async throws {
        try await store.createFolder(name: "Before")
        try setWritable(root, false)
        try await store.createFolder(name: "Missed")
        #expect(store.isMirrorStale, "fixture: the export must actually have failed")
        try setWritable(root, true)
    }

    // MARK: - The seam: only while stale, and only after the graph is loaded

    @Test("a healthy mirror is never rewritten — an app switch must not touch the user's file")
    func healthyMirrorIsLeftAlone() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }

        try await store.createFolder(name: "Ledgers")
        #expect(store.isMirrorStale == false, "precondition: the mirror is in sync")

        // Sentinel bytes stand in for the user's file: if the retry exports unconditionally they are
        // replaced by real JSON, and this is the only cheap way to prove a write did NOT happen.
        let sentinel = Data("not-json-at-all".utf8)
        try sentinel.write(to: mirrorURL(root))

        #expect(store.retryStaleMirrorExport() == false, "nothing to retry on a healthy mirror")
        #expect(try Data(contentsOf: mirrorURL(root)) == sentinel,
                "a retry on a healthy store must not rewrite organization.json")
    }

    @Test("a retry re-exports the whole graph, recovering the change that missed the mirror")
    func retryRecoversTheMissedChange() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        try await makeRecoverableStaleMirror(store, root: root)
        #expect(!mirroredFolderNames(at: root).contains("Missed"),
                "precondition: the durable mirror really is behind")

        // No mutation — the operator does nothing at all. This is the whole point of the item.
        #expect(store.retryStaleMirrorExport() == true)

        #expect(store.mirrorFailure == nil, "a working export must clear the stale warning")
        let onDisk = mirroredFolderNames(at: root)
        #expect(onDisk.contains("Missed"),
                "the whole-graph re-export must recover the change that missed the mirror")
        #expect(onDisk.contains("Before"))
    }

    @Test("a retry against a volume that is still bad stays stale, and says so")
    func retryOnStillBrokenVolumeStaysStale() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        try await store.createFolder(name: "Before")
        try setWritable(root, false)
        try await store.createFolder(name: "Missed")
        #expect(store.isMirrorStale)

        #expect(store.retryStaleMirrorExport() == true, "it should have tried")
        #expect(store.isMirrorStale, "…and an optimistic retry must not invent a recovery")
        #expect(!mirroredFolderNames(at: root).contains("Missed"))
    }

    @Test("a store with no root has nowhere to retry to")
    func retryWithoutAStoreRootDoesNothing() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-mirror-retry-noroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let index = NotesIndex(url: scratch.appendingPathComponent("index.db"))
        try await index.open()
        defer { Task { await cleanup(scratch, index) } }

        let store = OrganizationStore(index: index)     // never `load`ed
        try await store.createFolder(name: "Nowhere")
        #expect(store.mirrorFailure == .noStoreRoot)

        // Stale, but there is no destination and no loaded graph — retrying is not a recovery path.
        #expect(store.retryStaleMirrorExport() == false)
        #expect(store.mirrorFailure == .noStoreRoot)
    }

    // MARK: - The wiring: what the operator actually does

    /// A model wired to a private notification centre, so a posted app notification reaches this test's
    /// model and no other (the suites run in parallel).
    private func makeModel(_ store: OrganizationStore)
        -> (model: NotesModel, center: NotificationCenter) {
        let center = NotificationCenter()
        return (NotesModel(organization: store, notificationCenter: center), center)
    }

    @Test("coming back to the app re-exports a mirror that can be written again")
    func activationRecoversTheMirror() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        let (model, center) = makeModel(store)
        try await store.createFolder(name: "Before")
        try setWritable(root, false)
        _ = await model.createFolder(name: "Missed", under: nil)
        #expect(model.statusMessage?.isEmpty == false, "precondition: the operator was told")

        try setWritable(root, true)                     // the volume comes back…
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)  // …and so does the operator

        #expect(store.mirrorFailure == nil, "activation must retry the export")
        #expect(mirroredFolderNames(at: root).contains("Missed"),
                "the durable mirror must be caught up without a further mutation")
        #expect(model.statusMessage == nil,
                "a claim that is no longer true must be retracted, not left on screen")
    }

    @Test("quitting is the last chance to write the mirror, and it takes it")
    func terminateRecoversTheMirror() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        let (model, center) = makeModel(store)
        try await makeRecoverableStaleMirror(store, root: root)
        model.adoptMirrorFailure()
        #expect(model.statusMessage?.isEmpty == false)

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        #expect(store.mirrorFailure == nil)
        #expect(mirroredFolderNames(at: root).contains("Missed"),
                "the next launch inherits this file — it must not be left stale on quit")
    }

    @Test("a warning the operator dismissed comes back while the volume is still bad")
    func dismissedWarningReturnsOnActivation() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        let (model, center) = makeModel(store)
        try setWritable(root, false)
        _ = await model.createFolder(name: "Missed", under: nil)
        let warning = model.statusMessage
        #expect(warning?.isEmpty == false)

        model.statusMessage = nil                       // the operator dismisses the line
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(model.statusMessage == warning,
                "while the mirror is still behind, the app must keep saying so")
    }

    @Test("a healthy model says nothing, and writes nothing, when the app is activated")
    func activationOnAHealthyStoreIsSilent() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }

        let (model, center) = makeModel(store)
        _ = await model.createFolder(name: "Ledgers", under: nil)
        #expect(model.statusMessage == nil, "precondition: nothing is wrong")

        let sentinel = Data("not-json-at-all".utf8)
        try sentinel.write(to: mirrorURL(root))
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(model.statusMessage == nil, "no false warning on a working volume")
        #expect(try Data(contentsOf: mirrorURL(root)) == sentinel,
                "activation must not rewrite a mirror that is already in sync")
    }

    @Test("recovery retracts only the mirror's own line, never another subsystem's")
    func retractionLeavesAnotherSubsystemsMessageAlone() async throws {
        let (store, index, root, scratch) = try await makeEnv()
        defer { Task { await cleanup(scratch, index) } }
        defer { try? setWritable(root, true) }

        let (model, center) = makeModel(store)
        try setWritable(root, false)
        _ = await model.createFolder(name: "Missed", under: nil)
        #expect(model.statusMessage?.isEmpty == false)

        // Something else takes the shared status line over — the index, a failed write, anything.
        let other = "The search index is unavailable."
        model.statusMessage = other

        try setWritable(root, true)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(store.mirrorFailure == nil, "the mirror did recover")
        #expect(model.statusMessage == other,
                "retracting the mirror's line must not swallow a report it did not write")
    }
}
