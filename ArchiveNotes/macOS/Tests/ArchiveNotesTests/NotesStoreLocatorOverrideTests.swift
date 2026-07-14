import XCTest
@testable import ArchiveNotes

/// Safety tests for the DEBUG fixture-store override (`-ANUITestStorePath`, W8-S7).
///
/// Mirrors Reader's `RootFolderStoreTests`: the override MUST set `root` in-memory only and NEVER
/// persist/read the real `notesStoreRootBookmark`. This is the file-safety guarantee (Prime
/// Directive #1 + memory `never-mutate-live-app-root`) that the harness can never shadow or
/// clobber the owner's real Notes store — the same regression the Reader test catches.
@MainActor
final class NotesStoreLocatorOverrideTests: XCTestCase {

    private let bookmarkKey = "notesStoreRootBookmark"

    /// Launching with -ANUITestStorePath sets `root` WITHOUT persisting a bookmark.
    func testAdoptTestStoreDoesNotPersistBookmark() throws {
        // Snapshot any existing bookmark so we can verify it's unchanged afterward.
        let originalBookmark = UserDefaults.standard.data(forKey: bookmarkKey)

        // Inject the launch argument the same way XCUITest would (argument domain).
        let fixturePath = NSTemporaryDirectory() + "NotesStoreLocatorTest-fixture"
        try FileManager.default.createDirectory(atPath: fixturePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: fixturePath) }

        UserDefaults.standard.set(fixturePath, forKey: "ANUITestStorePath")
        defer { UserDefaults.standard.removeObject(forKey: "ANUITestStorePath") }

        let store = RootFolderStore()

        // root should point at the fixture (standardized — trailing slashes/symlinks normalized).
        XCTAssertEqual(store.root?.standardizedFileURL.path,
                       URL(fileURLWithPath: fixturePath, isDirectory: true).standardizedFileURL.path,
                       "root should point at the injected fixture store")

        // The real bookmark key must be byte-for-byte unchanged.
        let afterBookmark = UserDefaults.standard.data(forKey: bookmarkKey)
        XCTAssertEqual(originalBookmark, afterBookmark,
                       "adoptTestStore must NEVER write notesStoreRootBookmark")
    }

    /// An empty override path is ignored (guards the `!path.isEmpty` check): the override code
    /// path is not taken and `root` is not forced to the empty string.
    func testEmptyOverridePathIsIgnored() {
        UserDefaults.standard.set("", forKey: "ANUITestStorePath")
        defer { UserDefaults.standard.removeObject(forKey: "ANUITestStorePath") }

        let store = RootFolderStore()
        XCTAssertNotEqual(store.root?.path, "", "an empty -ANUITestStorePath must not be adopted")
    }
}
