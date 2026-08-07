// ReaderLinkScanTests.swift — W23.m14: the basename fallback is off-actor,
// cancellable and bounded, and never turns "I stopped looking" into "not found".
//
// The defect these guard: `ReaderLinkResolver` is `@MainActor` and its basename
// fallback used to enumerate every descendant of the granted Reader root
// synchronously, so clicking ONE broken source link froze all Notes UI for the
// length of a 100k–150k-file walk, with no way to cancel it.
//
// Scratch only: every fixture is a fresh temp tree, and the suite snapshots and
// restores `readerRootBookmarks` (the one thing `grantRoot` persists) so it
// leaves the host's defaults byte-identical. It never reads a real corpus.

import Testing
import Foundation
@testable import ArchiveNotes
@testable import ArchiveCore

// MARK: - Off-actor witness

/// Records what thread the scanner's progress callback ran on, and every tick it
/// reported. `@unchecked Sendable` + a lock: the callback fires on the scanning
/// thread by design, which is exactly what this is here to prove.
private final class ScanWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var _ticks: [Int] = []
    private var _sawMainThread = false
    private var _sawOffMainThread = false

    func record(_ count: Int) {
        lock.lock()
        _ticks.append(count)
        if Thread.isMainThread { _sawMainThread = true } else { _sawOffMainThread = true }
        lock.unlock()
    }

    var ticks: [Int] { lock.lock(); defer { lock.unlock() }; return _ticks }
    var sawMainThread: Bool { lock.lock(); defer { lock.unlock() }; return _sawMainThread }
    var sawOffMainThread: Bool { lock.lock(); defer { lock.unlock() }; return _sawOffMainThread }
}

/// Parks the scanning thread inside its first progress tick until the test says go,
/// so "cancel arrives mid-walk" is deterministic instead of a race.
private final class ScanGate: @unchecked Sendable {
    private let firstTick = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var parked = false

    /// Called ON the scanning thread.
    func parkOnFirstTick() {
        lock.lock()
        let alreadyParked = parked
        parked = true
        lock.unlock()
        guard !alreadyParked else { return }
        firstTick.signal()
        release.wait()
    }

    /// Called from the test: wait until the walk is parked, do `work`, then let it run on.
    /// Times out rather than hanging — if the walk ran on the main actor it could never
    /// park, and a stuck test is a far worse signal than a failed one.
    @discardableResult
    func afterFirstTick(timeout: TimeInterval = 15, _ work: () -> Void) -> Bool {
        let arrived = firstTick.wait(timeout: .now() + timeout) == .success
        work()
        release.signal()
        return arrived
    }
}

@MainActor
@Suite("Reader link basename search (W23.m14)", .serialized)
struct ReaderLinkScanTests {

    // MARK: - Fixtures

    /// A scratch Reader root with a marker, `fileCount` filler files spread over
    /// subdirectories, and optionally one file at `matchRelPath`.
    private func makeRoot(
        guid: UUID = UUID(),
        fillerFiles: Int = 0,
        perDirectory: Int = 100,
        matchRelPath: String? = nil
    ) throws -> (URL, UUID) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-m14-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let marker = RootMarker(guid: guid, name: root.lastPathComponent,
                                kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker)
            .write(to: root.appendingPathComponent(RootMarker.filename), options: .atomic)

