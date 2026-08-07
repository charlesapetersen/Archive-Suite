// ReaderLinkResolverTests.swift — W4-S5 tests for cross-app link resolution
// Tests the resolver, router, and root store against scratch directories.

import Testing
import Foundation
@testable import ArchiveNotes
@testable import ArchiveCore

// MARK: - NotesDeepLinkRouter tests

@MainActor
@Suite("NotesDeepLinkRouter")
struct NotesDeepLinkRouterTests {

    @Test("Parses a valid archivenotes:// URL")
    func parsesValidURL() {
        let router = NotesDeepLinkRouter()
        let id = UUID()
        let url = DurableLink.notesOpen(id: id, block: 3).url
        router.handle(url)
        #expect(router.pendingOpen == NotesDeepLinkRouter.PendingOpen(id: id, block: 3))
    }

    @Test("Parses archivenotes:// URL without block fragment")
    func parsesURLWithoutBlock() {
        let router = NotesDeepLinkRouter()
        let id = UUID()
        let url = DurableLink.notesOpen(id: id, block: nil).url
        router.handle(url)
        #expect(router.pendingOpen?.id == id)
        #expect(router.pendingOpen?.block == nil)
    }

    @Test("Ignores archivereader:// URLs")
    func ignoresReaderURL() {
        let router = NotesDeepLinkRouter()
        let url = DurableLink.readerReveal(rootGUID: UUID(), relativePath: "test.pdf", page: nil).url
        router.handle(url)
        #expect(router.pendingOpen == nil)
    }

    @Test("Ignores unrelated URLs")
    func ignoresUnrelatedURL() {
        let router = NotesDeepLinkRouter()
        let url = URL(string: "https://example.com")!
        router.handle(url)
        #expect(router.pendingOpen == nil)
    }

    @Test("clearPending resets state")
    func clearPending() {
        let router = NotesDeepLinkRouter()
        let url = DurableLink.notesOpen(id: UUID(), block: nil).url
        router.handle(url)
        #expect(router.pendingOpen != nil)
        router.clearPending()
        #expect(router.pendingOpen == nil)
    }

    @Test("Second URL replaces the first pending open")
    func secondURLReplaces() {
        let router = NotesDeepLinkRouter()
        let id1 = UUID()
        let id2 = UUID()
        router.handle(DurableLink.notesOpen(id: id1, block: nil).url)
        router.handle(DurableLink.notesOpen(id: id2, block: 5).url)
        #expect(router.pendingOpen?.id == id2)
        #expect(router.pendingOpen?.block == 5)
    }
}

// MARK: - ReaderLinkResolver tests

@MainActor
@Suite("ReaderLinkResolver")
struct ReaderLinkResolverTests {

    /// Create a scratch root with a RootMarker and some files.
    private func makeScratchRoot(guid: UUID? = nil) throws -> (URL, RootMarker) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Write a marker
        let marker: RootMarker
        if let guid {
            marker = RootMarker(guid: guid, name: tmp.lastPathComponent,
                                kind: .reader, createdAt: Date())
        } else {
            marker = RootMarker(guid: UUID(), name: tmp.lastPathComponent,
                                kind: .reader, createdAt: Date())
        }
        let data = try JSONEncoder().encode(marker)
        try data.write(to: tmp.appendingPathComponent(RootMarker.filename), options: .atomic)

