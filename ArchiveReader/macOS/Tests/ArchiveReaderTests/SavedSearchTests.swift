import XCTest
@testable import ArchiveReader

final class SavedSearchCodableTests: XCTestCase {
    func testFilterCodableRoundtrip() throws {
        var f = LibraryFilter()
        f.subjects = ["Cold War", "Jerry Brown"]
        f.subjectCombine = .any
        f.qualities = [3, 2]
        f.read = .unread
        f.searchText = "brown"
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(LibraryFilter.self, from: data)
        XCTAssertEqual(f, back)
    }

    func testPathPrefixCodableRoundtrip() throws {
        var f = LibraryFilter(); f.pathPrefix = "/root/Brown"
        let back = try JSONDecoder().decode(LibraryFilter.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back.pathPrefix, "/root/Brown")
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
        var f = LibraryFilter(); f.subjects = ["Cold War"]; f.qualities = [3]; f.read = .unread
        store.add(name: "Cold War Q3 Unread", search: AdvancedSearch(filter: f, fullTextQuery: "proposition 13"))
        XCTAssertEqual(store.searches.count, 1)
        let id = store.searches[0].id

        let reloaded = SavedSearchStore(defaults: d)
        XCTAssertEqual(reloaded.searches.count, 1)
        XCTAssertEqual(reloaded.searches[0].name, "Cold War Q3 Unread")
        XCTAssertEqual(reloaded.searches[0].search.rules.first?.text, "proposition 13")   // a two-character last word is not a prefix
        XCTAssertEqual(reloaded.searches[0].search.rules.first { $0.field == .quality }?.qualities, [3])

        store.delete(id)
        XCTAssertTrue(store.searches.isEmpty)
    }

    func testBlankNameIgnored() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        store.add(name: "   ", search: AdvancedSearch())
        XCTAssertTrue(store.searches.isEmpty)
    }

    func testRenamePersists() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        store.add(name: "Old", search: AdvancedSearch())
        let id = store.searches[0].id
        store.rename(id, to: "  New Name  ")
        XCTAssertEqual(store.searches[0].name, "New Name")            // trimmed
        store.rename(id, to: "   ")                                    // blank ignored
        XCTAssertEqual(store.searches[0].name, "New Name")
        XCTAssertEqual(SavedSearchStore(defaults: d).searches[0].name, "New Name")   // persisted
    }

    func testDuplicateNameOnAddIsDisambiguated() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        store.add(name: "Work", search: AdvancedSearch())
        store.add(name: "Work", search: AdvancedSearch())   // exact dup
        store.add(name: "  work  ", search: AdvancedSearch()) // case/whitespace dup
        // Collision detection is case-insensitive, but disambiguation preserves the user's typed casing.
        XCTAssertEqual(store.searches.map(\.name), ["Work", "Work 2", "work 3"])
        // Never silently dropped — every save is kept as its own entry.
        XCTAssertEqual(store.searches.count, 3)
    }

    func testRenameToDuplicateIsDisambiguatedButSelfRenameKeepsName() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        store.add(name: "A", search: AdvancedSearch())
        store.add(name: "B", search: AdvancedSearch())
        let bID = store.searches[1].id
        store.rename(bID, to: "A")                       // collides with the other entry
        XCTAssertEqual(store.searches[1].name, "A 2")
        store.rename(bID, to: "A 2")                     // renaming to its own current name → kept
        XCTAssertEqual(store.searches[1].name, "A 2")
    }

    func testMoveReordersAndPersists() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        for n in ["One", "Two", "Three"] { store.add(name: n, search: AdvancedSearch()) }
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)   // move "One" to the end
        XCTAssertEqual(store.searches.map(\.name), ["Two", "Three", "One"])
        // Reordering survives a reload from persistence.
        XCTAssertEqual(SavedSearchStore(defaults: d).searches.map(\.name), ["Two", "Three", "One"])
    }

    func testSaveApplyRoundTripReloads() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        var f = LibraryFilter()
        f.subjects = ["Economics"]; f.subjectCombine = .any; f.qualities = [2, 1]
        f.read = .read; f.searchText = "memo"; f.pathPrefix = "/root/Box 3"; f.needsAttentionOnly = true
        f.ambiguousDatesOnly = true
        let saved = AdvancedSearch(filter: f, fullTextQuery: "deficit")
        store.add(name: "Round Trip", search: saved)
        // Reload from a fresh store (persist → reload): the whole rule tree comes back as saved.
        let reloaded = SavedSearchStore(defaults: d).searches[0]
        XCTAssertEqual(reloaded.name, "Round Trip")
        XCTAssertEqual(reloaded.search, saved)
    }

    func testUpdateReplacesTheRulesInPlace() {
        let (store, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        store.add(name: "A", search: AdvancedSearch()); store.add(name: "B", search: AdvancedSearch())
        let id = store.searches[0].id
        var rule = SearchRule(field: .tags, op: .hasNone); rule.tags = ["Press"]
        store.update(id, search: AdvancedSearch(combine: .any, rules: [rule]))
        let back = SavedSearchStore(defaults: d).searches
        XCTAssertEqual(back.map(\.name), ["A", "B"])
        XCTAssertEqual(back[0].search.combine, .any)
        XCTAssertEqual(back[0].search.rules.first?.tags, ["Press"])
    }

    /// An entry this build cannot read (one saved before the rule tree) is dropped alone, not the whole list.
    func testAnUnreadableEntryIsDroppedAlone() throws {
        let (_, d, name) = makeStore(); defer { d.removePersistentDomain(forName: name) }
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SavedSearch(name: "Good", search: AdvancedSearch())))
        let old: [String: Any] = ["id": UUID().uuidString, "name": "Old", "filter": [:], "fullTextQuery": "x"]
        d.set(try JSONSerialization.data(withJSONObject: [old, good]), forKey: "savedSearches")
        XCTAssertEqual(SavedSearchStore(defaults: d).searches.map(\.name), ["Good"])
    }

    /// W40.fix-reader-date-ambiguity: a filter saved before `ambiguousDatesOnly` existed still decodes.
    func testAFilterSavedWithoutTheAmbiguousDatesKeyStillDecodes() throws {
        var old = LibraryFilter(); old.subjects = ["Cold War"]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "ambiguousDates")
        let decoded = try JSONDecoder().decode(LibraryFilter.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.subjects, ["Cold War"])
        XCTAssertFalse(decoded.ambiguousDatesOnly)
    }
}