        if fillerFiles > 0 {
            let fm = FileManager.default
            var made = 0
            var dirIndex = 0
            while made < fillerFiles {
                let dir = root.appendingPathComponent("d\(dirIndex)", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let batch = min(perDirectory, fillerFiles - made)
                for i in 0..<batch {
                    fm.createFile(atPath: dir.appendingPathComponent("filler-\(made + i).pdf").path,
                                  contents: nil)
                }
                made += batch
                dirIndex += 1
            }
        }

        if let matchRelPath {
            let fileURL = root.appendingPathComponent(matchRelPath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("%PDF-1.4 scratch\n".utf8).write(to: fileURL, options: .atomic)
        }

        return (root, guid)
    }

    /// Run `body` with `readerRootBookmarks` snapshotted and restored — `grantRoot`
    /// persists there, and this suite must leave the host's defaults untouched.
    private func withHermeticBookmarks(_ body: () async throws -> Void) async rethrows {
        let key = "readerRootBookmarks"
        let saved = UserDefaults.standard.dictionary(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    // MARK: - 1. The main-actor stage does not walk

    @Test("resolveExact defers the basename search instead of walking the archive")
    func exactStageNeverWalks() async throws {
        try await withHermeticBookmarks {
            let (root, guid) = try makeRoot(matchRelPath: "new-folder/doc.pdf")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = ReaderRootStore()
            store.grantRoot(root)
            let resolver = ReaderLinkResolver(rootStore: store)

            // A basename match DOES exist elsewhere — the pre-fix resolver found it
            // right here, on the main actor. The fast stage must hand it off instead.
            let fast = resolver.resolveExact(rootGUID: guid, relativePath: "old-folder/doc.pdf")
            guard case .needsBasenameSearch(let searchRoot, let basename) = fast else {
                Issue.record("expected .needsBasenameSearch, got \(fast)")
                return
            }
            #expect(basename == "doc.pdf")
            #expect(searchRoot.path == root.path)
        }
    }

    @Test("resolveExact still answers the cheap cases without a search")
    func exactStageAnswersCheapCases() async throws {
        try await withHermeticBookmarks {
            let (root, guid) = try makeRoot(matchRelPath: "folder/doc.pdf")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = ReaderRootStore()
            store.grantRoot(root)
            let resolver = ReaderLinkResolver(rootStore: store)

            // Exact hit.
            let hit = resolver.resolveExact(rootGUID: guid, relativePath: "folder/doc.pdf")
            guard case .decided(.resolved(let url)) = hit else {
                Issue.record("expected .decided(.resolved), got \(hit)")
                return
            }
            #expect(url.lastPathComponent == "doc.pdf")

            // Traversal is refused before any search is considered.
            #expect(resolver.resolveExact(rootGUID: guid, relativePath: "../../etc/passwd")
                    == .decided(.notFound))

            // An unknown root asks for a grant; it never searches.
            let unknown = UUID()
            #expect(resolver.resolveExact(rootGUID: unknown, relativePath: "doc.pdf")
                    == .decided(.needsRootGrant(guid: unknown)))
        }
    }

    // MARK: - 2. The walk runs off the main thread

    @Test("The basename walk executes off the main thread, even when started from it")
    func walkRunsOffTheMainThread() async throws {
        let (root, _) = try makeRoot(matchRelPath: "somewhere/target.pdf")
        defer { try? FileManager.default.removeItem(at: root) }

        let witness = ScanWitness()
        // Called from a @MainActor test: `scanForBasename` is `nonisolated async`, so it
        // must hop off the main actor. Its progress callback runs on the scanning thread,
        // which makes the hop directly observable.
        let scan = await ReaderLinkResolver.scanForBasename(
            "target.pdf", under: root, onProgress: { witness.record($0) }
        )

        #expect(scan.match?.lastPathComponent == "target.pdf")
        #expect(!witness.ticks.isEmpty, "the scanner reported no progress at all")
        #expect(witness.sawOffMainThread, "the walk ran on the main thread — the UI would freeze")
        #expect(!witness.sawMainThread)
    }

    // MARK: - 3. A search that did not finish is never reported as absence

    @Test("Hitting the scan bound reports searchIncomplete, never notFound")
    func boundReportsIncompleteNotAbsence() async throws {
        try await withHermeticBookmarks {
            let (root, guid) = try makeRoot(fillerFiles: 20, perDirectory: 5)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = ReaderRootStore()
            store.grantRoot(root)

            // No file named `ghost.pdf` exists anywhere, so the ONLY difference between
            // these two answers is whether the search was allowed to finish.
            let bounded = ReaderLinkResolver(rootStore: store, scanLimit: 5)
            let boundedResult = await bounded.resolve(rootGUID: guid, relativePath: "a/ghost.pdf")
            #expect(boundedResult == .searchIncomplete(scanned: 5))

            let unbounded = ReaderLinkResolver(rootStore: store)
            let fullResult = await unbounded.resolve(rootGUID: guid, relativePath: "a/ghost.pdf")
            #expect(fullResult == .notFound, "a completed search over a tiny tree must say notFound")
        }
    }

    @Test("A cancelled search reports searchIncomplete, never notFound")
    func cancellationReportsIncompleteNotAbsence() async throws {
        try await withHermeticBookmarks {
            let (root, guid) = try makeRoot(fillerFiles: 8)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = ReaderRootStore()
            store.grantRoot(root)
            let resolver = ReaderLinkResolver(rootStore: store)

            // The task waits until it can SEE its own cancellation before resolving, so
            // "the search ran cancelled" is deterministic rather than a race.
            let task = Task.detached { () -> LinkResolution in
                var spins = 0
                while !Task.isCancelled && spins < 1_000_000 {
                    await Task.yield()
                    spins += 1
                }
                return await resolver.resolve(rootGUID: guid, relativePath: "a/ghost.pdf")
            }
            task.cancel()

            let result = await task.value
            guard case .searchIncomplete = result else {
                Issue.record("a cancelled search must not claim absence, got \(result)")
                return
            }
        }
    }

    @Test("Cancellation lands mid-walk — the scan stops early, it does not run to the end")
    func cancellationStopsTheWalkEarly() async throws {
        // Big enough that the first progress tick (every 2048 entries) leaves plenty of
        // tree unwalked, so "stopped early" is measurable rather than incidental.
        let (root, _) = try makeRoot(fillerFiles: 6_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let witness = ScanWitness()
        let gate = ScanGate()
        // Detached: this test blocks the main thread on the gate while it waits for the
        // walk to park, so the walk must not need the main actor in order to start.
        // (That the walk hops off the main actor unprompted is `walkRunsOffTheMainThread`.)
        let task = Task.detached {
            await ReaderLinkResolver.scanForBasename(
                "ghost.pdf", under: root,
                onProgress: { count in
                    witness.record(count)
                    gate.parkOnFirstTick()
                }
            )
        }
        // The walk is parked inside its first tick; cancel while it is held there.
        let parked = gate.afterFirstTick { task.cancel() }
        #expect(parked, "the walk never reported progress — did it run on the main actor?")

        let scan = await task.value
        #expect(scan.stop == .cancelled)
        #expect(scan.match == nil)
        #expect(scan.scanned < 6_000, "the walk kept going after cancellation (\(scan.scanned) entries)")
        #expect(witness.sawOffMainThread)
    }

    @Test("A root that cannot be enumerated is not reported as a completed search")
    func unreadableRootIsNotAbsence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-m14-notadir-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: root, options: .atomic)
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = await ReaderLinkResolver.scanForBasename("ghost.pdf", under: root)
        #expect(scan.match == nil)
        #expect(scan.stop != .exhausted, "a root that could not be walked must not claim absence")
    }

