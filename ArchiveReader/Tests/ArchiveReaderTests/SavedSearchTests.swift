import XCTest
@testable import ArchiveReader

final class SavedSearchCodableTests: XCTestCase {
    func testFilterCodableRoundtrip() throws {
        var f = LibraryFilter()
        f.subjects = ["Cold War", "Jerry Brown"]
        f.subjectCombine = .any
        f.priorities = [10, 9]
        f.read = .unread
        f.searchText = "brown"
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(LibraryFilter.self, from: data)
        XCTAssertEqual(f, back)
    }
}

@MainActor
final class SavedSearchStoreTests: XCTestCase {
    private func makeStore() -> (SavedSearchStore, UserDefaults, String) {
        let name = "ArchiveReaderTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (SavedSearchStore(defaults: d), d, name)
    }

    func testAddDeletePersist() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        var f = LibraryFilter(); f.subjects = ["Cold War"]; f.priorities = [10]; f.read = .unread
        store.add(name: "Cold War P10 Unread", filter: f, fullTextQuery: "proposition 13")
        XCTAssertEqual(store.searches.count, 1)
        let id = store.searches[0].id

        let reloaded = SavedSearchStore(defaults: d)
        XCTAssertEqual(reloaded.searches.count, 1)
        XCTAssertEqual(reloaded.searches[0].name, "Cold War P10 Unread")
        XCTAssertEqual(reloaded.searches[0].filter.priorities, [10])
        XCTAssertEqual(reloaded.searches[0].fullTextQuery, "proposition 13")

        store.delete(id)
        XCTAssertTrue(store.searches.isEmpty)
    }

    func testBlankNameIgnored() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        store.add(name: "   ", filter: LibraryFilter(), fullTextQuery: "")
        XCTAssertTrue(store.searches.isEmpty)
    }
}