        return (tmp, marker)
    }

    /// A throwaway defaults domain, one per test, wiped before use.
    ///
    /// These tests called `grantRoot` against `UserDefaults.standard` — the app's REAL set of granted
    /// Reader roots — with no snapshot of any kind, unlike the three sibling suites that at least
    /// restore the key. Every run left a permanent junk entry there, keyed by a random GUID and
    /// pointing at a deleted temp directory. Injection (W26.notesabsence-fu1) is what makes that
    /// avoidable rather than merely tidied up afterwards.
    private func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "ArchiveNotesTests.ReaderLinkResolver.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    private func createFile(at root: URL, relativePath: String) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    @Test("Resolves a file that exists under a known root")
    func resolvesExistingFile() async throws {
        let (root, marker) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try createFile(at: root, relativePath: "folder/doc.pdf")

        let store = ReaderRootStore(defaults: scratchDefaults())
        store.grantRoot(root)

        let resolver = ReaderLinkResolver(rootStore: store)
        let result = await resolver.resolve(rootGUID: marker.guid, relativePath: "folder/doc.pdf")
        if case .resolved(let url) = result {
            #expect(url.lastPathComponent == "doc.pdf")
        } else {
            Issue.record("Expected .resolved, got \(result)")
        }
    }

    @Test("Returns needsRootGrant for unknown GUID")
    func unknownGUIDNeedsGrant() async {
        let store = ReaderRootStore(defaults: scratchDefaults())
        let resolver = ReaderLinkResolver(rootStore: store)
        let unknownGUID = UUID()
        let result = await resolver.resolve(rootGUID: unknownGUID, relativePath: "test.pdf")
        #expect(result == .needsRootGrant(guid: unknownGUID))
    }

    @Test("Returns notFound for missing file")
    func missingFileNotFound() async throws {
        let (root, marker) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderRootStore(defaults: scratchDefaults())
        store.grantRoot(root)

        let resolver = ReaderLinkResolver(rootStore: store)
        let result = await resolver.resolve(rootGUID: marker.guid, relativePath: "nonexistent.pdf")
        #expect(result == .notFound)
    }

    @Test("Returns renamedCandidate when basename found elsewhere")
    func renamedCandidateFound() async throws {
        let (root, marker) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // File exists at a different path than what the link says
        try createFile(at: root, relativePath: "new-folder/doc.pdf")

        let store = ReaderRootStore(defaults: scratchDefaults())
        store.grantRoot(root)

        let resolver = ReaderLinkResolver(rootStore: store)
        let result = await resolver.resolve(rootGUID: marker.guid, relativePath: "old-folder/doc.pdf")
        if case .renamedCandidate(let url) = result {
            #expect(url.lastPathComponent == "doc.pdf")
            #expect(url.path.contains("new-folder"))
        } else {
            Issue.record("Expected .renamedCandidate, got \(result)")
        }
    }

    @Test("Rejects path traversal (../../) outside root")
    func rejectsPathTraversal() async throws {
        let (root, marker) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderRootStore(defaults: scratchDefaults())
        store.grantRoot(root)

        let resolver = ReaderLinkResolver(rootStore: store)
        let result = await resolver.resolve(rootGUID: marker.guid, relativePath: "../../etc/passwd")
        #expect(result == .notFound)
    }

    @Test("grantAndResolve succeeds with correct GUID")
    func grantAndResolveSuccess() async throws {
        let guid = UUID()
        let (root, _) = try makeScratchRoot(guid: guid)
        defer { try? FileManager.default.removeItem(at: root) }

        try createFile(at: root, relativePath: "test.pdf")

        let store = ReaderRootStore(defaults: scratchDefaults())
        let resolver = ReaderLinkResolver(rootStore: store)
        let result = await resolver.grantAndResolve(url: root, rootGUID: guid, relativePath: "test.pdf")
        if case .resolved(let url) = result {
            #expect(url.lastPathComponent == "test.pdf")
        } else {
            Issue.record("Expected .resolved, got \(result)")
        }
    }

    @Test("grantAndResolve rejects wrong GUID")
    func grantAndResolveWrongGUID() async throws {
        let (root, _) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderRootStore(defaults: scratchDefaults())
        let resolver = ReaderLinkResolver(rootStore: store)
        let wrongGUID = UUID()
        let result = await resolver.grantAndResolve(url: root, rootGUID: wrongGUID, relativePath: "test.pdf")
        #expect(result == .needsRootGrant(guid: wrongGUID))
    }

    @Test("Resolves file with special characters (em-dash, NBSP, spaces)")
    func resolvesSpecialCharacters() async throws {
        let (root, marker) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let relPath = "Folder\u{2014}Name/Doc\u{00A0}File.pdf"
        try createFile(at: root, relativePath: relPath)

        let store = ReaderRootStore(defaults: scratchDefaults())
        store.grantRoot(root)

        let resolver = ReaderLinkResolver(rootStore: store)
        let result = await resolver.resolve(rootGUID: marker.guid, relativePath: relPath)
        if case .resolved(let url) = result {
            #expect(url.lastPathComponent == "Doc\u{00A0}File.pdf")
        } else {
            Issue.record("Expected .resolved, got \(result)")
        }
    }

    // MARK: - W26.notesabsence-fu1: a refused grant is SAID, and a symlinked root is not refused

    /// End to end through the resolver: the user picks a symlinked archive folder and the file in it
    /// opens. This is what makes `W26.notesabsence`'s symlink handling reachable from the UI at all —
    /// before this the grant failed inside `ReaderRootStore`, `root(for:)` answered `nil`, and the
    /// resolver went straight back to `.needsRootGrant`, i.e. asked for the same folder again.
    @Test("grantAndResolve resolves a file under a root granted as a SYMLINK")
    func grantAndResolveThroughASymlinkedRoot() async throws {
        let guid = UUID()
        let (real, _) = try makeScratchRoot(guid: guid)
        defer { try? FileManager.default.removeItem(at: real) }
        try createFile(at: real, relativePath: "folder/doc.pdf")

        let link = real.deletingLastPathComponent()
            .appendingPathComponent("ArchiveNotes-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let resolver = ReaderLinkResolver(rootStore: store)
            let result = await resolver.grantAndResolve(
                url: link, rootGUID: guid, relativePath: "folder/doc.pdf")
            if case .resolved(let url) = result {
                #expect(url.lastPathComponent == "doc.pdf")
            } else {
                Issue.record("Expected .resolved through a symlinked granted root, got \(result)")
            }
        }
    }

    /// A folder that is not an archive root used to come back `.notFound` — a claim that the archive
    /// was searched and the file is not in it, made about a folder that was never opened.
    @Test("A pick that is not an archive root is refused WITH A REASON, not reported notFound")
    func grantAndResolveRefusesANonArchiveFolder() async throws {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let resolver = ReaderLinkResolver(rootStore: store)
            let result = await resolver.grantAndResolve(
                url: plain, rootGUID: UUID(), relativePath: "doc.pdf")
            #expect(result == .grantRefused(.notAnArchiveRoot(plain)))
            #expect(result != .notFound)
            // The popover shows this string, so it has to name the folder it is about.
            #expect(ReaderRootGrantRefusal.notAnArchiveRoot(plain).message
                        .contains(plain.lastPathComponent))
        }
    }
}

