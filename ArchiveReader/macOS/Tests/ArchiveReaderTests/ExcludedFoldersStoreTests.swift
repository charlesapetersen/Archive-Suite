import XCTest
@testable import ArchiveReader

@MainActor
final class ExcludedFoldersStoreTests: XCTestCase {

    /// A fresh store backed by an isolated `UserDefaults` suite per test — which is what the comment
    /// here always CLAIMED and what the code did not do (`W26.fixturehang`'s sweep).
    ///
    /// Every case used the `.shared` singleton over `.standard`, and `setUp`/`tearDown` cleared
    /// `ar.excludedFolders` outright. So running this file **deleted the owner's real exclusion list**,
    /// and unlike the fixture-pin leak it did not need a killed host to do damage — it happened on every
    /// green run. Nothing here reads or writes the owner's domain now.
    private func scratchStore(_ testName: String = #function) -> ExcludedFoldersStore {
        ExcludedFoldersStore(defaults: fixtureDefaults(pinnedTo: nil, testName))
    }

    /// The guard on the above: a store on a throwaway suite must leave the real key exactly as it found
    /// it, including when the owner has exclusions set. Fails if `scratchStore` is ever "simplified"
    /// back to `.shared`.
    func testAScratchStoreNeverTouchesTheRealExcludedFoldersKey() {
        let realKey = "ar.excludedFolders"
        let before = UserDefaults.standard.stringArray(forKey: realKey)

        let store = scratchStore()
        store.add("Unsorted")
        store.add("Beta")
        store.remove("Beta")

        XCTAssertEqual(store.excludedRelativePaths, ["Unsorted"], "the scratch store did do the work")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: realKey), before,
                       "and none of it reached the owner's exclusion list")
    }

    // MARK: - isExcludedAbsolute

    func testIsExcludedAbsolute_exactMatch() {
        let store = scratchStore()
        store.add("Unsorted")
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Unsorted", rootPath: "/Archive"))
    }

    func testIsExcludedAbsolute_descendant() {
        let store = scratchStore()
        store.add("Unsorted")
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Unsorted/file.pdf", rootPath: "/Archive"))
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Unsorted/Sub/file.pdf", rootPath: "/Archive"))
    }

    func testIsExcludedAbsolute_componentBoundary() {
        let store = scratchStore()
        store.add("Foo")
        // "FooBar" shares a prefix string but is NOT a child of "Foo" — must not match.
        XCTAssertFalse(store.isExcludedAbsolute("/Archive/FooBar/file.pdf", rootPath: "/Archive"))
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Foo/file.pdf", rootPath: "/Archive"))
    }

    func testIsExcludedAbsolute_rootWithTrailingSlash() {
        let store = scratchStore()
        store.add("Temp")
        XCTAssertTrue(store.isExcludedAbsolute("/Archive/Temp/file.pdf", rootPath: "/Archive/"))
    }

    func testIsExcludedAbsolute_noExclusions() {
        let store = scratchStore()
        XCTAssertFalse(store.isExcludedAbsolute("/Archive/Foo/file.pdf", rootPath: "/Archive"))
    }

    // MARK: - Add / remove / dedup

    func testAddDeduplicatesExact() {
        let store = scratchStore()
        store.add("Unsorted")
        store.add("Unsorted")
        XCTAssertEqual(store.excludedRelativePaths, ["Unsorted"])
    }

    func testAddCollapsesNestedToOutermost() {
        let store = scratchStore()
        store.add("Unsorted/Sub")
        store.add("Unsorted")
        // Adding the parent should remove the child.
        XCTAssertEqual(store.excludedRelativePaths, ["Unsorted"])
    }

    func testAddDescendantOfExistingIsNoOp() {
        let store = scratchStore()
        store.add("Unsorted")
        store.add("Unsorted/Sub")
        // The descendant should not be added since the parent already covers it.
        XCTAssertEqual(store.excludedRelativePaths, ["Unsorted"])
    }

    func testRemove() {
        let store = scratchStore()
        store.add("Alpha")
        store.add("Beta")
        store.remove("Alpha")
        XCTAssertEqual(store.excludedRelativePaths, ["Beta"])
    }

    // MARK: - absolutePrefixes

    func testAbsolutePrefixes() {
        let store = scratchStore()
        store.add("A")
        store.add("B/C")
        let prefixes = store.absolutePrefixes(rootPath: "/Root")
        XCTAssertEqual(Set(prefixes), Set(["/Root/A", "/Root/B/C"]))
    }
}
