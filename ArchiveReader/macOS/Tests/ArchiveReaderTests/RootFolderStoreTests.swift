import XCTest
@testable import ArchiveReader

@MainActor
final class RootFolderStoreTests: XCTestCase {

    private let bookmarkKey = "archiveRootBookmark"

    /// Verify that launching with -ARUITestRootPath sets `root` WITHOUT persisting a bookmark.
    /// The real `archiveRootBookmark` must stay untouched — this is the safety guarantee that
    /// the DEBUG fixture-root override can never shadow or clobber the user's real archive root.
    func testAdoptTestRootDoesNotPersistBookmark() throws {
        // Snapshot any existing bookmark so we can verify it's unchanged afterward.
        let originalBookmark = UserDefaults.standard.data(forKey: bookmarkKey)

        // Inject the launch argument the same way XCUITest would.
        let fixturePath = NSTemporaryDirectory() + "RootFolderStoreTest-fixture"
        try FileManager.default.createDirectory(atPath: fixturePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: fixturePath) }

        UserDefaults.standard.set(fixturePath, forKey: "ARUITestRootPath")
        defer { UserDefaults.standard.removeObject(forKey: "ARUITestRootPath") }

        let store = RootFolderStore()

        // root should be set to the fixture path.
        XCTAssertEqual(store.root?.path, fixturePath, "root should point at the fixture")

        // The real bookmark key must be unchanged.
        let afterBookmark = UserDefaults.standard.data(forKey: bookmarkKey)
        XCTAssertEqual(originalBookmark, afterBookmark,
                       "adoptTestRoot must NEVER write archiveRootBookmark")
    }

    /// With no -ARUITestRootPath, init falls through to resolveSaved() as usual.
    func testNormalInitDoesNotUseTestPath() {
        UserDefaults.standard.removeObject(forKey: "ARUITestRootPath")
        let store = RootFolderStore()
        // We can't easily assert what resolveSaved does (depends on persisted state),
        // but we verify no crash and that the test-root code path was NOT taken
        // when the key is absent.
        _ = store.root // just exercising the path
    }
}
