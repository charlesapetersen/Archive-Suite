import XCTest
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class DeepLinkTests: XCTestCase {

    // MARK: - DeepLinkRouter

    func testRouterIgnoresNonReaderScheme() {
        let router = DeepLinkRouter()
        // No nav wired — just verify no crash on a non-reader URL.
        let url = URL(string: "https://example.com")!
        router.handle(url)
    }

    func testRouterIgnoresNotesScheme() {
        let router = DeepLinkRouter()
        let url = URL(string: "archivenotes://open?id=\(UUID().uuidString.lowercased())")!
        router.handle(url)
    }

    func testRouterParsesReaderRevealURL() {
        let guid = UUID()
        let rel = "Box 1/00001 IMG — Brown.pdf"
        let link = DurableLink.readerReveal(rootGUID: guid, relativePath: rel, page: 2)
        let parsed = DurableLink(url: link.url)
        XCTAssertEqual(parsed, link, "DurableLink should round-trip through URL")
    }

    // MARK: - RootFolderStore rootMarker

    func testRootMarkerLoadedFromTestRoot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepLinkTests-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a marker file.
        let marker = RootMarker(guid: UUID(), name: "test", kind: .reader, createdAt: Date())
        let data = try JSONEncoder().encode(marker)
        try data.write(to: dir.appendingPathComponent(RootMarker.filename))

        // Use the test-root path.
        UserDefaults.standard.set(dir.path, forKey: "ARUITestRootPath")
        defer { UserDefaults.standard.removeObject(forKey: "ARUITestRootPath") }

        let store = RootFolderStore()
        XCTAssertEqual(store.root?.path, dir.path)
        XCTAssertEqual(store.rootMarker?.guid, marker.guid,
                       "adoptTestRoot should read (not create) the marker")
    }

    func testRootMarkerNilWhenNoMarkerFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepLinkTests-nomarker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        UserDefaults.standard.set(dir.path, forKey: "ARUITestRootPath")
        defer { UserDefaults.standard.removeObject(forKey: "ARUITestRootPath") }

        let store = RootFolderStore()
        XCTAssertEqual(store.root?.path, dir.path)
        XCTAssertNil(store.rootMarker, "No marker file → rootMarker should be nil")
    }

    // MARK: - NavigationModel.revealAndSelect

    func testRevealAndSelectNoRoot() {
        let model = NavigationModel()
        // No root set — should set a status message, not crash.
        model.revealAndSelect(rootGUID: UUID(), relativePath: "test.pdf", page: nil)
        XCTAssertTrue(model.statusMessage.contains("No archive folder"),
                      "Should warn about missing archive folder")
    }

    func testRevealAndSelectGuidMismatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepLinkTests-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a marker with a known GUID.
        let knownGUID = UUID()
        let marker = RootMarker(guid: knownGUID, name: "test", kind: .reader, createdAt: Date())
        let data = try JSONEncoder().encode(marker)
        try data.write(to: dir.appendingPathComponent(RootMarker.filename))

        UserDefaults.standard.set(dir.path, forKey: "ARUITestRootPath")
        defer { UserDefaults.standard.removeObject(forKey: "ARUITestRootPath") }

        let model = NavigationModel()
        XCTAssertEqual(model.rootStore.rootMarker?.guid, knownGUID)

        // Try to reveal with a different GUID.
        let otherGUID = UUID()
        model.revealAndSelect(rootGUID: otherGUID, relativePath: "test.pdf", page: nil)
        XCTAssertTrue(model.statusMessage.contains("different archive"),
                      "Should warn about GUID mismatch")
        XCTAssertTrue(model.selection.isEmpty, "Selection should be unchanged on mismatch")
    }

    func testRevealAndSelectGuidMatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepLinkTests-match-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let knownGUID = UUID()
        let marker = RootMarker(guid: knownGUID, name: "test", kind: .reader, createdAt: Date())
        let data = try JSONEncoder().encode(marker)
        try data.write(to: dir.appendingPathComponent(RootMarker.filename))

        UserDefaults.standard.set(dir.path, forKey: "ARUITestRootPath")
        defer { UserDefaults.standard.removeObject(forKey: "ARUITestRootPath") }

        let model = NavigationModel()
        // With the right GUID but no library files, the reveal is deferred (pendingReveal set).
        // The status message should NOT be the mismatch message.
        model.revealAndSelect(rootGUID: knownGUID, relativePath: "sub/test.pdf", page: nil)
        XCTAssertFalse(model.statusMessage.contains("different archive"),
                       "GUID matches — no mismatch warning")
    }

    func testDegradedDiscoveryNeverCountsAsDocumentNotFound() throws {
        try XCTSkipIf(getuid() == 0, "a permission denial is meaningless when running as root")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepLinkTests-degraded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = RootMarker(guid: UUID(), name: "test", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker).write(to: dir.appendingPathComponent(RootMarker.filename))

        UserDefaults.standard.set(dir.path, forKey: "ARUITestRootPath")
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
            UserDefaults.standard.removeObject(forKey: "ARUITestRootPath")
        }

        let model = NavigationModel()
        XCTAssertTrue(model.library.phase.isSettled, "precondition: the initial fixture pass is clean")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        model.rescan()
        XCTAssertNotNil(model.library.phase.failure, "precondition: the rescan could not look")

        model.revealAndSelect(rootGUID: marker.guid, relativePath: "missing.pdf", page: nil)
        model.applyPendingRevealIfPossible()
        model.applyPendingRevealIfPossible()

        XCTAssertFalse(model.statusMessage.contains("Document not found"),
                       "three degraded observations are still zero authoritative misses")
    }
}