    // MARK: - 4. The fallback still does its job

    @Test("The off-actor search still finds a file moved within the root")
    func searchStillFindsRenamedCandidate() async throws {
        try await withHermeticBookmarks {
            let (root, guid) = try makeRoot(fillerFiles: 300, matchRelPath: "new/place/doc.pdf")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = ReaderRootStore()
            store.grantRoot(root)
            let resolver = ReaderLinkResolver(rootStore: store)

            let result = await resolver.resolve(rootGUID: guid, relativePath: "old/place/doc.pdf")
            guard case .renamedCandidate(let url) = result else {
                Issue.record("expected .renamedCandidate, got \(result)")
                return
            }
            #expect(url.lastPathComponent == "doc.pdf")
            #expect(url.path.hasPrefix(root.path + "/"))
        }
    }

    @Test("Progress is reported to the caller on the main actor")
    func progressReachesTheMainActor() async throws {
        try await withHermeticBookmarks {
            let (root, guid) = try makeRoot(matchRelPath: "deep/inside/doc.pdf")
            defer { try? FileManager.default.removeItem(at: root) }

            let store = ReaderRootStore()
            store.grantRoot(root)
            let resolver = ReaderLinkResolver(rootStore: store)

            let model = PreviewSearchModel()
            let search = model.beginSearch()
            let result = await resolver.resolve(
                rootGUID: guid, relativePath: "gone/doc.pdf",
                progress: { count in model.advance(to: count, generation: search) }
            )
            guard case .renamedCandidate = result else {
                Issue.record("expected .renamedCandidate, got \(result)")
                return
            }
            // Ticks are relayed through the main actor, so they can land after the
            // result; give the queue a bounded chance to drain before reading.
            var spins = 0
            while model.scanned == 0 && spins < 1_000 {
                await Task.yield()
                spins += 1
            }
            #expect(model.scanned > 0, "no progress ever reached the main actor")
        }
    }

