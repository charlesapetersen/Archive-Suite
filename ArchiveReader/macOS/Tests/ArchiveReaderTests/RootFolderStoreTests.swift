import XCTest
import ArchiveCore
@testable import ArchiveReader

@MainActor
final class RootFolderStoreTests: XCTestCase {

    private let bookmarkKey = "archiveRootBookmark"

    /// Verify that launching with -ARUITestRootPath sets `root` WITHOUT persisting a bookmark.
    /// The real `archiveRootBookmark` must stay untouched — this is the safety guarantee that
    /// the DEBUG fixture-root override can never shadow or clobber the user's real archive root.
    ///
    /// The pin goes into a throwaway suite (`fixtureDefaults`): it used to be written into `.standard`
    /// and removed in a `defer`, which a killed host never runs — `W26.fixturehang`.
    func testAdoptTestRootDoesNotPersistBookmark() throws {
        // Snapshot any existing bookmark so we can verify it's unchanged afterward.
        let originalBookmark = UserDefaults.standard.data(forKey: bookmarkKey)

        let fixturePath = NSTemporaryDirectory() + "RootFolderStoreTest-fixture"
        try FileManager.default.createDirectory(atPath: fixturePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: fixturePath) }

        // Inject the launch argument the same way XCUITest would — into this test's own domain.
        let defaults = fixtureDefaults(pinnedTo: URL(fileURLWithPath: fixturePath, isDirectory: true))
        let store = RootFolderStore(defaults: defaults)

        // root should be set to the fixture path.
        XCTAssertEqual(store.root?.path, fixturePath, "root should point at the fixture")

