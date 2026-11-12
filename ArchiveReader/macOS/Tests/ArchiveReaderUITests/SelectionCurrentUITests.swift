import XCTest

/// W40.reader-selection-current, in the real window (the owner's Reader notes of 2026-11-10, points 10 and 13):
/// ⇧↓ in the preview sheet extends the list's selection from its anchor, the same run ⇧↑ then shrinks in the list,
/// and the file shown in the sheet or a document window is the list's row labelled "on view". The rows that leave
/// on a tag change (point 12) are covered headlessly in `SelectionCurrentTests`. Read-only on the fixture.
final class SelectionCurrentUITests: FixtureUITestCase {

    private var selectedRows: XCUIElementQuery { table.tableRows.matching(NSPredicate(format: "isSelected == true")) }
    /// The name cells that say "on view": VoiceOver reads a row by its cells. One per row marked.
    private var onViewRows: XCUIElementQuery {
        table.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'ar.cell.name.' AND label ENDSWITH ', on view'"))
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(condition(), "\(what) — rows: \(rowsDescription())")
    }

    private func rowsDescription() -> String {
        (0..<min(4, table.tableRows.count)).map { i in
            let row = table.tableRows.element(boundBy: i)
            let name = row.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'ar.cell.name.'")).firstMatch
            return "[\(i) row label=\(row.label) name label=\(name.label) selected=\(row.isSelected)]"
        }.joined(separator: " ")
    }

    /// Whether the row at `index` is the one marked on view.
    private func isOnView(_ index: Int) -> Bool {
        table.tableRows.element(boundBy: index).staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ar.cell.name.' AND label ENDSWITH ', on view'")).count == 1
    }

    func testShiftArrowsInThePreviewExtendTheListsRunAndTheFileShownIsOnView() throws {
        waitForRows(minimum: 4, timeout: 10)
        clickRow(0)
        toolbarButton("ar.toolbar.preview").click()
        let done = app.buttons["ar.preview.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the preview sheet opens")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        captureScreenshot("w40-selection-current-preview-open")
        wait("the file shown in the sheet is the list's row on view") { onViewRows.count == 1 && isOnView(0) }

        app.typeKey(.downArrow, modifierFlags: .shift)
        app.typeKey(.downArrow, modifierFlags: .shift)
        wait("⇧↓ twice in the sheet selects three rows") { selectedRows.count == 3 }
        wait("and the sheet shows the row just added") { onViewRows.count == 1 && isOnView(2) }
        captureScreenshot("w40-selection-current-preview-extended")

        app.typeKey(.upArrow, modifierFlags: .shift)
        wait("⇧↑ in the sheet shrinks the run from the same end") { selectedRows.count == 2 && isOnView(1) }

        done.click()
        wait("closing the sheet leaves nothing on view") { onViewRows.count == 0 }
        XCTAssertEqual(selectedRows.count, 2, "the selection stays")

        app.typeKey(.downArrow, modifierFlags: .shift)
        wait("⇧↓ in the list carries on the sheet's run") { selectedRows.count == 3 }
        app.typeKey(.upArrow, modifierFlags: .shift)
        app.typeKey(.upArrow, modifierFlags: .shift)
        wait("and ⇧↑ shrinks it back to the anchor") { selectedRows.count == 1 }
        XCTAssertTrue(table.tableRows.element(boundBy: 0).isSelected, "the anchor is the row first clicked")
    }

    func testTheDocumentWindowsFileIsOnViewInTheList() throws {
        waitForRows(minimum: 3, timeout: 10)
        clickRow(1)
        // The launch restores the last run's selection, which the previous test leaves as a two-row run; a click
        // inside a multi-row selection narrows it only after the mouse-up settles (NSTableView keeps it for a
        // drag), and a ⌘O before that opens both rows. Open only once row 1 alone is selected.
        wait("row 1 alone is selected") { selectedRows.count == 1 && table.tableRows.element(boundBy: 1).isSelected }
        pressKey("o", modifiers: .command)
        wait("a document window opens", timeout: 10) { app.windows.count >= 2 }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        captureScreenshot("w40-selection-current-document-window")
        wait("its file is the list's row on view") { onViewRows.count == 1 && isOnView(1) }
        pressKey("w", modifiers: .command)
        wait("closing it leaves nothing on view") { onViewRows.count == 0 }
    }
}
