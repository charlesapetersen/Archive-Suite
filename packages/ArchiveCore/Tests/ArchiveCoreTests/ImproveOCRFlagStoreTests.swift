// ImproveOCRFlagStoreTests.swift — the shared OCR Poor flag generations (W44.reocr-processor)
import Testing
import Foundation
import Darwin
@testable import ArchiveCore

@Suite("ImproveOCRFlagStore")
struct ImproveOCRFlagStoreTests {
    let root = UUID(uuidString: "7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e")!

    private func store(lockTimeout: TimeInterval = 10) throws -> ImproveOCRFlagStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flagstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ImproveOCRFlagStore(support: dir, lockTimeout: lockTimeout)
    }

    private var key: ImproveOCRFlagStore.FileKey { .init(rootGUID: root, relativePath: "Box 3/Folder 2/letter.pdf") }

    @Test func everyActionAdvancesTheGeneration() throws {
        let s = try store()
        let first = try s.withLock(key, app: "Reader") { l -> UUID in
            #expect(try l.state() == .init(generation: nil, flagged: nil, pending: nil))
            let i = try l.begin(flagged: true, origin: .flag)
            let e = try l.commit(i, observedFlagged: true)
            #expect(e.sequence == 1 && e.flagged && e.generation == i.generation)
            return e.generation
        }
        // Flagging an already flagged file is still a new action with a new generation.
        let second = try s.withLock(key, app: "Reader") { l -> UUID in
            try l.commit(l.begin(flagged: true, origin: .flag), observedFlagged: true).generation
        }
        #expect(first != second)
        let state = try s.withLock(key, app: "Processor") { try $0.state() }
        #expect(state.generation == second && state.flagged == true && state.pending == nil)
        // A new store over the same folder (another app, a relaunch) reads the same state.
        #expect(try ImproveOCRFlagStore(support: s.support).peek(key) == state)
    }

    @Test func anUnfinishedActionIsABarrierUntilReconciled() throws {
        let s = try store()
        let intent = try s.withLock(key, app: "Reader") { try $0.begin(flagged: true, origin: .flag) }
        // A crash here: the intent is still on disk.
        try s.withLock(key, app: "Processor") { l in
            #expect(try l.state().pending == intent)
            #expect(throws: ImproveOCRFlagStore.StoreError.pendingAction(intent.operationID)) {
                _ = try l.begin(flagged: false, origin: .acceptedClear)
            }
            // The tag never moved: reconcile records what it really is.
            let e = try #require(try l.reconcile(observedFlagged: false))
            #expect(e.origin == .reconciled && !e.flagged && e.requested == true && e.generation == intent.generation)
            #expect(try l.state().pending == nil)
            #expect(try l.reconcile(observedFlagged: false) == nil)
        }
    }

    @Test func commitTakesOnlyItsOwnIntent() throws {
        let s = try store()
        try s.withLock(key, app: "Reader") { l in
            let real = try l.begin(flagged: true, origin: .flag)
            let other = ImproveOCRFlagStore.Intent(operationID: UUID(), generation: UUID(), flagged: true, origin: .flag,
                                                   app: "Reader", date: real.date)
            #expect(throws: ImproveOCRFlagStore.StoreError.notOurIntent) { try l.commit(other, observedFlagged: true) }
            let e = try l.commit(real, observedFlagged: false)
            #expect(!e.flagged && e.requested == true)   // what was read back, not what was asked
            #expect(throws: ImproveOCRFlagStore.StoreError.noPendingAction) { try l.commit(real, observedFlagged: false) }
        }
    }

    @Test func theLockExcludesASecondHolder() throws {
        let s = try store(lockTimeout: 0.2)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let k = key
        let holder = Thread {
            try? s.withLock(k, app: "Reader") { _ in held.signal(); release.wait() }
        }
        holder.start()
        held.wait()
        #expect(throws: ImproveOCRFlagStore.StoreError.busy) { try s.withLock(k, app: "Processor") { _ in } }
        release.signal()
        // Once released, it is free again.
        var got = false
        for _ in 0..<50 where !got {
            got = (try? s.withLock(k, app: "Processor") { _ in true }) ?? false
            if !got { usleep(20_000) }
        }
        #expect(got)
    }

    @Test func keysNormaliseCompositionNotCase() {
        let composed = ImproveOCRFlagStore.FileKey(rootGUID: root, relativePath: "Caf\u{E9}/a.pdf")
        let decomposed = ImproveOCRFlagStore.FileKey(rootGUID: root, relativePath: "Cafe\u{301}/a.pdf")
        #expect(composed == decomposed && composed.digest == decomposed.digest)
        let upper = ImproveOCRFlagStore.FileKey(rootGUID: root, relativePath: "CAF\u{C9}/a.pdf")
        #expect(upper.digest != composed.digest)
        #expect(!composed.digest.contains("a.pdf") && composed.digest.count == 64)
        let otherRoot = ImproveOCRFlagStore.FileKey(rootGUID: UUID(), relativePath: "Caf\u{E9}/a.pdf")
        #expect(otherRoot.digest != composed.digest)
    }

    @Test func folderAndFilesArePrivate() throws {
        let s = try store()
        try s.withLock(key, app: "Reader") { l in _ = try l.commit(l.begin(flagged: true, origin: .flag), observedFlagged: true) }
        let dir = s.support.appendingPathComponent("Flags").appendingPathComponent(key.digest)
        func mode(_ url: URL) -> mode_t { var st = stat(); lstat(url.path, &st); return st.st_mode & 0o777 }
        #expect(mode(s.support.appendingPathComponent("Flags")) == 0o700 && mode(dir) == 0o700)
        #expect(mode(dir.appendingPathComponent("events/0000000001.json")) == 0o600)
        #expect(mode(dir.appendingPathComponent("lock")) == 0o600 && mode(dir.appendingPathComponent("key.json")) == 0o600)
    }

    @Test func aSharedFolderOthersCanReadIsRefused() throws {
        let s = try store()
        let flags = s.support.appendingPathComponent("Flags")
        try FileManager.default.createDirectory(at: flags, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(throws: ImproveOCRFlagStore.StoreError.notPrivate(flags.path)) { try s.withLock(key, app: "Reader") { _ in } }
    }

    @Test func eventsAreNumberedInOrder() throws {
        let s = try store()
        let seqs = try (0..<3).map { n in
            try s.withLock(key, app: "Reader") { l in
                try l.commit(l.begin(flagged: n % 2 == 0, origin: n % 2 == 0 ? .flag : .unflag), observedFlagged: n % 2 == 0).sequence
            }
        }
        #expect(seqs == [1, 2, 3])
        #expect(try s.withLock(key, app: "Reader") { try $0.state().flagged } == true)
    }

    // MARK: Review fixes

    @Test func everySpellingOfOneFileIsOneKey() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("flagkey-\(UUID().uuidString)", isDirectory: true)
        let root = tmp.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Box 3/Caf\u{E9}", isDirectory: true),
                                                withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Box 3/Caf\u{E9}/Letter.pdf")
        try Data("x".utf8).write(to: file)
        let k = try ImproveOCRFlagStore.FileKey(rootGUID: self.root, root: root, file: file)
        #expect(k.relativePath == "Box 3/Caf\u{E9}/Letter.pdf")
        let spellings = [
            root.path + "/Box 3//Caf\u{E9}/Letter.pdf",
            root.path + "/./Box 3/Cafe\u{301}/Letter.pdf",
            root.path + "/box 3/CAF\u{C9}/letter.PDF",   // a case-insensitive volume, as the corpus disk is
        ]
        for path in spellings {
            #expect(try ImproveOCRFlagStore.FileKey(rootGUID: self.root, root: root, file: URL(fileURLWithPath: path)) == k, "\(path)")
        }
        // /var and /private/var name the same folder.
        if root.path.hasPrefix("/var/") {
            let priv = URL(fileURLWithPath: "/private" + root.path)
            #expect(try ImproveOCRFlagStore.FileKey(rootGUID: self.root, root: priv, file: file) == k)
        }
        #expect(throws: ImproveOCRFlagStore.StoreError.notInRoot) {
            _ = try ImproveOCRFlagStore.FileKey(rootGUID: self.root, root: root.appendingPathComponent("Box 3"), file: tmp)
        }
        #expect(throws: ImproveOCRFlagStore.StoreError.notInRoot) {
            _ = try ImproveOCRFlagStore.FileKey(rootGUID: self.root, root: root, file: root.appendingPathComponent("missing.pdf"))
        }
    }

    @Test func anUnreadableIntentIsABarrierThatReconcileLifts() throws {
        let s = try store()
        let first = try s.withLock(key, app: "Reader") { l in try l.commit(l.begin(flagged: true, origin: .flag), observedFlagged: true) }
        let dir = s.support.appendingPathComponent("Flags").appendingPathComponent(key.digest)
        try Data("{\"operat".utf8).write(to: dir.appendingPathComponent("intent.json"))   // a damaged record
        try s.withLock(key, app: "Processor") { l in
            let st = try l.state()
            #expect(st.pendingUnreadable && st.isPending && st.pending == nil)
            #expect(throws: (any Error).self) { _ = try l.begin(flagged: false, origin: .acceptedClear) }
            let e = try #require(try l.reconcile(observedFlagged: true))
            #expect(e.requested == nil && e.origin == .reconciled && e.generation != first.generation)
            #expect(try !l.state().isPending)
        }
    }

    @Test func compareAndBeginRefusesAMovedGeneration() throws {
        let s = try store()
        let reviewed = try s.withLock(key, app: "Reader") { l in try l.commit(l.begin(flagged: true, origin: .flag), observedFlagged: true).generation }
        // The person flags the file again while the re-read runs.
        _ = try s.withLock(key, app: "Reader") { l in try l.commit(l.begin(flagged: true, origin: .flag), observedFlagged: true) }
        try s.withLock(key, app: "Processor") { l in
            #expect(throws: ImproveOCRFlagStore.StoreError.generationChanged) {
                _ = try l.begin(flagged: false, origin: .acceptedClear, ifGenerationIs: reviewed)
            }
            let now = try l.state().generation
            let i = try l.begin(flagged: false, origin: .acceptedClear, ifGenerationIs: now)
            #expect(try l.commit(i, observedFlagged: false).origin == .acceptedClear)
        }
        // Never recorded: nil is the generation to expect.
        let fresh = ImproveOCRFlagStore.FileKey(rootGUID: root, relativePath: "other.pdf")
        try s.withLock(fresh, app: "Processor") { l in _ = try l.begin(flagged: false, origin: .acceptedClear, ifGenerationIs: nil) }
    }

    @Test func aRetryAfterTheEventDoesNotDuplicateIt() throws {
        let s = try store()
        let dir = s.support.appendingPathComponent("Flags").appendingPathComponent(key.digest)
        try s.withLock(key, app: "Reader") { l in
            let i = try l.begin(flagged: true, origin: .flag)
            let saved = try Data(contentsOf: dir.appendingPathComponent("intent.json"))
            let e = try l.commit(i, observedFlagged: true)
            // A crash after the event and before the intent went: the intent is back.
            try saved.write(to: dir.appendingPathComponent("intent.json"))
            let again = try l.commit(i, observedFlagged: true)
            #expect(again == e)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("events").path).count == 1)
            #expect(try !l.state().isPending)
        }
    }

    @Test func aFolderInsideAnArchiveIsRefused() throws {
        let s = try store()
        try Data("{}".utf8).write(to: s.support.appendingPathComponent(RootMarker.filename))
        #expect(throws: ImproveOCRFlagStore.StoreError.unsuitableFolder("it is inside an archive")) {
            try s.withLock(key, app: "Reader") { _ in }
        }
    }

    @Test func noTemporaryIsLeftBehind() throws {
        let s = try store()
        try s.withLock(key, app: "Reader") { l in _ = try l.commit(l.begin(flagged: true, origin: .flag), observedFlagged: true) }
        let dir = s.support.appendingPathComponent("Flags").appendingPathComponent(key.digest)
        let all = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
        #expect(!all.contains { ($0 as NSString).lastPathComponent.hasPrefix(".tmp-") }, "\(all)")
    }
}