    // MARK: - 5. The progress readout the popover shows

    @Test("The search readout moves forward only, and ignores a finished search's ticks")
    func progressReadoutIsMonotonicAndScoped() {
        let model = PreviewSearchModel()
        #expect(model.scanned == 0)

        let first = model.beginSearch()
        model.advance(to: 2_048, generation: first)
        model.advance(to: 6_144, generation: first)
        model.advance(to: 4_096, generation: first) // a relayed tick landing out of order
        #expect(model.scanned == 6_144)

        let second = model.beginSearch()
        #expect(model.scanned == 0)
        // A straggler from the search we just replaced must not inflate the new readout.
        model.advance(to: 9_000, generation: first)
        #expect(model.scanned == 0)
        model.advance(to: 128, generation: second)
        #expect(model.scanned == 128)
    }

    // MARK: - 6. Absence requires a walk that could READ the tree (W26.notesabsence)

    /// A root reachable only through a symlink, holding `doc.pdf` at `matchRelPath`.
    ///
    /// The link's FINAL component is the root — the shape a user creates by aliasing an archive
    /// folder onto another volume, and the one `FileManager.enumerator(at:)` refuses outright.
    /// Returns `(linkURL, realRootURL, guid)`; delete `container` to clean up both.
    private func makeSymlinkedRoot(matchRelPath: String) throws -> (link: URL, real: URL,
                                                                    guid: UUID, container: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-notesabsence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let real = container.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)

        let guid = UUID()
        let marker = RootMarker(guid: guid, name: "real", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker)
            .write(to: real.appendingPathComponent(RootMarker.filename), options: .atomic)

        let fileURL = real.appendingPathComponent(matchRelPath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("%PDF-1.4 scratch\n".utf8).write(to: fileURL, options: .atomic)

        let link = container.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return (link, real, guid, container)
    }

