import XCTest
import SwiftUI
@testable import ArchiveReader

/// W40.reader-back-forward (owner, 2026-11-13): Go ▸ Back and Forward, ⌘[ and ⌘], through a viewer's page jumps
/// and the navigation window's folders, as in Preview and Finder.
@MainActor
final class BackForwardTests: XCTestCase {

    // MARK: The history model

    func testBackAndForwardRetraceTheJumpsAndStopAtTheEnds() {
        var history = NavigationHistory<String>()
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack(from: "A"), "nothing behind the first place")
        history.record(leaving: "A")          // A → B
        history.record(leaving: "B")          // B → C
        XCTAssertEqual(history.goBack(from: "C"), "B")
        XCTAssertEqual(history.goBack(from: "B"), "A")
        XCTAssertNil(history.goBack(from: "A"), "Back stops at the first place")
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.goForward(from: "A"), "B")
        XCTAssertEqual(history.goForward(from: "B"), "C")
        XCTAssertNil(history.goForward(from: "C"), "Forward stops at the last place")
        XCTAssertFalse(history.canGoForward)
        XCTAssertTrue(history.canGoBack)
    }

    func testAJumpAfterGoingBackDropsTheForwardList() {
        var history = NavigationHistory<String>()
        history.record(leaving: "A")          // A → B
        history.record(leaving: "B")          // B → C
        XCTAssertEqual(history.goBack(from: "C"), "B")
        XCTAssertTrue(history.canGoForward)
        history.record(leaving: "B")          // B → D, a new branch
        XCTAssertFalse(history.canGoForward, "C is gone, as in a browser")
        XCTAssertEqual(history.goBack(from: "D"), "B")
        XCTAssertEqual(history.goBack(from: "B"), "A")
        XCTAssertEqual(history.goForward(from: "A"), "B")
        XCTAssertEqual(history.goForward(from: "B"), "D")
    }

    func testAPlaceThatIsGoneIsSkippedAndTheOldestPlacesGoFirst() {
        var history = NavigationHistory<String>(limit: 3)
        for place in ["A", "B", "C", "D"] { history.record(leaving: place) }
        XCTAssertEqual(history.back, ["B", "C", "D"], "the limit drops the oldest")
        XCTAssertEqual(history.goBack(from: "E", isAvailable: { $0 != "D" }), "C", "a place that is gone is skipped")
        XCTAssertEqual(history.forward, ["E"])
        history.removeAll { $0 == "B" }
        XCTAssertEqual(history.back, [])
        XCTAssertNil(history.goBack(from: "C", isAvailable: { _ in false }))
        XCTAssertEqual(history.forward, ["E"], "a failed step changes nothing else")
    }

    // MARK: The viewer's page jumps

    /// A five-page scan (pairs 0, 1, 2) and two one-page files.
    private func viewer() throws -> (DocumentViewerModel, [URL]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("back-forward-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for (name, pages) in [("a.pdf", 5), ("b.pdf", 1), ("c.pdf", 1)] {
            let url = dir.appendingPathComponent(name)
            XCTAssertTrue(TestPDFBuilder.write(pages: (0..<pages).map { "\(name) PAGE \($0 + 1) word" }, to: url))
            urls.append(url)
        }
        let model = DocumentViewerModel(persists: false, thumbnailer: nil)
        model.load(DocumentSelection(filePaths: urls.map(\.path)))
        return (model, urls)
    }

    func testAThumbnailOrTileJumpIsUndoneByBackAndRedoneByForward() throws {
        let (reader, urls) = try viewer()
        XCTAssertFalse(reader.canGoBack)
        reader.openThumbnail(file: 0, pair: 2)
        XCTAssertTrue(reader.canGoBack)
        reader.setShowingAllPages(true)
        reader.openTiledPage(file: 2, page: 1)
        XCTAssertEqual(reader.currentFilePath, urls[2].path)

        reader.goBack()
        XCTAssertEqual(reader.index, 0)
        XCTAssertEqual(reader.pair, 2, "Back returns to the page the tile was chosen from")
        reader.goBack()
        XCTAssertEqual(reader.index, 0)
        XCTAssertEqual(reader.pair, 0)
        XCTAssertFalse(reader.canGoBack)
        XCTAssertTrue(reader.canGoForward)
        reader.goForward()
        XCTAssertEqual(reader.pair, 2)
        reader.goForward()
        XCTAssertEqual(reader.currentFilePath, urls[2].path)
        XCTAssertFalse(reader.canGoForward)
    }

    func testSteppingAPageIsNotAJumpAndBackFromItReturnsToTheJumpsOrigin() throws {
        let (reader, _) = try viewer()
        reader.next()
        reader.next()
        XCTAssertFalse(reader.canGoBack, "stepping one page at a time is not a jump, as in Preview")
        reader.openThumbnail(file: 0, pair: 2)
        XCTAssertFalse(reader.canGoBack, "a thumbnail of the page on view goes nowhere")
        reader.openThumbnail(file: 0, pair: 0)
        reader.next()                              // pair 1, stepped
        reader.goBack()
        XCTAssertEqual(reader.pair, 2, "Back returns to where the jump started")
        reader.goForward()
        XCTAssertEqual(reader.pair, 1, "Forward returns to the page Back left, stepped to after the jump")
    }

    func testAFindHitInAnotherFileIsAJump() throws {
        let (reader, urls) = try viewer()
        reader.findQuery = "c.pdf"
        reader.performFind()
        XCTAssertEqual(reader.currentFilePath, urls[2].path, "precondition: the hit is in the third file")
        reader.goBack()
        XCTAssertEqual(reader.index, 0)
        XCTAssertEqual(reader.pair, 0)
    }

    func testANewSelectionForgetsPlacesInFilesNoLongerOpen() throws {
        let (reader, urls) = try viewer()
        reader.openThumbnail(file: 2, pair: 0)    // left a.pdf
        reader.load(DocumentSelection(filePaths: [urls[1].path, urls[2].path]))
        XCTAssertFalse(reader.canGoBack, "a.pdf is no longer open")
        reader.goBack()
        XCTAssertEqual(reader.currentFilePath, urls[1].path, "Back with nothing behind changes nothing")
    }

    // MARK: The navigation window's folders

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BackForwardTests-root-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (folder, names) in [("Smith", ["Smith letter.pdf", "Smith memo.pdf"]), ("Jones", ["Jones memo.pdf"])] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in names {
                let url = dir.appendingPathComponent(name)
                try Data("scratch PDF \(name)".utf8).write(to: url)
                try (url as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
            }
        }
        return root
    }

    private func folder(_ model: NavigationModel, _ name: String) -> String {
        let file = model.library.files.first { $0.name.hasPrefix(name) }!.path
        return (file as NSString).deletingLastPathComponent
    }

    func testBackReturnsToTheFolderWithItsSelection() throws {
        let model = fixtureNavigationModel(pinnedTo: try makeRoot())
        model.filter.read = .all
        model.recompute()
        let smith = folder(model, "Smith"), jones = folder(model, "Jones")
        XCTAssertFalse(model.canGoBack)

        model.setFolderScope(smith)
        let memo = try XCTUnwrap(model.displayed.first { $0.name == "Smith memo.pdf" })
        model.selection = [memo.id]
        model.setFolderScope(jones)
        model.selection = [model.displayed[0].id]
        model.setFolderScope(jones)
        XCTAssertEqual(model.placeHistory.back.count, 2, "choosing the folder on view again is not a move")

        model.goBack()
        XCTAssertEqual(model.filter.pathPrefix, smith)
        XCTAssertEqual(model.selection, [memo.id], "the selection is put back, as in Finder")
        model.goBack()
        XCTAssertEqual(model.currentPlace, .folder(nil), "All Files")
        XCTAssertTrue(model.selection.isEmpty, "nothing was selected there")
        XCTAssertFalse(model.canGoBack)
        model.goForward()
        model.goForward()
        XCTAssertEqual(model.filter.pathPrefix, jones)
        XCTAssertEqual(model.selection.count, 1)
        XCTAssertFalse(model.canGoForward)

        model.goBack()
        model.setFolderScope(nil)                 // a new branch
        XCTAssertFalse(model.canGoForward)
    }

    func testSmartFoldersAreInTheHistoryUntilDeleted() throws {
        let model = fixtureNavigationModel(pinnedTo: try makeRoot())
        model.filter.read = .all
        model.recompute()
        var rule = SearchRule(field: .fileName)
        rule.text = "memo"
        let id = try XCTUnwrap(model.savedSearches.add(name: "Memos", search: AdvancedSearch(combine: .all, rules: [rule])))
        let memos = try XCTUnwrap(model.savedSearches.searches.first { $0.id == id })
        model.applyScope(memos)
        XCTAssertEqual(model.displayed.count, 2)
        model.setFolderScope(folder(model, "Smith"))
        model.goBack()
        XCTAssertEqual(model.currentPlace, .smartFolder(id))
        XCTAssertEqual(model.displayed.count, 2)

        model.goForward()
        model.savedSearches.delete(id)
        XCTAssertTrue(model.canGoBack, "All Files is still behind the deleted smart folder")
        model.goBack()
        XCTAssertEqual(model.currentPlace, .folder(nil), "the deleted smart folder is skipped")
    }

    // MARK: Keys

    func testBackAndForwardTakeCommandBracketsAndTheUnreadCommandsMoveToOption() {
        XCTAssertEqual(ReaderCommand.goBack.key, CommandKey("["))
        XCTAssertEqual(ReaderCommand.goForward.key, CommandKey("]"))
        XCTAssertEqual(ReaderCommand.previousUnread.key, CommandKey("[", [.command, .option]))
        XCTAssertEqual(ReaderCommand.nextUnread.key, CommandKey("]", [.command, .option]))
        XCTAssertEqual(ReaderCommand.listPreviousUnread.key, CommandKey("[", []), "the bare keys in the list stay")
        XCTAssertEqual(ReaderCommand.listNextUnread.key, CommandKey("]", []))
    }
}
