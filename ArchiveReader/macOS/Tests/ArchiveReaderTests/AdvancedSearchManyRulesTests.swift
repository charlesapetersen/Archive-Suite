import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-reader-advanced-many-rules (owner, 2026-11-10: rules past about seven "get added for a little bit and
/// then dropped"): twelve rules added through the form's + stay in the request's draft, which a re-presented form
/// reads, and all twelve reach the saved search and the search in effect. A count the next edit cancels returns.
@MainActor
final class AdvancedSearchManyRulesTests: XCTestCase {
    func testTwelveAddedRulesReachTheSavedSearch() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdvancedSearchMany-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["a.pdf", "b.pdf"] {
            let url = scratch.appendingPathComponent(name)
            try Data("scratch fixture".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        let indexer = ContentIndexer(
            url: scratch.appendingPathComponent("content.sqlite3"),
            extractPDFForTesting: { _ in
                ExtractedContent(fullBody: "words", strippedBody: "words", classification: nil, pageCount: 2)
            }
        )
        let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: scratch), indexer: indexer)
        model.clearUserFilters()
        model.openAdvancedSearch()
        let request = try XCTUnwrap(model.advancedSearchRequest)
        XCTAssertEqual(request.search.rules.count, 3, "precondition: the starter rows")

        // Each from the last row's +, as the owner added them.
        for k in 1...12 {
            let id = request.draft.search.rules.insertRule(after: request.draft.search.rules.last?.id)
            let i = try XCTUnwrap(request.draft.search.rules.firstIndex { $0.id == id })
            request.draft.search.rules[i].text = "w\(k)"
        }
        // One inside a group too: + on a group's row adds to that group.
        let groupID = request.draft.search.rules.insertRule(after: nil, group: true)
        let g = try XCTUnwrap(request.draft.search.rules.firstIndex { $0.id == groupID })
        request.draft.search.rules[g].children.insertRule(after: request.draft.search.rules[g].children.first?.id)
        XCTAssertEqual(request.draft.search.rules[g].children.count, 2)

        func words(_ s: AdvancedSearch) -> [String] { s.rules.map(\.text).filter { $0.hasPrefix("w") } }
        let want = (1...12).map { "w\($0)" }
        XCTAssertEqual(words(request.search), want, "all twelve, in order")
        let again = try XCTUnwrap(model.advancedSearchRequest)
        XCTAssertEqual(again.id, request.id)
        XCTAssertEqual(words(again.search), want, "a form presented again from the request has all twelve")

        // A count the next edit cancels comes back without running on.
        let cancelled = Task { await model.countMatches(request.search) }
        cancelled.cancel()
        _ = await cancelled.value

        model.saveAdvancedSearch(request.search, name: "Twelve rules")
        let saved = try XCTUnwrap(model.savedSearches.searches.first { $0.name == "Twelve rules" })
        XCTAssertEqual(words(saved.search), want, "the saved smart folder has all twelve")
        XCTAssertEqual(saved.search.rules.count, 16, "three starter rows, twelve rules and the group")

        model.editSmartFolder(saved)
        let edit = try XCTUnwrap(model.advancedSearchRequest)
        XCTAssertEqual(words(edit.search), want, "Edit Smart Folder opens on all twelve")
        edit.draft.search.rules.insertRule(after: edit.search.rules.last?.id)
        model.commitAdvancedSearch(edit)
        let updated = try XCTUnwrap(model.savedSearches.searches.first { $0.id == saved.id })
        XCTAssertEqual(updated.search.rules.count, 17, "Save keeps what the draft holds")
        model.savedSearches.delete(saved.id)
    }
}
