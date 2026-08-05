import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W26.walk1 — **the first test of Reader discovery that has ever existed.**
///
/// Before this file, `grep 'ArchiveLibrary('` over `ArchiveReader/macOS/Tests` returned zero hits:
/// nothing anywhere constructed the type that decides which files the app can see. The only
/// `ArchiveLibrary` test file was `ArchiveLibraryOverrideTests`, whose eight cases all test the
/// Spotlight tag-index-lag override rather than discovery itself. That gap is precisely how a Release
/// build shipped with **no filesystem discovery at all** — the working walk was `#if DEBUG` — and on
/// 2026-08-04 a dead Spotlight index made the app report *"No Read/Unread-tagged PDFs were found in
/// this folder"* over 1,849 correctly-tagged PDFs.
///
/// What this file pins, ahead of `W26.walk2`'s swap:
///
/// 1. **Equivalence.** `CorpusWalker` returns exactly what the shipped fixture loader returns on a
///    fully readable tree — so replacing the loader with the walker cannot change which files the app
///    lists. `NavigationUITests` pins the same membership rule end to end; this pins it in a unit.
/// 2. **The one place they must NOT agree.** On a file whose tags cannot be read, the shipped loader
///    drops the file in silence; the walker reports it. That is the whole point of the wave, and
///    asserting it here is what makes walk2's swap demonstrably not cosmetic.
///
/// ⚠️ **These tests deliberately SET `-ARUITestRootPath`, and that is correct HERE and nowhere else.**
/// The key selects the DEBUG fixture loader (`ArchiveLibrary.swift:66`), which is the *baseline* this
/// file compares against. `W26.walk2`'s headline regression test — *"a fixture Spotlight has never
/// indexed must still list every tagged file"* — must do the opposite and assert the key is ABSENT,
/// or it exercises the DEBUG walker and proves nothing (plan §7a.9). Do not copy the setup below into
/// that test.
///
/// ⚠️ Tests 1 and 2 stop compiling when `W26.walk2` deletes `loadFixtureSynchronously`. That is
/// intended: they are the before-picture, and the compiler is what retires them.
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

    /// Loads `root` through the SHIPPED discovery path (the DEBUG fixture loader), synchronously.
    ///
    /// Setting the key is removed in teardown without exception: leaving it behind would point the
    /// OWNER's next real Reader launch at a deleted temp directory.
    private func loadViaShippedLibrary(_ root: URL) -> ArchiveLibrary {
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
        XCTAssertFalse(library.isGathering)
        XCTAssertEqual(library.scopeDescription, "No folder selected")
    }

    // MARK: - 1. The walker returns exactly what the shipped loader returns

    func testCorpusWalkerMatchesTheShippedLoaderOnAFullyReadableTree() throws {
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

        let library = loadViaShippedLibrary(root)
        let walk = CorpusWalker.scan(root: root)

        XCTAssertFalse(library.files.isEmpty, "the shipped loader must have produced the baseline")
        XCTAssertFalse(library.isGathering, "the fixture path settles synchronously")
        XCTAssertTrue(walk.isClean)

        let shippedPaths = library.files.map { $0.url.path }.sorted()
        let walkedPaths = walk.entries.map { $0.url.path }.sorted()
        XCTAssertEqual(walkedPaths, shippedPaths,
                       "swapping the loader for the walker must not change WHICH files the app lists")

        // …and not just the same set: the same rows. Parse the walker's raw tags exactly as the Reader
        // will (`DocumentTags.parse`) and compare every displayed facet.
        let shippedByPath = Dictionary(uniqueKeysWithValues: library.files.map { ($0.url.path, $0) })
        for entry in walk.entries {
            let row = try XCTUnwrap(shippedByPath[entry.url.path])
            let parsed = DocumentTags.parse(raw: entry.tagNames, labelNumber: entry.labelNumber)
            XCTAssertEqual(parsed, row.tags, "facets must match for \(entry.url.lastPathComponent)")
            XCTAssertEqual(entry.contentModified, row.contentModified,
                           "content mtime must come from the same key (plan §5.16)")
        }

        // The one row-field the walker vends raw rather than formatted: the caller derives the short
        // type label from this identifier, exactly as the loader does.
        let pdf = try XCTUnwrap(walk.entries.first { $0.url.lastPathComponent == "unread.pdf" })
        XCTAssertEqual(pdf.contentTypeIdentifier, "com.adobe.pdf")
        XCTAssertEqual(shippedByPath[pdf.url.path]?.fileType, "PDF")
    }

    // MARK: - 2. The one divergence, and it is the reason for the whole wave

    func testTheShippedLoaderSilentlyDropsAnUnreadableFileWhileTheWalkerReportsIt() throws {
        try XCTSkipIf(getuid() == 0, "a permission denial is meaningless when running as root")
        let root = try makeFixtureRoot()
        try makeFile("readable.pdf", tags: ["Read"], in: root)
        let sealed = try makeFile("sealed.pdf", tags: ["Unread", "Subject/Foo", "P9"], in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sealed.path)

        let library = loadViaShippedLibrary(root)
        let walk = CorpusWalker.scan(root: root)

        // The shipped behaviour, asserted so the fix is measurable rather than asserted: the file is
        // gone from the list, and NOTHING on the library says a file was skipped. `isGathering` is
        // false, so every consumer treats this as a settled, complete answer — which is how
        // `NavigationWindowView` came to state "no tagged PDFs were found" as a fact about the corpus.
        XCTAssertEqual(library.files.map { $0.url.lastPathComponent }, ["readable.pdf"])
        XCTAssertFalse(library.isGathering, "the shipped loader reports a clean settle regardless")

        // The walker's answer about the same tree: same list, plus the reason it is not authoritative.
        XCTAssertEqual(walk.entries.map { $0.url.lastPathComponent }, ["readable.pdf"])
        XCTAssertEqual(walk.unreadable.count, 1)
        XCTAssertEqual(walk.unreadable.first?.url.lastPathComponent, "sealed.pdf")
        XCTAssertFalse(walk.isClean, "one unreadable file makes an absence unactionable")
        XCTAssertFalse(walk.entries.contains { $0.url.lastPathComponent == "sealed.pdf" },
                       "and it must never appear as a row with no tags — that is the W26.deny bug")
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
