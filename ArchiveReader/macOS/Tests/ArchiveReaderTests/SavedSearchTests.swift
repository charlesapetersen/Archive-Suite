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

    func testPathPrefixCodableAndBackwardCompat() throws {
        var f = LibraryFilter(); f.pathPrefix = "/root/Brown"
        let back = try JSONDecoder().decode(LibraryFilter.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back.pathPrefix, "/root/Brown")
        // A smart folder saved before pathPrefix existed must still decode (→ nil).
        let old = #"{"subjects":[],"subjectCombine":"all","priorities":[],"read":"all","searchText":""}"#
        let decoded = try JSONDecoder().decode(LibraryFilter.self, from: Data(old.utf8))
        XCTAssertNil(decoded.pathPrefix)
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

    func testRenamePersists() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        store.add(name: "Old", filter: LibraryFilter(), fullTextQuery: "")
        let id = store.searches[0].id
        store.rename(id, to: "  New Name  ")
        XCTAssertEqual(store.searches[0].name, "New Name")            // trimmed
        store.rename(id, to: "   ")                                    // blank ignored
        XCTAssertEqual(store.searches[0].name, "New Name")
        XCTAssertEqual(SavedSearchStore(defaults: d).searches[0].name, "New Name")   // persisted
    }

    func testDuplicateNameOnAddIsDisambiguated() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        store.add(name: "Work", filter: LibraryFilter(), fullTextQuery: "")
        store.add(name: "Work", filter: LibraryFilter(), fullTextQuery: "")   // exact dup
        store.add(name: "  work  ", filter: LibraryFilter(), fullTextQuery: "") // case/whitespace dup
        // Collision detection is case-insensitive, but disambiguation preserves the user's typed casing.
        XCTAssertEqual(store.searches.map(\.name), ["Work", "Work 2", "work 3"])
        // Never silently dropped — every save is kept as its own entry.
        XCTAssertEqual(store.searches.count, 3)
    }

    func testRenameToDuplicateIsDisambiguatedButSelfRenameKeepsName() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        store.add(name: "A", filter: LibraryFilter(), fullTextQuery: "")
        store.add(name: "B", filter: LibraryFilter(), fullTextQuery: "")
        let bID = store.searches[1].id
        store.rename(bID, to: "A")                       // collides with the other entry
        XCTAssertEqual(store.searches[1].name, "A 2")
        store.rename(bID, to: "A 2")                     // renaming to its own current name → kept
        XCTAssertEqual(store.searches[1].name, "A 2")
    }

    func testMoveReordersAndPersists() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        for n in ["One", "Two", "Three"] { store.add(name: n, filter: LibraryFilter(), fullTextQuery: "") }
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)   // move "One" to the end
        XCTAssertEqual(store.searches.map(\.name), ["Two", "Three", "One"])
        // Reordering survives a reload from persistence.
        XCTAssertEqual(SavedSearchStore(defaults: d).searches.map(\.name), ["Two", "Three", "One"])
    }

    func testSaveApplyRoundTripReloads() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        var f = LibraryFilter()
        f.subjects = ["Economics"]; f.subjectCombine = .any; f.priorities = [9, 8]
        f.read = .read; f.searchText = "memo"; f.pathPrefix = "/root/Box 3"; f.needsAttentionOnly = true
        store.add(name: "Round Trip", filter: f, fullTextQuery: "deficit")
        // Reload from a fresh store (persist → reload) and confirm the saved filter is intact so it can
        // be re-applied to the live filter state verbatim.
        let reloaded = SavedSearchStore(defaults: d).searches[0]
        XCTAssertEqual(reloaded.name, "Round Trip")
        XCTAssertEqual(reloaded.fullTextQuery, "deficit")
        XCTAssertEqual(reloaded.filter, f)   // whole filter round-trips (drives applySaved)
    }
}
