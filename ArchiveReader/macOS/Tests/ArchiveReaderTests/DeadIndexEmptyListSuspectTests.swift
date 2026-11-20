import XCTest
@testable import ArchiveReader

/// S-003 (`verification/SUSPECTS.md`, W49.reader-s003-reproduce): with the content index unopenable, an OCR query
/// empties the list and the window draws the generic "No matches" overlay, while only the status bar says the
/// index is unavailable. `W23.m9` promised a dead index is never answered as "no matches".
///
/// The model state the window reads is checked here: `LibraryEmptyState.forPhase` picks the overlay
/// (`NavigationWindowView`, the `.filteredOut` case draws "No matches" with `emptyListExplanation`), and
/// `indexFailure` drives the amber status line. Reproduced 2026-11-20: the check that the overlay is not
/// "No matches" is a known issue, so the run stays green while the defect is there and fails once it is gone, when
/// the fix removes the `XCTExpectFailure`. Phase rule 5a(4): a second session on another model checks the
/// reproduction before a fix item is filed (`W49.reader-s003-reproduce-check`). Scratch `mktemp` fixtures only.
@MainActor
final class DeadIndexEmptyListSuspectTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeadIndexEmptyListSuspectTests-root-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in ["Smith letter.pdf", "Jones memo.pdf"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        }
        return root
    }

    /// 1 KiB of non-header bytes, as `ContentIndexerFailureTests` and the VM fixture's `AR_GUI_CORRUPT_INDEX` use:
    /// SQLite opens the file, then fails on the first statement.
    private func garbageIndex() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cix-s003-\(UUID().uuidString).sqlite3")
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
        }
        try Data(repeating: 0x5A, count: 1024).write(to: url)
        return url
    }

    func testS003ADeadIndexAnswersAnOCRQueryWithNoMatches() async throws {
        let root = try makeRoot()
        let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: root),
                                    indexer: ContentIndexer(url: try garbageIndex()))
        model.filter.read = .all
        model.recompute()
        XCTAssertEqual(model.displayed.count, 2, "precondition: both files are listed")

        model.fullTextQuery = "smith"
        model.runFullTextSearch()
        let deadline = Date().addingTimeInterval(10)
        while model.ftsPaths == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        await model.listPresented()

        guard case .unavailable = model.indexFailure else {
            return XCTFail("precondition: the status bar reports the dead index, got \(String(describing: model.indexFailure))")
        }
        XCTAssertEqual(model.indexFailure?.message, "Search index unavailable")
        XCTAssertEqual(model.ftsPaths, [], "the dead index answers the query with an empty set, not nil")
        XCTAssertTrue(model.displayed.isEmpty, "the list empties")

        let overlay = LibraryEmptyState.forPhase(model.library.phase, rowCount: model.library.files.count,
                                                 displayedCount: model.displayed.count)
        XCTExpectFailure("S-003: a dead index is answered with the \"No matches\" overlay (W49.reader-s003-reproduce)") {
            XCTAssertNotEqual(overlay, .filteredOut, "the overlay must not read as an answer while the index is dead")
        }
        XCTAssertEqual(overlay, .filteredOut, "today: the \"No matches\" overlay is drawn")
        XCTAssertEqual(model.emptyListCauses, [.text], "today: the OCR text query is blamed")
        XCTAssertEqual(model.emptyListExplanation, "The OCR search \u{201c}smith\u{201d} hides every file.",
                       "today: the overlay's sentence states the search found nothing")
    }
}
