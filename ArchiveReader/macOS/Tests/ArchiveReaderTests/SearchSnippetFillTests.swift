import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-reader-fts-snippets: a hit the search left without a snippet (past its cap or its time budget)
/// gets one once its row is drawn, without another search.
@MainActor
final class SearchSnippetFillTests: XCTestCase {
    func testHitsWithoutASnippetGetOneWhenTheirRowsAreDrawn() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchSnippetFill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for i in 0..<3 {
            let url = scratch.appendingPathComponent("hit-\(i).pdf")
            try Data("scratch fixture".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        let indexer = ContentIndexer(
            url: scratch.appendingPathComponent("content.sqlite3"),
            extractPDFForTesting: { _ in
                ExtractedContent(fullBody: "a memorandum on the snippetterm budget",
                                 strippedBody: "a memorandum on the snippetterm budget",
                                 classification: nil, pageCount: 2)
            }
        )
        let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: scratch), indexer: indexer)
        let paths = model.library.files.map { $0.url.path }
        XCTAssertEqual(paths.count, 3, "precondition: the fixture root supplies three rows")
        let indexDeadline = Date().addingTimeInterval(10)
        while Date() < indexDeadline, indexer.completedPassesForTesting == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        model.ftsSnippetLimit = 0   // the search itself gives no previews, as when its budget runs out
        model.fullTextQuery = "snippetterm"
        model.runFullTextSearch()
        let searchDeadline = Date().addingTimeInterval(10)
        while Date() < searchDeadline, model.ftsPaths?.count != 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.ftsPaths, Set(paths))
        XCTAssertTrue(paths.allSatisfy { model.searchSnippet(for: $0) == nil },
                      "non-vacuity: no preview came with the search")

        // Each poll is what the table does when it draws (and, after a fill, redraws) the rows.
        let fillDeadline = Date().addingTimeInterval(10)
        while Date() < fillDeadline, !paths.allSatisfy({ model.searchSnippet(for: $0) != nil }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for path in paths {
            let segments = try XCTUnwrap(model.searchSnippet(for: path), "no preview for \(path)")
            XCTAssertEqual(segments.filter { $0.isMatch }.map { $0.text }, ["snippetterm"])
        }
        XCTAssertGreaterThan(model.snippetFillGeneration, 0, "the table is told to redraw")
        XCTAssertEqual(model.takeFilledSnippetPaths(), Set(paths), "the table reloads exactly the filled rows")
        XCTAssertTrue(model.takeFilledSnippetPaths().isEmpty)
        await indexer.closeForTesting()
    }

    /// The scanned fragment for a stop-word-only query: a window of `tokenCount` words starting a few
    /// words before the first match, with an ellipsis on each side where text was left out.
    func testScannedFragmentWindowsTheFirstMatch() {
        let the = [SearchSnippet.Term(word: "the", isPrefix: false)]
        let body = "one two three four five six seven the eight nine ten eleven twelve thirteen fourteen"
        XCTAssertEqual(SearchSnippet.fragment(in: body, terms: the, tokenCount: 6),
                       "…six seven \u{2}the\u{3} eight nine ten…")
        XCTAssertEqual(SearchSnippet.fragment(in: "The end.", terms: the),
                       "\u{2}The\u{3} end.")   // case-folded; nothing left out, so no ellipsis
        XCTAssertNil(SearchSnippet.fragment(in: "nothing to see here", terms: the))
        XCTAssertNil(SearchSnippet.fragment(in: "", terms: the))
        let prefix = [SearchSnippet.Term(word: "the", isPrefix: true)]
        XCTAssertEqual(SearchSnippet.fragment(in: "Over there, Thé.", terms: prefix),
                       "Over \u{2}there\u{3}, \u{2}Thé\u{3}.")
    }
}
