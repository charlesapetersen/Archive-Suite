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

        let store = ReaderRootStore()
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
        let store = ReaderRootStore()
        let resolver = ReaderLinkResolver(rootStore: store)
        let unknownGUID = UUID()
        let result = await resolver.resolve(rootGUID: unknownGUID, relativePath: "test.pdf")
        #expect(result == .needsRootGrant(guid: unknownGUID))
    }

    @Test("Returns notFound for missing file")
    func missingFileNotFound() async throws {
        let (root, marker) = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReaderRootStore()
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

        let store = ReaderRootStore()
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

        let store = ReaderRootStore()
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

        let store = ReaderRootStore()
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

        let store = ReaderRootStore()
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

        let store = ReaderRootStore()
        store.grantRoot(root)

        let resolver = ReaderLinkResolver(rootStore: store)
        let result = await resolver.resolve(rootGUID: marker.guid, relativePath: relPath)
        if case .resolved(let url) = result {
            #expect(url.lastPathComponent == "Doc\u{00A0}File.pdf")
        } else {
            Issue.record("Expected .resolved, got \(result)")
        }
    }
}

// MARK: - ReaderRootStore tests

@MainActor
@Suite("ReaderRootStore")
struct ReaderRootStoreTests {

    @Test("grantRoot stores and retrieves by GUID")
    func grantAndRetrieve() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-rootstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let marker = RootMarker(guid: UUID(), name: "test", kind: .reader, createdAt: Date())
        let data = try JSONEncoder().encode(marker)
        try data.write(to: tmp.appendingPathComponent(RootMarker.filename), options: .atomic)

        let store = ReaderRootStore()
        let result = store.grantRoot(tmp)
        #expect(result?.guid == marker.guid)
        #expect(store.knownRoots[marker.guid] != nil)
    }

    @Test("root(for:) returns nil for unknown GUID")
    func unknownGUID() {
        let store = ReaderRootStore()
        #expect(store.root(for: UUID()) == nil)
    }

    @Test("grantRoot returns nil for folder without marker")
    func noMarker() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveNotes-rootstore-nomarker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ReaderRootStore()
        let result = store.grantRoot(tmp)
        #expect(result == nil)
    }
}