/// A throwaway `UserDefaults` suite for the tests that make `ReaderRootStore` PERSIST something.
///
/// `grantRoot` writes `readerRootBookmarks`, and in `.standard` that key is the app's real set of
/// granted Reader roots — the reason the store takes its defaults by injection (W26.notesabsence-fu1).
/// The suites that predate the injection snapshot and restore the key instead; this is the same
/// guarantee without the window in which the real key holds a test's bookmark.
enum ScratchDefaults {
    /// `@MainActor` because every caller is a main-actor test and the store it configures is
    /// `@MainActor` — a nonisolated helper would be *sending* the body across an actor boundary.
    @MainActor
    static func with(_ name: String = #function,
                     _ body: (UserDefaults) async throws -> Void) async throws {
        let suite = "ArchiveNotesTests.ReaderRootStore.\(name).\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create a throwaway UserDefaults suite")
            return
        }
        try await body(defaults)
    }
}

// MARK: - ReaderRootStore tests

@MainActor
@Suite("ReaderRootStore")
struct ReaderRootStoreTests {

    private let bookmarksKey = "readerRootBookmarks"

    /// A scratch directory carrying a Reader `RootMarker`. Removed by the caller.
    private func makeMarkedRoot(_ label: String) throws -> (URL, RootMarker) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-rootstore-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = RootMarker(guid: UUID(), name: "test", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker)
            .write(to: dir.appendingPathComponent(RootMarker.filename), options: .atomic)
        return (dir, marker)
    }

    /// The two paths compared after both have been resolved the same way — the container's temp
    /// directory sits under the `/var` → `/private/var` alias, so a raw `path ==` is a coin flip
    /// about which side happens to be spelled which way.
    private func samePath(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @Test("grantRoot stores and retrieves by GUID")
    func grantAndRetrieve() async throws {
        let (tmp, marker) = try makeMarkedRoot("plain")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let result = store.grantRoot(tmp)
            #expect(result.marker?.guid == marker.guid)
            #expect(store.knownRoots[marker.guid] != nil)
            // A plain directory is adopted exactly as picked — `canonicalRoot` returns every
            // non-symlinked root byte-unchanged, which is what keeps working roots from shifting.
            #expect(store.knownRoots[marker.guid]?.path == tmp.path)
        }
    }

    @Test("root(for:) returns nil for unknown GUID")
    func unknownGUID() async throws {
        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            #expect(store.root(for: UUID()) == nil)
        }
    }

    // MARK: - W26.notesabsence-fu1

    /// The heart of the item: a folder that IS a symbolic link is granted, as its target.
    ///
    /// Pre-fix this returned a **non-nil** marker — the marker had already been read before the
    /// bookmark was attempted — while `knownRoots` stayed empty and `root(for:)` answered `nil`. So
    /// the assertions that matter are the last two, not `marker != nil`: the caller's belief that the
    /// grant worked was exactly the defect.
    @Test("A root that IS a symlink is granted, as its target")
    func symlinkedRootIsGranted() async throws {
        let (real, marker) = try makeMarkedRoot("symlink-target")
        defer { try? FileManager.default.removeItem(at: real) }
        let link = real.deletingLastPathComponent()
            .appendingPathComponent("ArchiveNotes-rootstore-link-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let grant = store.grantRoot(link)

            #expect(grant.refusal == nil)
            #expect(grant.marker?.guid == marker.guid)
            // The value a caller actually gets back — pre-fix `knownRoots` was empty here and
            // `root(for:)` answered nil while the marker above came back non-nil.
            #expect(samePath(store.root(for: marker.guid), real))
            // Stored as the TARGET, because that is the URL a security-scoped bookmark can open.
            #expect(samePath(store.knownRoots[marker.guid], real))
            #expect(store.knownRoots[marker.guid]?.path != link.path)
            // And the bookmark really was persisted, so the grant survives a relaunch.
            #expect(defaults.dictionary(forKey: bookmarksKey)?
                        .keys.contains(marker.guid.uuidString.lowercased()) == true)
        }
    }

    /// The measured premise, asserted rather than trusted: `bookmarkData(.withSecurityScope)` cannot
    /// open a symlink. If a future macOS lifts that, this fails and says the canonicalisation above is
    /// no longer load-bearing — instead of the test suite passing while nothing is being guarded.
    @Test("Premise: a security-scoped bookmark cannot be minted for a symlink, only for its target")
    func securityScopedBookmarkRefusesASymlink() throws {
        let (real, _) = try makeMarkedRoot("premise")
        defer { try? FileManager.default.removeItem(at: real) }
        let link = real.deletingLastPathComponent()
            .appendingPathComponent("ArchiveNotes-premise-link-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(throws: (any Error).self) {
            _ = try link.bookmarkData(options: .withSecurityScope,
                                      includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        // Same directory, spelled as itself: fine. So the link is the whole difference.
        #expect(throws: Never.self) {
            _ = try real.bookmarkData(options: .withSecurityScope,
                                      includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    @Test("A pick that cannot be opened is refused as unreadable — and persists nothing")
    func unreadablePickIsRefused() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-rootstore-unreadable-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let missing = base.appendingPathComponent("never-existed", isDirectory: true)
        // A DANGLING link is not an empty archive: its target may be an unmounted volume.
        let dangling = base.appendingPathComponent("dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        // `realpath` succeeds for a link to a regular FILE, so the openable-directory probe is
        // what refuses this one.
        let file = base.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: file, options: .atomic)
        let toFile = base.appendingPathComponent("to-file", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: toFile, withDestinationURL: file)

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            for pick in [missing, dangling, toFile, file] {
                // Reported as PICKED: nothing about it could be resolved, so there is no other
                // spelling to report it under.
                #expect(store.grantRoot(pick).refusal == .unreadable(pick))
            }
            #expect(store.knownRoots.isEmpty)
            #expect(defaults.dictionary(forKey: bookmarksKey) == nil,
                    "a refused grant must not persist a bookmark")
        }
    }

    @Test("grantRoot refuses a folder without a marker, and says which folder")
    func noMarker() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-rootstore-nomarker-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let result = store.grantRoot(tmp)
            #expect(result.marker == nil)
            #expect(result.refusal == .notAnArchiveRoot(tmp))
            #expect(store.knownRoots.isEmpty)
        }
    }

    /// An identity that will not decode must never read as "this folder has no identity": the repair
    /// for absence is to mint a fresh GUID, and that orphans every link already written from the root
    /// (W23.m6). `RootMarker.read` already draws that line — before this the store threw it away with
    /// `try?` and reported the same bare `nil` for both.
    @Test("A marker that will not decode is refused as an unreadable identity, not as absence")
    func malformedMarkerIsNotAbsence() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-rootstore-malformed-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("{ not json".utf8)
            .write(to: tmp.appendingPathComponent(RootMarker.filename), options: .atomic)

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            let result = store.grantRoot(tmp)
            guard case .markerUnreadable(let url, _)? = result.refusal else {
                Issue.record("expected .markerUnreadable, got \(String(describing: result.refusal))")
                return
            }
            #expect(url == tmp)
            #expect(result.refusal != .notAnArchiveRoot(tmp))
            #expect(store.knownRoots.isEmpty)
        }
    }

    /// The branch this item is NAMED for: `bookmarkData` fails for a folder that opens and carries a
    /// marker. Pre-fix it returned `.granted`-in-effect — the marker had been read before the attempt —
    /// so the caller believed a grant had happened that `knownRoots` knew nothing about.
    ///
    /// It needs the `mintBookmark` seam, and that is a finding rather than a convenience: with the
    /// canonicalisation in place, nothing reachable from a test in the app container can make minting
    /// fail (the symlink that used to is precisely what the fix removes), so without the seam a
    /// mutation putting the original bug back passes the whole suite.
    @Test("A folder that cannot be bookmarked is REFUSED — never reported as granted")
    func couldNotBookmarkIsRefused() async throws {
        let (real, marker) = try makeMarkedRoot("mint-fails")
        defer { try? FileManager.default.removeItem(at: real) }
        // Picked through a symlink, so the refusal's naming is checked on the case where the pick and
        // the target differ: the user is told about the folder THEY chose.
        let link = real.deletingLastPathComponent()
            .appendingPathComponent("ArchiveNotes-mintfail-link-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            store.mintBookmark = { _ in throw CocoaError(.fileReadNoPermission) }
            let grant = store.grantRoot(link)

            #expect(grant.marker == nil, "a grant that could not be kept is not a grant")
            guard case .couldNotBookmark(let named, _)? = grant.refusal else {
                Issue.record("expected .couldNotBookmark, got \(String(describing: grant.refusal))")
                return
            }
            #expect(named == link, "the refusal must name the folder the user picked")
            #expect(store.knownRoots.isEmpty)
            #expect(store.root(for: marker.guid) == nil)
            #expect(defaults.dictionary(forKey: bookmarksKey) == nil,
                    "nothing may be persisted for a root we could not keep access to")
        }
    }

    /// The safety guard, mirroring the Reader's: with defaults injected, nothing in a grant may reach
    /// `UserDefaults.standard` — where `readerRootBookmarks` is the app's real set of granted roots.
    ///
    /// Asserted on THIS grant's GUID key rather than on the whole dictionary: three sibling suites in
    /// this bundle still snapshot-and-restore that key around their own `.standard` writes, and they
    /// run in parallel with this test, so a whole-dictionary comparison would flake against their
    /// restore window while proving nothing extra. A GUID minted in this test can only get there one way.
    @Test("grantRoot writes ONLY the injected defaults, never the app's real bookmarks")
    func grantRootNeverTouchesStandardDefaults() async throws {
        let (tmp, marker) = try makeMarkedRoot("hermetic")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ourKey = marker.guid.uuidString.lowercased()
        #expect(UserDefaults.standard.dictionary(forKey: bookmarksKey)?.keys.contains(ourKey) != true)

        try await ScratchDefaults.with { defaults in
            let store = ReaderRootStore(defaults: defaults)
            #expect(store.grantRoot(tmp).marker?.guid == marker.guid)
            #expect(defaults.dictionary(forKey: bookmarksKey)?.keys.contains(ourKey) == true)
        }
        #expect(UserDefaults.standard.dictionary(forKey: bookmarksKey)?.keys.contains(ourKey) != true,
                "the grant's bookmark must not appear in the app's real defaults")
    }
}
