import XCTest
import ArchiveCore
@testable import ArchiveReader

/// Reader discovery — the tests `W26.walk1` created (the first that had ever existed) and
/// `W26.walk2` rewrote around the swap.
///
/// **What changed here, and why two cases are gone.** walk1's file compared `CorpusWalker` against the
/// shipped `#if DEBUG` fixture loader: one case asserted they agree on a readable tree, the other that
/// they *disagree* on an unreadable file (the loader dropped it in silence). walk2 deleted the loader,
/// so both cases had lost their baseline — the first would have compared the walker with itself, and
/// the second asserted the very behaviour this item removed (`XCTAssertFalse(library.isGathering)`,
/// *"the shipped loader reports a clean settle regardless"*). They were the before-picture and were
/// retired on schedule; `git show 003ca59` has them.
///
/// What remains and what arrives: that the library's rows are exactly the walker's answer, and — in
/// `LibraryDiscoverySwapTests` — the regression guard for the whole wave, which must run against the
/// PRODUCTION path with `-ARUITestRootPath` **absent** (plan §7a.9).
///
/// Throwaway temp fixtures only — never the corpus, and never the app's granted root.
@MainActor
final class LibraryDiscoveryTests: XCTestCase {

    // MARK: - Helpers
    //
    // Fixtures are created per test and cleaned up via `addTeardownBlock` rather than a `setUp`
    // override: `XCTestCase.setUp` is nonisolated, so overriding it on a `@MainActor` class trips
    // Swift 6 isolation checks. The house style in `DeepLinkTests` is per-test dirs anyway.

    private func fresh(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func makeFixtureRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path
        addTeardownBlock {
            restoreReadAccess(atPath: path)   // a sealed entry blocks its own removal
            try? FileManager.default.removeItem(atPath: path)
        }
        return dir
    }

    @discardableResult
    private func makeFile(_ relativePath: String, tags: [String] = [], in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try Data("BYTES-\(UUID().uuidString)".utf8).write(to: url)
        if !tags.isEmpty {
            try (fresh(url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        return url
    }

    /// Load `root` through the fixture-root path, which since `W26.walk2` runs the **same walker** as
    /// production and differs only in delivering synchronously.
    ///
    /// Removing the key in teardown is unconditional: leaving it behind would point the OWNER's next
    /// real Reader launch at a deleted temp directory.
    private func loadViaFixtureRoot(_ root: URL) -> ArchiveLibrary {
        XCTAssertNil(UserDefaults.standard.string(forKey: archiveTestRootKey),
                     "\(archiveTestRootKey) must not already be set — a leak changes what this tests")
        UserDefaults.standard.set(root.path, forKey: archiveTestRootKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: archiveTestRootKey) }
        let library = ArchiveLibrary()
        library.start(scope: root)
        return library
    }

    // MARK: - 0. The type is constructible at all

    func testArchiveLibraryStartsEmptyWithNoFolderSelected() {
        let library = ArchiveLibrary()

        XCTAssertTrue(library.files.isEmpty)
        XCTAssertEqual(library.phase, .noRoot)
        XCTAssertFalse(library.phase.isSettled, "no root is not a settled answer about any folder")
        XCTAssertEqual(library.scopeDescription, "No folder selected")
    }

    // MARK: - 1. The library's rows ARE the walker's answer

    func testTheLibrarysRowsMatchTheWalkerOnAFullyReadableTree() throws {
        let root = try makeFixtureRoot()

        try makeFile("unread.pdf", tags: ["Unread", "Subject/Rosevelt", "1936"], in: root)
        try makeFile("read.pdf", tags: ["Read", "P3", "Decade/1930s"], in: root)
        try makeFile("lowercase.pdf", tags: ["unread"], in: root)          // membership is case-insensitive
        try makeFile("untagged.pdf", in: root)
        try makeFile("subject-only.pdf", tags: ["Subject/Bar"], in: root)  // no Read/Unread → excluded
        // Membership is a TAG rule, not a type rule: a tagged non-PDF is in the library.
        try makeFile("notes.txt", tags: ["Unread"], in: root)
        try makeFile(".hidden.pdf", tags: ["Unread"], in: root)            // hidden → excluded
        try makeFile("Box 1/deep/report\u{2014}final\u{00A0}copy.pdf", tags: ["Read"], in: root)
        try makeFile("Bundle.rtfd/inside.pdf", tags: ["Unread"], in: root) // package descendant → excluded

        let library = loadViaFixtureRoot(root)
        let walk = CorpusWalker.scan(root: root)

        XCTAssertTrue(walk.isClean)
        XCTAssertTrue(library.phase.isSettled, "a clean pass over a stable root settles")

        let libraryPaths = library.files.map { $0.url.path }.sorted()
        let walkedPaths = walk.entries.map { $0.url.path }.sorted()
        XCTAssertEqual(libraryPaths, walkedPaths,
                       "the library must list exactly what the walker found — no membership of its own")

        // …and not just the same set: the same rows. Parse the walker's raw tags exactly as the Reader
        // does and compare every displayed facet.
        let rowsByPath = Dictionary(uniqueKeysWithValues: library.files.map { ($0.url.path, $0) })
        for entry in walk.entries {
            let row = try XCTUnwrap(rowsByPath[entry.url.path])
            XCTAssertEqual(DocumentTags.parse(raw: entry.tagNames, labelNumber: entry.labelNumber),
                           row.tags, "facets must match for \(entry.url.lastPathComponent)")
            XCTAssertEqual(entry.contentModified, row.contentModified,
                           "content mtime must come from the same key (plan §5.16)")
        }

        let pdf = try XCTUnwrap(walk.entries.first { $0.url.lastPathComponent == "unread.pdf" })
        XCTAssertEqual(pdf.contentTypeIdentifier, "com.adobe.pdf")
        XCTAssertEqual(rowsByPath[pdf.url.path]?.fileType, "PDF")
    }
}

/// File scope, not a `static` on the `@MainActor` class above: teardown blocks are nonisolated.
private let archiveTestRootKey = "ARUITestRootPath"

/// Restore owner access below `path` so a deliberately sealed fixture entry can be deleted.
private func restoreReadAccess(atPath path: String) {
    let fm = FileManager.default
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    guard let en = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                                 options: [], errorHandler: { _, _ in true }) else { return }
    while let u = en.nextObject() as? URL {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }
}
