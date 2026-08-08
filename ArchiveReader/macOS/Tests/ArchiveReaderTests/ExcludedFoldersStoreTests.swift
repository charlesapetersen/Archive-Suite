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
    /// back to `.shared`, or if `ExcludedFoldersStore.persist` loses its injected domain.
    ///
    /// ⚠️ The excluded path is a **UUID sentinel**, and the load-bearing assertion is that the real key
    /// does not CONTAIN it — not that the key is unchanged. The first version of this test used the
    /// literal `"Unsorted"` and a before/after comparison, and it passed against a planted mutation:
    /// XCTest runs the class alphabetically, four `add()` cases run before this one, and under the
    /// mutation they had already left `["Unsorted"]` in the real domain — so before and after matched and
    /// the guard reported clean while the owner's list was being overwritten. Order-dependent, and
    /// therefore vacuous exactly when it mattered. A value only this run could have produced cannot
    /// coincide with a leftover.
    ///
    /// It does not repair what it finds, deliberately: putting the owner's value back would itself be a
    /// write to their domain, and it would hide the breakage from the next run.
    func testAScratchStoreNeverTouchesTheRealExcludedFoldersKey() {
        let realKey = "ar.excludedFolders"
        let sentinel = "W26-fixturehang-sentinel-\(UUID().uuidString)"
        let before = UserDefaults.standard.stringArray(forKey: realKey)

        let store = scratchStore()
        store.add(sentinel)
        store.add("Beta")
        store.remove("Beta")

        XCTAssertEqual(store.excludedRelativePaths, [sentinel], "the scratch store did do the work")
        let real = UserDefaults.standard.stringArray(forKey: realKey)
        XCTAssertFalse(real?.contains(sentinel) ?? false,
                       "a value only this test could have written reached the owner's exclusion list")
        XCTAssertEqual(real, before, "and nothing else about that list changed either")
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