    /// Chmod a directory back before deleting it — a `0o000` fixture that is merely
    /// `removeItem`-ed silently survives the test run.
    private func removeFixture(_ url: URL, unlocking: [URL] = []) {
        for dir in unlocking {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: dir.path)
        }
        try? FileManager.default.removeItem(at: url)
    }

    @Test("A symlinked root is walked THROUGH the link, so the file is found rather than denied")
    func symlinkedRootIsWalkedThroughItsTarget() async throws {
        let fixture = try makeSymlinkedRoot(matchRelPath: "new/place/doc.pdf")
        defer { removeFixture(fixture.container) }

        // Pre-fix: `fileExists(atPath:isDirectory:)` follows the link and reports a directory,
        // the enumerator is non-nil and yields NOTHING, and the walk called that exhausted —
        // `.notFound` for a file sitting right there. Measured 2026-08-07.
        let scan = await ReaderLinkResolver.scanForBasename("doc.pdf", under: fixture.link)
        #expect(scan.stop != .unreadableRoot, "a readable target must not read as unreadable")
        guard let match = scan.match else {
            Issue.record("the walk did not find doc.pdf under the symlinked root (stop: \(scan.stop))")
            return
        }
        #expect(match.lastPathComponent == "doc.pdf")
        // Containment accepted it: entries come back spelled under the TARGET, and the walk's
        // canonical root has to be spelled the same way or every match is discarded.
        #expect(match.path.hasSuffix("new/place/doc.pdf"))
    }

    @Test("A root we cannot open at all is never absence — it is an incomplete search")
    func deniedRootIsNotAbsence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-notesabsence-denied-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("%PDF-1.4\n".utf8).write(to: root.appendingPathComponent("doc.pdf"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { removeFixture(root, unlocking: [root]) }

        let scan = await ReaderLinkResolver.scanForBasename("doc.pdf", under: root)
        #expect(scan.match == nil)
        #expect(scan.stop == .unreadableRoot,
                "a 0o000 root yields a live enumerator and zero entries — that is not absence")
    }

    @Test("One unreadable SUBDIRECTORY demotes the whole walk: the file may be inside it")
    func deniedSubdirectoryDemotesExhausted() async throws {
        let (root, _) = try makeRoot(fillerFiles: 20, perDirectory: 10)
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data("%PDF-1.4\n".utf8).write(to: denied.appendingPathComponent("doc.pdf"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { removeFixture(root, unlocking: [denied]) }

        let scan = await ReaderLinkResolver.scanForBasename("doc.pdf", under: root)
        #expect(scan.match == nil, "the file is behind the denial; it must not be findable")
        #expect(scan.scanned > 0, "the readable part of the tree was still walked")
        #expect(scan.stop == .unreadableRoot,
                "the enumerator skipped `denied/` in silence and the walk claimed to be exhausted")
    }

    @Test("A clean walk over a readable tree still establishes absence")
    func cleanWalkStillEstablishesAbsence() async throws {
        let (root, _) = try makeRoot(fillerFiles: 20, perDirectory: 10)
        defer { removeFixture(root) }

        // The other half of the fix: it must not make every search incomplete. Without this,
        // demoting on any error passes vacuously by never reporting `.exhausted` again.
        let scan = await ReaderLinkResolver.scanForBasename("ghost.pdf", under: root)
        #expect(scan.match == nil)
        #expect(scan.stop == .exhausted)
    }

    @Test("A root that is GONE still establishes absence — the W8-S9 computer-move contract")
    func missingRootStillEstablishesAbsence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-notesabsence-gone-\(UUID().uuidString)",
                                    isDirectory: true)
        // Never created. `canonicalRoot` returns nil here exactly as it does for a denial, so
        // this is the assertion that keeps the two apart.
        let scan = await ReaderLinkResolver.scanForBasename("doc.pdf", under: root)
        #expect(scan.match == nil)
        #expect(scan.stop == .exhausted,
                "a stale root reports the file missing (shipped W8-S9), it does not stall")
    }

    @Test("A dangling symlink root is unreachable, not empty")
    func danglingSymlinkRootIsNotAbsence() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-notesabsence-dangling-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { removeFixture(container) }
        let link = container.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: container.appendingPathComponent("nowhere"))

        // The deliberate behaviour CHANGE: `fileExists` follows the link, finds nothing and used
        // to report absence. The target may be an unmounted volume, so we cannot say that.
        let scan = await ReaderLinkResolver.scanForBasename("doc.pdf", under: link)
        #expect(scan.stop == .unreadableRoot)
    }

    @Test("End to end: a denied subtree reaches the user as searchIncomplete, not notFound")
    func deniedSubtreeSurfacesAsSearchIncomplete() async throws {
        try await withHermeticBookmarks {
            let (root, guid) = try makeRoot(fillerFiles: 20, perDirectory: 10)
            let denied = root.appendingPathComponent("denied", isDirectory: true)
            try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
            try Data("%PDF-1.4\n".utf8).write(to: denied.appendingPathComponent("doc.pdf"),
                                              options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                                  ofItemAtPath: denied.path)
            defer { removeFixture(root, unlocking: [denied]) }

            let store = ReaderRootStore()
            store.grantRoot(root)
            let resolver = ReaderLinkResolver(rootStore: store)

            let result = await resolver.resolve(rootGUID: guid, relativePath: "old/doc.pdf")
            guard case .searchIncomplete = result else {
                Issue.record("expected .searchIncomplete, got \(result)")
                return
            }
        }
    }
}
