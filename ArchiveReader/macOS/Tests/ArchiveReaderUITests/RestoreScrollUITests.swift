import XCTest

/// W40.fix-reader-restore-scroll — after a quit and relaunch the list comes back at the rows the user was
/// looking at (reader-1, row 35: "it returned to the smart folder but not to the same rows").
///
/// Builds its own 80-file corpus in a scratch directory (`WarmStartUITests.makeScratchDirectory`), long
/// enough to scroll at the window's default size; the shared fixture is too short to tell a restored place
/// from the top of the list. VM lane only (`ops/gui/vm-gui-runner.sh reader xcuitest`) — never the owner's
/// screen. The model's half (what is saved, when it is ignored) is `RestoreListPlaceTests` in the unit lane.
@MainActor
final class RestoreScrollUITests: XCTestCase {

    private var scratch: URL!
    private var corpus: URL!
    private var app: XCUIApplication?
    private let count = 80

    override func setUp() async throws {
        continueAfterFailure = false
        scratch = try WarmStartUITests.makeScratchDirectory(prefix: "AR-RestoreScroll")
        corpus = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        // Name and date in the same order, so the list reads doc-01 … doc-80 whichever the default sort is.
        for i in 1...count {
            let url = corpus.appendingPathComponent(String(format: "doc-%02d.pdf", i))
            try Data("PDF fixture bytes \(i)".utf8).write(to: url)
            try (URL(fileURLWithPath: url.path) as NSURL)
                .setResourceValue(["Unread", String(1900 + i)], forKey: .tagNamesKey)
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testARelaunchReturnsToTheRowsThatWereOnScreen() throws {
        var app = launch()
        let table = app.tables["ar.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 30), "the main window should come up")
        waitForRows(app, minimum: count)
        XCTAssertEqual(topRowNumber(app), 1, "precondition: a fresh list starts at its first row")

        // Scroll the wheel, as a user does, to somewhere in the middle of the list.
        for _ in 0..<12 where (topRowNumber(app) ?? 0) < 25 {
            table.scroll(byDeltaX: 0, deltaY: -40)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let before = try XCTUnwrap(topRowNumber(app), "the top row before the quit")
        XCTAssertGreaterThan(before, 10, "precondition: the list really scrolled away from its top")
        captureScreenshot("restore-scroll-before-quit")

        quit(app)
        app = launch()
        XCTAssertTrue(app.tables["ar.table"].waitForExistence(timeout: 30), "the window should come back")
        waitForRows(app, minimum: count)
        var after: Int?
        let deadline = Date().addingTimeInterval(10)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            after = topRowNumber(app)
        } while after != before && Date() < deadline
        captureScreenshot("restore-scroll-after-relaunch")
        // The row saved is the one under the list's top edge, which before the quit may have been half
        // hidden there; after the relaunch it is the first row in full. One row is the tolerance.
        let restored = try XCTUnwrap(after, "a row at the top after the relaunch")
        XCTAssertLessThanOrEqual(abs(restored - before), 1,
                                 "the relaunch should come back at row \(before), not row \(restored)")
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication.archiveUITestApp()   // never a bare init — see UITestLaunch
        app.launchArguments += ["-ARUITestRootPath", corpus.path]
        app.launch()
        app.activate()
        self.app = app
        return app
    }

    /// ⌘Q, as a user quits, so the app ends normally. Falls back to terminate() after 15 s.
    private func quit(_ app: XCUIApplication) {
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(15)
        while app.state != .notRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if app.state != .notRunning { app.terminate() }
    }

    private func waitForRows(_ app: XCUIApplication, minimum: Int, timeout: TimeInterval = 30) {
        let table = app.tables["ar.table"]
        let deadline = Date().addingTimeInterval(timeout)
        while table.tableRows.count < minimum, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertGreaterThanOrEqual(table.tableRows.count, minimum, "expected \(minimum) rows within \(timeout)s")
    }

    /// The number of the first row shown in full below the column header (doc-NN → NN).
    private func topRowNumber(_ app: XCUIApplication) -> Int? {
        let table = app.tables["ar.table"]
        let header = app.descendants(matching: .any)["ar.table.header"]
        let top = header.exists ? header.frame.maxY : table.frame.minY
        let bottom = table.frame.maxY
        for row in table.tableRows.allElementsBoundByIndex {
            let frame = row.frame
            guard frame.height > 0, frame.minY >= top - 1, frame.minY < bottom else { continue }
            let texts = row.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }
            guard let name = texts.first(where: { $0.contains("doc-") }),
                  let range = name.range(of: "doc-") else { continue }
            return Int(name[range.upperBound...].prefix(2))
        }
        return nil
    }
}
