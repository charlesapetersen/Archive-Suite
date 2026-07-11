import XCTest
@testable import ArchiveReader

@MainActor
final class ExcludedFoldersStoreTests: XCTestCase {
    // Use a fresh store backed by an isolated UserDefaults suite per test.
    // Since ExcludedFoldersStore is a singleton, we test the path-matching logic directly
    // and verify add/remove/dedup behavior via the public API with a reset after each test.

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "ar.excludedFolders")
        ExcludedFoldersStore.shared.reload()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ar.excludedFolders")
        ExcludedFoldersStore.shared.reload()
        super.tearDown()
    }

    // MARK: - isExcludedAbsolute

    func testIsExcludedAbsolute_exactMatch() {
        let store = ExcludedFoldersStore.shared
        store.add("Unsorted")
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Unsorted", rootPath: "/Archive"))
    }

    func testIsExcludedAbsolute_descendant() {
        let store = ExcludedFoldersStore.shared
        store.add("Unsorted")
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Unsorted/file.pdf", rootPath: "/Archive"))
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Unsorted/Sub/file.pdf", rootPath: "/Archive"))
    }

    func testIsExcludedAbsolute_componentBoundary() {
        let store = ExcludedFoldersStore.shared
        store.add("Foo")
        // "FooBar" shares a prefix string but is NOT a child of "Foo" — must not match.
        XCTAssertFalse(store.isExcludedAbsolute("/Archive/FooBar/file.pdf", rootPath: "/Archive"))
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Foo/file.pdf", rootPath: "/Archive"))
    }

    func testIsExcludedAbsolute_rootWithTrailingSlash() {
        let store = ExcludedFoldersStore.shared
        store.add("Temp")
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Temp/file.pdf", rootPath: "/Archive/"))
    }

    func testIsExcludedAbsolute_noExclusions() {
        let store = ExcludedFoldersStore.shared
        XCTAssertFalse(store.isExcludedAbsolute("/Archive/Foo/file.pdf", rootPath: "/Archive"))
    }

    // MARK: - Add / remove / dedup

    func testAddDeduplicatesExact() {
        let store = ExcludedFoldersStore.shared
        store.add("Unsorted")
        store.add("Unsorted")
        XCTAssertEqual(store.excludedRelativePaths, ["Unsorted"])
    }

    func testAddCollapsesNestedToOutermost() {
        let store = ExcludedFoldersStore.shared
        store.add("Unsorted/Sub")
        store.add("Unsorted")
        // Adding the parent should remove the child.
        XCTAssertEqual(store.excludedRelativePaths, ["Unsorted"])
    }

    func testAddDescendantOfExistingIsNoOp() {
        let store = ExcludedFoldersStore.shared
        store.add("Unsorted")
        store.add("Unsorted/Sub")
        // The descendant should not be added since the parent already covers it.
        XCTAssertEqual(store.excludedRelativePaths, ["Unsorted"])
    }

    func testRemove() {
        let store = ExcludedFoldersStore.shared
        store.add("Alpha")
        store.add("Beta")
        store.remove("Alpha")
        XCTAssertEqual(store.excludedRelativePaths, ["Beta"])
    }

    // MARK: - absolutePrefixes

    func testAbsolutePrefixes() {
        let store = ExcludedFoldersStore.shared
        store.add("A")
        store.add("B/C")
        let prefixes = store.absolutePrefixes(rootPath: "/Root")
        XCTAssertEqual(Set(prefixes), Set(["/Root/A", "/Root/B/C"]))
    }
}
