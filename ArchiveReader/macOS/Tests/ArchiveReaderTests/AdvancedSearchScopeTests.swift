import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.reader-advanced-search: an Advanced Search as the list's base scope — run unsaved, narrowed by the filter
/// bar, saved as a smart folder, edited, counted and deleted — over a scratch fixture with a real content index.
@MainActor
final class AdvancedSearchScopeTests: XCTestCase {
    func testAdvancedSearchScopesTheListLikeASmartFolder() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdvancedSearchScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture: [(name: String, tags: [String], body: String)] = [
            ("a.pdf", ["Unread", "Press"], "a balanced budget"),
            ("b.pdf", ["Read", "Treasury"], "a draft budget"),
            ("c.pdf", ["Unread"], "taxes"),
            ("d.pdf", ["Read", "Press"], "nothing here"),
        ]
        for f in fixture {
            let url = scratch.appendingPathComponent(f.name)
            try Data("scratch fixture".utf8).write(to: url)
            try (url as NSURL).setResourceValue(f.tags, forKey: .tagNamesKey)
        }
        let bodies = Dictionary(uniqueKeysWithValues: fixture.map { ($0.name, $0.body) })
        let indexer = ContentIndexer(
            url: scratch.appendingPathComponent("content.sqlite3"),
            extractPDFForTesting: { url in
                let body = bodies[url.lastPathComponent] ?? ""
                return ExtractedContent(fullBody: body, strippedBody: body, classification: nil, pageCount: 2)
            }
        )
        let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: scratch), indexer: indexer)
        XCTAssertEqual(model.library.files.count, 4, "precondition: the fixture root supplies four rows")
        let indexDeadline = Date().addingTimeInterval(10)
        while Date() < indexDeadline, indexer.completedPassesForTesting == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        func shown() -> [String] { model.displayed.map(\.name).sorted() }
        func waitFor(_ want: [String], _ message: String) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, shown() != want { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(shown(), want, message)
        }
        model.clearUserFilters()
        try await waitFor(["a.pdf", "b.pdf", "c.pdf", "d.pdf"], "precondition: nothing filtered")

        // OCR text has "budget", and no text has "draft".
        var budget = SearchRule(field: .ocrText); budget.text = "budget"
        var noDraft = SearchRule(field: .text, op: .noWords); noDraft.text = "draft"
        let search = AdvancedSearch(combine: .all, rules: [budget, noDraft, SearchRule(field: .date)])
        model.runAdvancedSearch(search)
        try await waitFor(["a.pdf"], "the text rules, answered by the index")
        XCTAssertFalse(model.scopeIsSaved)
        XCTAssertEqual(model.activeFilterChips.first?.facet, .smartFolder)

        // The filter bar narrows within it, and Clear goes back to it.
        model.filter.read = .read
        model.recompute()
        XCTAssertEqual(shown(), [])
        model.clearUserFilters()
        XCTAssertEqual(shown(), ["a.pdf"])

        // Saved with a filter-bar narrowing, then opened: the same rows.
        model.filter.subjects = ["press"]
        model.recompute()
        model.saveCurrentSearch(name: "Budget")
        let saved = try XCTUnwrap(model.savedSearches.searches.first { $0.name == "Budget" })
        XCTAssertEqual(saved.search.rules.last?.field, .tags)
        model.applyScope(saved)
        XCTAssertTrue(model.scopeIsSaved)
        try await waitFor(["a.pdf"], "the saved smart folder shows what was saved")

        // Edit Smart Folder: any of — has none of Press, or is unread.
        var noPress = SearchRule(field: .tags, op: .hasNone); noPress.tags = ["Press"]
        var unread = SearchRule(field: .readState); unread.read = .unread
        model.updateSmartFolder(saved.id, search: AdvancedSearch(combine: .any, rules: [noPress, unread]))
        XCTAssertEqual(shown(), ["a.pdf", "b.pdf", "c.pdf"], "the open folder shows its new rules at once")
        let countDeadline = Date().addingTimeInterval(5)
        while Date() < countDeadline, model.smartFolderCounts[saved.id] != 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.smartFolderCounts[saved.id], 3, "a folder with no text rule is counted")

        model.savedSearches.delete(saved.id)
        try await waitFor(["a.pdf", "b.pdf", "c.pdf", "d.pdf"], "deleting the open folder leaves it")
        XCTAssertNil(model.scope)

        // An Advanced Search with nothing filled in leaves the scope rather than showing a chip for nothing.
        model.runAdvancedSearch(.starter)
        XCTAssertNil(model.scope)
        await indexer.closeForTesting()
    }
}
