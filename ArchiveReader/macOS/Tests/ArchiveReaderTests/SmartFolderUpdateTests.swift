import XCTest
import ArchiveCore
import AppKit
@testable import ArchiveReader

/// W40.reader-smart-folder-update: Advanced Search opened inside a smart folder remembers it and saves changed
/// rules back to it; the filter bar's Save to "<name>" folds its filters into the folder. Scratch fixture only.
@MainActor
final class SmartFolderUpdateTests: XCTestCase {
    func testChangedRulesSaveBackToTheSmartFolderTheyCameFrom() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartFolderUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for (name, tags) in [("a.pdf", ["Unread", "Press"]), ("b.pdf", ["Read", "Press"]), ("c.pdf", ["Unread"])] {
            let url = scratch.appendingPathComponent(name)
            try Data("scratch fixture".utf8).write(to: url)
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: scratch))
        model.clearUserFilters()
        func shown() -> [String] { model.displayed.map(\.name).sorted() }
        XCTAssertEqual(shown(), ["a.pdf", "b.pdf", "c.pdf"], "precondition: nothing filtered")

        // Outside a smart folder there is nothing to save back to.
        model.openAdvancedSearch()
        XCTAssertNil(model.advancedSearchRequest?.origin)
        XCTAssertFalse(model.canSaveFiltersToScope)

        var press = SearchRule(field: .tags); press.tags = ["Press"]
        // A folder rule outside the root: the list leaves it out, but saving back must keep it.
        var elsewhere = SearchRule(field: .folder); elsewhere.text = "/Volumes/Elsewhere/Box 1"
        var anyGroup = SearchRule(field: .group); anyGroup.combine = .any; anyGroup.children = [press, elsewhere]
        let id = try XCTUnwrap(model.savedSearches.add(name: "Press", search: AdvancedSearch(combine: .all, rules: [anyGroup])))
        model.applyScope(try XCTUnwrap(model.savedSearches.searches.first { $0.id == id }))
        XCTAssertEqual(shown(), ["a.pdf", "b.pdf"])

        // The form opened inside it starts from its saved rules and remembers it.
        model.openAdvancedSearch()
        let request = try XCTUnwrap(model.advancedSearchRequest)
        XCTAssertNil(request.editing, "a new search, so Search still runs without saving")
        XCTAssertEqual(request.origin?.id, id)
        XCTAssertEqual(request.search, AdvancedSearch(combine: .all, rules: [anyGroup]),
                       "the folder's rules as saved, the out-of-root folder rule included")

        // Change a rule and save it back: the folder's rules are replaced, and it shows them.
        var unread = SearchRule(field: .readState); unread.read = .unread
        request.draft.search.rules.append(unread)
        model.saveToSmartFolder(id, search: request.search)
        let updated = try XCTUnwrap(model.savedSearches.searches.first { $0.id == id })
        XCTAssertEqual(updated.search, AdvancedSearch(combine: .all, rules: [anyGroup, unread]))
        XCTAssertEqual(updated.name, "Press", "the name and place stay")
        XCTAssertEqual(model.savedSearches.searches.count, 1, "no second folder")
        XCTAssertTrue(model.scopeIsSaved)
        XCTAssertEqual(model.scope?.id, id)
        XCTAssertEqual(shown(), ["a.pdf"])

        // The filter bar on top of it: Save to folds the filters into the folder and clears them.
        XCTAssertFalse(model.canSaveFiltersToScope, "no filters, nothing to save")
        model.filter.searchText = "a"
        model.recompute()
        XCTAssertTrue(model.canSaveFiltersToScope)
        model.saveFiltersToScope()
        let folded = try XCTUnwrap(model.savedSearches.searches.first { $0.id == id })
        XCTAssertEqual(folded.search.rules.count, 3, "the saved rules AND the name filter")
        XCTAssertEqual(Array(folded.search.rules.prefix(2)), [anyGroup, unread])
        XCTAssertEqual(model.filter.searchText, "", "the filters are the folder's own now")
        XCTAssertFalse(model.canSaveFiltersToScope)
        XCTAssertEqual(shown(), ["a.pdf"])

        // An unsaved Advanced Search is not a folder to save to.
        model.runAdvancedSearch(AdvancedSearch(combine: .all, rules: [press]))
        model.openAdvancedSearch()
        XCTAssertNil(model.advancedSearchRequest?.origin)
        // Edit Smart Folder… is still there, and carries no second target.
        model.editSmartFolder(folded)
        XCTAssertEqual(model.advancedSearchRequest?.editing?.id, id)
        XCTAssertNil(model.advancedSearchRequest?.origin)

        // A folder deleted while the form is open is not recreated.
        model.savedSearches.delete(id)
        model.saveToSmartFolder(id, search: AdvancedSearch(combine: .all, rules: [press]))
        XCTAssertTrue(model.savedSearches.searches.isEmpty)
    }
}