        // No bookmark anywhere: not in the injected domain (the assertion the fixture lane owes) and
        // not in the real one (the 2026-07-11 incident's guard).
        XCTAssertNil(defaults.data(forKey: bookmarkKey),
                     "adoptTestRoot must persist no bookmark at all, not merely a harmless one")
        XCTAssertEqual(UserDefaults.standard.data(forKey: bookmarkKey), originalBookmark,
                       "adoptTestRoot must NEVER write archiveRootBookmark")
    }

    /// With no -ARUITestRootPath, init falls through to resolveSaved() as usual.
    ///
    /// On a throwaway domain rather than `.standard`, which is a safety fix and not just tidiness: with
    /// `.standard` this test resolved the OWNER'S saved bookmark and started a security scope on their
    /// real archive root, and it reached that branch by removing a key from the owner's own defaults.
    /// An empty suite holds no bookmark, so `resolveSaved()` is exercised and finds nothing.
    func testNormalInitDoesNotUseTestPath() {
        let defaults = fixtureDefaults()   // no pin
        let store = RootFolderStore(defaults: defaults)
        XCTAssertNil(store.root, "no pin and no saved bookmark is no root — not the owner's")
        XCTAssertFalse(store.hasSavedBookmark)
    }

    // MARK: Adoption (W26.symroot-fu1)
    //
    // These exercise `setRoot`, which WRITES `archiveRootBookmark` — so every one of them gives the
    // store a throwaway `UserDefaults` suite. Nothing here may go near `.standard`: that key is the
    // owner's real archive root, and clobbering it is the 2026-07-11 incident. The
    // `testSetRootNeverTouchesTheStandardBookmarkKey` case below is the guard on that.

    /// A fresh throwaway defaults suite, removed at the end of the test.
    private func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "RootFolderStoreTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func scratchDir(_ name: String = #function) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RFS-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The heart of the item: a folder that IS a symbolic link is adopted, as its target.
    ///
    /// Before this, `bookmarkData(options: .withSecurityScope)` threw for the link (it cannot
    /// `open()` one), `setRoot` swallowed that in a `catch` that only `NSLog`ed, and the pick left the
    /// app with no root, no scan and nothing said. The assertion is on the TARGET spelling, not merely
    /// on non-nil: adopting the link spelling would put the bookmark back in the failing case.
    func testASymlinkedPickIsAdoptedAsItsTarget() throws {
        let base = try scratchDir()
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let store = RootFolderStore(defaults: scratchDefaults())
        let refusal = store.setRoot(link)

        XCTAssertNil(refusal, "a symlink to a readable directory is a perfectly good archive root")
        XCTAssertEqual(store.root?.resolvingSymlinksInPath().path, real.resolvingSymlinksInPath().path,
                       "the root must be the link's TARGET — a security-scoped bookmark cannot open a link")
        XCTAssertNotEqual(store.root?.path, link.path,
                          "adopting the link spelling is exactly what fails to bookmark")
        XCTAssertNotNil(store.discoveredPathPrefix)
    }

    /// A folder that cannot be opened is REFUSED with something sayable, rather than adopted or
    /// silently dropped. A dangling link is the interesting case: it exists to `lstat`, so a check
    /// weaker than `canonicalRoot`'s (which resolves *and* probes) would accept it.
    func testAnUnopenablePickIsRefusedWithAMessage() throws {
        let base = try scratchDir()
        let dangling = base.appendingPathComponent("dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: base.appendingPathComponent("nothing-here", isDirectory: true))
        let missing = base.appendingPathComponent("never-existed", isDirectory: true)

        for pick in [dangling, missing] {
            let store = RootFolderStore(defaults: scratchDefaults())
            let refusal = store.setRoot(pick)
            XCTAssertEqual(refusal, .unreadable(pick), "\(pick.lastPathComponent) cannot be opened")
            XCTAssertNil(store.root, "a refused pick must not leave a root behind")
            XCTAssertNil(store.discoveredPathPrefix)
            XCTAssertFalse(refusal?.message.isEmpty ?? true, "the refusal has to be sayable")
            XCTAssertTrue(refusal?.message.contains(pick.lastPathComponent) ?? false,
                          "the message names the folder the user picked")
        }
    }

    /// A refused pick must not disturb a root that is already open — the window keeps working.
    func testARefusedPickLeavesAnAlreadyOpenRootAlone() throws {
        let base = try scratchDir()
        let good = base.appendingPathComponent("good", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)

        let store = RootFolderStore(defaults: scratchDefaults())
        XCTAssertNil(store.setRoot(good))
        let adopted = store.root
        let prefix = store.discoveredPathPrefix

        XCTAssertNotNil(store.setRoot(base.appendingPathComponent("never-existed", isDirectory: true)))
        XCTAssertEqual(store.root, adopted, "the previously granted root must survive a bad pick")
        XCTAssertEqual(store.discoveredPathPrefix, prefix)
    }

    /// `discoveredPathPrefix` is the spelling the WALKER reports, and that is NOT `root.path`.
    ///
    /// The root here is reached through a **mid-path** symlink, which is the case `canonicalRoot`
    /// deliberately does not touch (its final component is a real directory) and the case
    /// `discoveredPathPrefix` exists for. Without a link in the path this test would be vacuous: the
    /// unit bundle's `NSTemporaryDirectory()` is the app CONTAINER's tmp, not `/var/folders`, so it
    /// has no aliased ancestor to expose the difference (memory `app-hosted-tests-sandboxed-tmp`).
    /// Asserted against the walker's own output rather than against a second copy of the rule.
    func testDiscoveredPathPrefixIsTheSpellingTheWalkerReports() throws {
        let base = try scratchDir()
        let real = base.appendingPathComponent("real", isDirectory: true)
        let dir = real.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link", isDirectory: true), withDestinationURL: real)
        try Data("x".utf8).write(to: dir.appendingPathComponent("doc.pdf"))

        // Spelled through the link — a real directory, so it bookmarks and adopts unchanged.
        let picked = base.appendingPathComponent("link", isDirectory: true)
            .appendingPathComponent("sub", isDirectory: true)
        let store = RootFolderStore(defaults: scratchDefaults())
        XCTAssertNil(store.setRoot(picked))
        let prefix = try XCTUnwrap(store.discoveredPathPrefix)
        XCTAssertNotEqual(prefix, try XCTUnwrap(store.root).path,
                          "if these were equal the assertion below could not fail — the fixture is wrong")

        // `scanFingerprints` rather than `scan`: it reports every readable regular file, so the
        // fixture needs no Read/Unread tag for this to be a real assertion about spelling.
        let walked = CorpusWalker.scanFingerprints(root: try XCTUnwrap(store.root)).entries
        XCTAssertFalse(walked.isEmpty, "the fixture must actually be walkable")
        for entry in walked {
            XCTAssertTrue(entry.url.path.hasPrefix(prefix + "/"),
                          "the walker reported \(entry.url.path), which is not under \(prefix)")
        }
    }

    /// The 2026-07-11 guard, extended to the adoption path: injecting defaults is the whole reason
    /// these tests may call `setRoot` at all, so prove the injection actually holds.
    func testSetRootNeverTouchesTheStandardBookmarkKey() throws {
        let before = UserDefaults.standard.data(forKey: bookmarkKey)
        let dir = try scratchDir()
        let scratch = scratchDefaults()

        let store = RootFolderStore(defaults: scratch)
        XCTAssertNil(store.setRoot(dir))

        XCTAssertNotNil(scratch.data(forKey: bookmarkKey), "the bookmark went to the injected suite")
        XCTAssertEqual(UserDefaults.standard.data(forKey: bookmarkKey), before,
                       "setRoot must never write the real archiveRootBookmark from a test")
        store.clear()
        XCTAssertNil(scratch.data(forKey: bookmarkKey))
        XCTAssertEqual(UserDefaults.standard.data(forKey: bookmarkKey), before,
                       "clear() must not reach the real key either")
    }
}
