import XCTest

/// W40.reader-advanced-search (owner session reader-1, row 33; rule rows, owner 2026-11-04): the Advanced Search
/// form opens on its starter rows, a row's field and operator change from their popups, the count follows, Search
/// narrows the list, Save as Smart Folder adds it to the sidebar, and Edit Smart Folder opens it filled in. Writes
/// no file: a smart folder is app defaults only, and the test deletes the one it made.
final class AdvancedSearchUITests: FixtureUITestCase {
    private let folderName = "AS UITest"

    override func tearDown() async throws {
        if app != nil {
            app.typeKey(.escape, modifierFlags: [])   // a form still open would hold the sidebar's menu back
            deleteSmartFolders()
        }
        try await super.tearDown()
    }

    func testRuleRowsSearchSaveAndEdit() throws {
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        waitForRows(minimum: 2, timeout: 15)
        deleteSmartFolders()   // one a killed earlier run left behind (the VM keeps the app's defaults)
        let all = rowCount

        let advanced = app.buttons["ar.filter.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5), "Advanced… is beside the OCR search box")
        advanced.click()
        let count = app.staticTexts["ar.advanced.count"]
        _ = count.waitForExistence(timeout: 3)
        _ = captureScreenshot("w40-advanced-search-open")
        XCTAssertTrue(count.waitForExistence(timeout: 5), "the form opens")
        let fields = app.popUpButtons.matching(identifier: "ar.advanced.rule.field")
        XCTAssertEqual(fields.count, 3, "three starter rows")
        XCTAssertEqual(fields.allElementsBoundByIndex.map { $0.value as? String },
                       ["OCR text", "Tags", "Date"], "the starter rows: OCR text, tags, a date")
        XCTAssertTrue(waitFor(count, toRead: "\(all) documents match"), "empty rows match everything")
        _ = captureScreenshot("w40-advanced-search-starter")

        // First row: File name does not contain "00001".
        fields.element(boundBy: 0).click()
        app.menuItems["File name"].click()
        let ops = app.popUpButtons.matching(identifier: "ar.advanced.rule.op")
        ops.element(boundBy: 0).click()
        app.menuItems["does not contain"].click()
        let text = app.textFields.matching(identifier: "ar.advanced.rule.text").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        text.click()
        text.typeText("00001")
        XCTAssertTrue(waitFor(count, toRead: "\(all - 1) documents match"), "the count follows the rule")

        // A rule added below, then taken away again.
        app.buttons.matching(identifier: "ar.advanced.add").element(boundBy: 0).click()
        XCTAssertEqual(fields.count, 4, "+ adds a row")
        app.buttons.matching(identifier: "ar.advanced.remove").element(boundBy: 1).click()
        XCTAssertEqual(fields.count, 3, "− removes it")
        _ = captureScreenshot("w40-advanced-search-filled")

        app.buttons["ar.advanced.search"].click()
        XCTAssertFalse(count.waitForExistence(timeout: 1), "Search closes the form")
        XCTAssertTrue(waitForRowCount(all - 1), "the list shows what the form counted")

        // Reopened on what the list shows, then saved as a smart folder.
        advanced.click()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(fields.element(boundBy: 0).value as? String, "File name", "the form opens on the search in effect")
        app.buttons["ar.advanced.saveAs"].click()
        let name = app.textFields["ar.advanced.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click()
        name.typeText(folderName)
        app.buttons["ar.advanced.saveNamed"].click()
        XCTAssertTrue(smartFolder().waitForExistence(timeout: 5), "the smart folder is in the sidebar")
        XCTAssertTrue(waitForRowCount(all - 1))

        // Edit Smart Folder opens the same form, filled in.
        smartFolder().rightClick()
        let edit = app.menuItems.matching(NSPredicate(format: "title == %@", "Edit Smart Folder…"))
            .allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(edit, "the smart folder's menu offers Edit Smart Folder…").click()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(fields.element(boundBy: 0).value as? String, "File name")
        XCTAssertEqual(text.value as? String, "00001")
        XCTAssertFalse(app.buttons["ar.advanced.saveAs"].exists, "editing saves in place")
        _ = captureScreenshot("w40-advanced-search-edit")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// W40.fix-reader-smart-folders: saved OCR rules count and scope files; only a typed text search
    /// contributes previews. The synthetic fixture puts California in bodies, never in file names.
    func testSmartFolderCountsAndPreviewsOnlyForUserTextSearch() throws {
        deleteSmartFolders()
        app.buttons["ar.filter.advanced"].click()
        let count = app.staticTexts["ar.advanced.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let text = app.textFields.matching(identifier: "ar.advanced.rule.text").firstMatch
        text.click()
        text.typeText("smartfolderabsentzzqx")
        XCTAssertTrue(waitFor(count, toRead: "0 documents match"), "wait for the OCR rule, not the old unfiltered count")
        text.typeKey("a", modifierFlags: .command)
        text.typeText("California")
        let deadline = Date().addingTimeInterval(30)
        var matches = 0
        while Date() < deadline {
            let label = (count.value as? String) ?? count.label
            matches = Int(label.split(separator: " ").first ?? "") ?? 0
            if matches > 0 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertGreaterThan(matches, 0, "the scratch OCR rule matches files")
        app.buttons["ar.advanced.saveAs"].click()
        let name = app.textFields["ar.advanced.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click(); name.typeText(folderName)
        app.buttons["ar.advanced.saveNamed"].click()
        let folder = smartFolder()
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForRowCount(matches))
        XCTAssertTrue(waitFor(folder, toRead: "\(matches) documents"), "sidebar counts the OCR rule")
        let preview = table.staticTexts.matching(NSPredicate(
            format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "California", "California")).firstMatch
        XCTAssertFalse(preview.exists, "saved OCR rules list filenames without snippets")
        _ = captureScreenshot("smart-folder-files-and-count")
        let query = app.textFields["ar.filter.ocr"]
        query.click(); query.typeText("California")
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "typing a text search adds the preview")
        _ = captureScreenshot("smart-folder-text-search")
        app.buttons["ar.filter.ocrClear"].click()
        XCTAssertTrue(waitForRowCount(matches))
        let clearDeadline = Date().addingTimeInterval(5)
        while preview.exists, Date() < clearDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(preview.exists, "clearing text search restores plain filenames")
        XCTAssertTrue(waitFor(folder, toRead: "\(matches) documents"))
        _ = captureScreenshot("smart-folder-cleared-search")
    }

    private func smartFolder() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ar.sidebar.smart")
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", folderName, folderName)).firstMatch
    }

    /// Through the sidebar's menu, every smart folder this test names. Never asserts: it also runs from tearDown.
    private func deleteSmartFolders() {
        for _ in 0..<5 {
            let item = smartFolder()
            guard item.waitForExistence(timeout: 2) else { return }
            item.rightClick()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            let delete = app.menuItems.matching(NSPredicate(format: "title == %@", "Delete"))
                .allElementsBoundByIndex.first { $0.isHittable }
            if let delete { delete.click() } else { app.typeKey(.escape, modifierFlags: []); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    private func waitFor(_ element: XCUIElement, toRead text: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == text || element.label == text { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("read \(element.label) / \(String(describing: element.value)), wanted \(text)")
        return false
    }

    private func waitForRowCount(_ n: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while rowCount != n, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        return rowCount == n
    }
}
