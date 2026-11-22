import XCTest

final class NotesHeaderSortUITests: NotesFixtureUITestCase {
    func testTitleHeaderSortsRowsInBothDirections() throws {
        try withFixture {
            let window = mainWindow
            func titleCell(_ id: String) -> XCUIElement {
                window.descendants(matching: .any)["an.cell.title.\(id)"].firstMatch
            }
            let moore = titleCell(Self.idReader)
            let lovelace = titleCell(Self.idZotero)
            let plain = titleCell(Self.idPlain)
            func rowsAreOrdered(_ cells: [XCUIElement]) -> Bool {
                guard cells.allSatisfy({ $0.exists }) else { return false }
                let positions = cells.map { $0.frame.minY }
                return positions == positions.sorted() && Set(positions).count == cells.count
            }

            guard pollUntil(timeout: 10, { rowsAreOrdered([moore, lovelace, plain]) }) else {
                XCTFail("The default date sort should put the dated Moore note first")
                return
            }
            let titleHeader = window.buttons["Title"].firstMatch
            let clickTarget: XCUICoordinate
            if titleHeader.exists {
                clickTarget = titleHeader.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            } else {
                // Click inside the Title column, just above the first row.
                let firstCell = moore.frame
                clickTarget = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: firstCell.minX - window.frame.minX + 20,
                    dy: firstCell.minY - window.frame.minY - 8
                ))
            }

            clickTarget.click()
            XCTAssertTrue(pollUntil(timeout: 10) { rowsAreOrdered([lovelace, moore, plain]) },
                          "Ascending Title should read Lovelace, Moore, My First Note")
            try captureOrder("ascending")

            clickTarget.click()
            XCTAssertTrue(pollUntil(timeout: 10) { rowsAreOrdered([plain, moore, lovelace]) },
                          "Descending Title should read My First Note, Moore, Lovelace")
            try captureOrder("descending")
        }
    }

    private func captureOrder(_ direction: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-header-sort-\(direction).png")
        try mainWindow.screenshot().pngRepresentation.write(to: url, options: .atomic)
        print("[shot] header-sort-\(direction): wrote \(url.path)")
    }
}
