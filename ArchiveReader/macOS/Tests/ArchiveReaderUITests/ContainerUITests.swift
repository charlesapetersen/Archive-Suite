import XCTest

/// W47.ct-reader-view: the folder levels offered when a root is first added, the Container column, the Containers
/// facet menu and the Inspector's Container section, on a scratch corpus built here. The only file the app writes is
/// the level map, in the scratch corpus's `.archivesuite` folder, when the test presses Save, and (W47.ct-reader-edit)
/// the box folders' container files, when the test edits a container, and (W40.reader-item-field-edit) a box folder's
/// `.archivesuite/item-fields.json`, when the test corrects an item field.
@MainActor
final class ContainerUITests: XCTestCase {
    private var scratch: URL!
    private var corpus: URL!
    private var app: XCUIApplication?

    override func setUp() async throws {
        continueAfterFailure = false
        scratch = try WarmStartUITests.makeScratchDirectory(prefix: "AR-Containers")
        corpus = scratch.appendingPathComponent("corpus", isDirectory: true)
        for (box, docs) in [("Box 17", 1...3), ("Box 18", 4...5)] {
            let dir = corpus.appendingPathComponent("Hoover Institution Archives", isDirectory: true)
                .appendingPathComponent("Glotzer papers, Mss 1036", isDirectory: true)
                .appendingPathComponent(box, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in docs {
                let url = dir.appendingPathComponent(String(format: "doc-%02d.pdf", i))
                try Data("PDF fixture bytes \(i)".utf8).write(to: url)
                try (URL(fileURLWithPath: url.path) as NSURL)
                    .setResourceValue(["Unread", String(1950 + i)], forKey: .tagNamesKey)
            }
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.archiveUITestApp()   // never a bare init — see UITestLaunch
        app.launchArguments += ["-ARUITestRootPath", corpus.path] + extra
        app.launch()
        app.activate()
        self.app = app
        return app
    }

    private func waitForRows(_ app: XCUIApplication, _ count: Int, timeout: TimeInterval = 30) {
        let table = app.tables["ar.table"]
        let deadline = Date().addingTimeInterval(timeout)
        while table.tableRows.count != count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertEqual(table.tableRows.count, count, "expected \(count) rows within \(timeout)s")
    }

    func testTheFolderLevelsAreOfferedThenTheColumnFacetsAndInspectorShowTheContainer() throws {
        let app = launch(["-ARUITestOfferContainerLevels"])
        waitForRows(app, 5)

        let sheet = app.buttons["ar.containerLevels.save"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 60), "offered once the scan has settled")
        let preview = app.staticTexts["ar.containerLevels.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.accessibilityText.contains("Container: Box 1"), preview.accessibilityText)
        XCTAssertTrue(preview.accessibilityText.contains("Repository: Hoover Institution Archives"))
        _ = captureScreenshot("containers-level-sheet")
        let mapURL = corpus.appendingPathComponent(".archivesuite/container-levels.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path), "nothing is written before Save")
        sheet.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mapURL.path), "Save writes the level map")

        // The column appears once the catalog is rebuilt with the map.
        let table = app.tables["ar.table"]
        let cell = table.staticTexts["Box 17"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), "the Container column shows each file's box")
        _ = captureScreenshot("containers-column")

        // A facet narrows the list and shows as a chip.
        let menu = app.descendants(matching: .any)["ar.filter.containers"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.click()
        let containerItem = app.menuItems["Container"].firstMatch
        XCTAssertTrue(containerItem.waitForExistence(timeout: 5))
        containerItem.hover()
        let box18 = app.menuItems["Box 18 (2)"].firstMatch
        XCTAssertTrue(box18.waitForExistence(timeout: 5))
        box18.click()
        waitForRows(app, 2)
        let chip = app.descendants(matching: .any)["ar.filter.chip.container.container"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the facet is a removable chip")
        _ = captureScreenshot("containers-facet")

        // The Inspector lists the file's container with each value's state.
        table.tableRows.element(boundBy: 0).click()
        if !app.buttons["ar.tagEditor.done"].exists { app.typeKey("i", modifierFlags: [.command, .option]) }
        let value = app.staticTexts["ar.container.container.value"].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 10), "the Inspector's Container section")
        XCTAssertEqual(value.accessibilityText, "Box 18")
        let status = app.descendants(matching: .any)["ar.container.container.status"].firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertTrue(status.accessibilityText.contains("lower confidence"), status.accessibilityText)
        _ = captureScreenshot("containers-inspector")

        // Asked once: a relaunch does not offer the sheet again.
        app.terminate()
        let again = launch(["-ARUITestOfferContainerLevels"])
        waitForRows(again, 5)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(again.buttons["ar.containerLevels.save"].exists, "a root with a map is not asked")
    }

    /// W47.ct-reader-edit: a value changed in the Inspector reaches every file of its run, and "set for selection"
    /// gives the selected files a box of their own while the others keep theirs. Only the box folder's
    /// `.archivesuite/containers.json` is written.
    func testTheInspectorEditsARunAndSetsABoxForTheSelection() throws {
        let suite = corpus.appendingPathComponent(".archivesuite", isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        try Data(#"{"levels":["repository","collection","box"],"overrides":{},"schemaVersion":1}"#.utf8)
            .write(to: suite.appendingPathComponent("container-levels.json"))
        let box17 = corpus.appendingPathComponent("Hoover Institution Archives/Glotzer papers, Mss 1036/Box 17",
                                                  isDirectory: true)
        let written = box17.appendingPathComponent(".archivesuite/containers.json")

        let app = launch()
        waitForRows(app, 5)
        let table = app.tables["ar.table"]
        XCTAssertTrue(table.staticTexts["Box 17"].firstMatch.waitForExistence(timeout: 30))

        // One file: Change… the container. Box 17 comes from the folder name, so the edit is the folder's own value.
        func rows(_ box: String) -> XCUIElementQuery {
            table.tableRows.containing(NSPredicate(format: "label == %@ OR value == %@", box, box))
        }
        rows("Box 17").element(boundBy: 0).click()
        if !app.buttons["ar.tagEditor.done"].exists { app.typeKey("i", modifierFlags: [.command, .option]) }
        let edit = app.descendants(matching: .any)["ar.container.container.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 15), "each value has an Edit menu")
        edit.click()
        let change = app.menuItems["Change…"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        change.click()
        let field = app.textFields["ar.container.container.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let scope = app.staticTexts["ar.container.container.scope"].firstMatch
        XCTAssertTrue(scope.accessibilityText.contains("every file in this folder"), scope.accessibilityText)
        _ = captureScreenshot("containers-edit-field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Box 99\r")
        XCTAssertTrue(table.staticTexts["Box 99"].firstMatch.waitForExistence(timeout: 20), "the list follows the edit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path), "the box folder's container file")
        let value = app.staticTexts["ar.container.container.value"].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 10))
        XCTAssertEqual(value.accessibilityText, "Box 99")
        let status = app.descendants(matching: .any)["ar.container.container.status"].firstMatch
        XCTAssertTrue(status.accessibilityText.lowercased().contains("checked"), status.accessibilityText)
        _ = captureScreenshot("containers-edited")

        XCTAssertEqual(rows("Box 99").count, 3, "every file of the folder follows")

        // Two files: set a box for the selection.
        rows("Box 99").element(boundBy: 0).click()
        XCUIElement.perform(withKeyModifiers: .command) { rows("Box 99").element(boundBy: 1).click() }
        let input = app.textFields["ar.containerSelection.value"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "several files: set for selection")
        input.click()
        input.typeText("Box 5")
        app.buttons["ar.containerSelection.set"].firstMatch.click()
        let deadline = Date().addingTimeInterval(20)
        while rows("Box 5").count < 2, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        XCTAssertEqual(rows("Box 5").count, 2, "the selected files show their box")
        XCTAssertEqual(rows("Box 99").count, 1, "the third file of the folder keeps the edit")
        XCTAssertEqual(rows("Box 18").count, 2, "the other folder is untouched")
        _ = captureScreenshot("containers-set-for-selection")
        let json = try String(contentsOf: written, encoding: .utf8)
        XCTAssertTrue(json.contains("Box 5") && json.contains("Box 99"), json)
    }

    /// W47.ct-reader-edit-undo: Edit ▸ Undo takes a container change back, and Edit ▸ Redo makes it again; each
    /// rewrites only the box folder's container file.
    func testEditUndoAndRedoTakeAContainerChangeBackAndForward() throws {
        let suite = corpus.appendingPathComponent(".archivesuite", isDirectory: true)
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        try Data(#"{"levels":["repository","collection","box"],"overrides":{},"schemaVersion":1}"#.utf8)
            .write(to: suite.appendingPathComponent("container-levels.json"))
        let written = corpus.appendingPathComponent(
            "Hoover Institution Archives/Glotzer papers, Mss 1036/Box 17/.archivesuite/containers.json")

        let app = launch()
        waitForRows(app, 5)
        let table = app.tables["ar.table"]
        XCTAssertTrue(table.staticTexts["Box 17"].firstMatch.waitForExistence(timeout: 30))
        func count(_ box: String) -> Int {
            table.tableRows.containing(NSPredicate(format: "label == %@ OR value == %@", box, box)).count
        }
        func waitFor(_ box: String, _ n: Int, _ why: String) {
            let deadline = Date().addingTimeInterval(20)
            while count(box) != n, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
            XCTAssertEqual(count(box), n, why)
        }
        table.tableRows.containing(NSPredicate(format: "label == %@ OR value == %@", "Box 17", "Box 17"))
            .element(boundBy: 0).click()
        if !app.buttons["ar.tagEditor.done"].exists { app.typeKey("i", modifierFlags: [.command, .option]) }
        let edit = app.descendants(matching: .any)["ar.container.container.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.click()
        app.menuItems["Change…"].firstMatch.click()
        let field = app.textFields["ar.container.container.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Box 99\r")
        waitFor("Box 99", 3, "the edit reaches the folder's files")
        let edited = try String(contentsOf: written, encoding: .utf8)
        XCTAssertTrue(edited.contains("Box 99"), edited)

        // Edit ▸ Undo, named for the change (W49.reader-undo-menu-names): it read a bare "Undo", and only the menu
        // reached a container edit; ⌘Z now does too.
        func choose(_ title: String) {
            app.menuBars.menuBarItems["Edit"].click()
            let item = app.menuBars.menuBarItems["Edit"].menuItems[title].firstMatch
            let shown = app.menuBars.menuBarItems["Edit"].menuItems.allElementsBoundByIndex
                .map { "\($0.title)\($0.isEnabled ? "" : " (off)")" }
            XCTAssertTrue(item.waitForExistence(timeout: 5), "Edit ▸ \(title); the menu shows \(shown)")
            XCTAssertTrue(item.isEnabled, "Edit ▸ \(title) is enabled")
            _ = captureScreenshot("containers-edit-menu-\(title.lowercased())")
            item.click()
        }
        choose("Undo Container Change")
        waitFor("Box 17", 3, "undo puts the folder's name back")
        XCTAssertEqual(count("Box 99"), 0)
        let undone = try String(contentsOf: written, encoding: .utf8)
        XCTAssertFalse(undone.contains("Box 99"), "the file holds what it held before the edit (none): \(undone)")
        _ = captureScreenshot("containers-undone")

        choose("Redo Container Change")
        waitFor("Box 99", 3, "redo makes the change again")
        XCTAssertTrue(try String(contentsOf: written, encoding: .utf8).contains("Box 99"))

        // ⌘Z and ⇧⌘Z take the same change, the newest of any kind, with the list in front.
        table.tableRows.containing(NSPredicate(format: "label == %@ OR value == %@", "Box 99", "Box 99"))
            .element(boundBy: 0).click()
        app.typeKey("z", modifierFlags: .command)
        waitFor("Box 17", 3, "⌘Z undoes the container change")
        app.typeKey("z", modifierFlags: [.command, .shift])
        waitFor("Box 99", 3, "⇧⌘Z redoes it")
        XCTAssertTrue(try String(contentsOf: written, encoding: .utf8).contains("Box 99"))
        XCTAssertEqual(count("Box 18"), 2, "the other folder is untouched throughout")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: corpus.appendingPathComponent(
                "Hoover Institution Archives/Glotzer papers, Mss 1036/Box 18/.archivesuite").path))
    }

    /// W40.reader-item-field-edit: an item field added in the Inspector's Checks shows as the user's, checked; None
    /// hides it; Edit ▸ Undo brings the value back. Only the box folder's `.archivesuite/item-fields.json` is written,
    /// and no PDF changes.
    func testTheChecksCorrectAnItemFieldAndUndoTakesItBack() throws {
        let box17 = corpus.appendingPathComponent("Hoover Institution Archives/Glotzer papers, Mss 1036/Box 17",
                                                  isDirectory: true)
        let written = box17.appendingPathComponent(".archivesuite/item-fields.json")
        let pdf = box17.appendingPathComponent("doc-01.pdf")
        let bytes = try Data(contentsOf: pdf)

        let app = launch()
        waitForRows(app, 5)
        let table = app.tables["ar.table"]
        table.tableRows.element(boundBy: 0).click()
        if !app.buttons["ar.tagEditor.done"].exists { app.typeKey("i", modifierFlags: [.command, .option]) }
        let add = app.descendants(matching: .any)["ar.fieldStatus.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15), "a field page 2 lacks can be added")
        add.click()
        let titleItem = app.menuItems["Title"].firstMatch
        XCTAssertTrue(titleItem.waitForExistence(timeout: 5))
        titleItem.click()
        let field = app.textFields["ar.fieldStatus.title.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("The Harbour Report")
        _ = captureScreenshot("item-field-typing")
        app.buttons["ar.fieldStatus.title.save"].firstMatch.click()

        let value = app.staticTexts["ar.fieldStatus.title.value"].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 20), "the user's value is listed")
        XCTAssertEqual(value.accessibilityText, "The Harbour Report")
        let status = app.descendants(matching: .any)["ar.fieldStatus.title.status"].firstMatch
        XCTAssertEqual(status.label, "Checked")
        // The tooltip's source line ("Set by the user; page 2 has none") is checked in ItemFieldEditTests.
        _ = captureScreenshot("item-field-set")
        let json = try String(contentsOf: written, encoding: .utf8)
        XCTAssertTrue(json.contains("The Harbour Report") && json.contains("doc-01.pdf"), json)
        XCTAssertEqual(try Data(contentsOf: pdf), bytes, "the PDF is never rewritten")

        // None: the file has no title, still the user's and checked.
        let edit = app.descendants(matching: .any)["ar.fieldStatus.title.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.click()
        let none = app.menuItems["None"].firstMatch
        XCTAssertTrue(none.waitForExistence(timeout: 5))
        none.click()
        let gone = NSPredicate(format: "label == %@ OR value == %@", "None", "None")
        wait(for: [expectation(for: gone, evaluatedWith: value)], timeout: 20)
        _ = captureScreenshot("item-field-none")

        // Edit ▸ Undo, named for the change (W49.reader-undo-menu-names).
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuBarItems["Edit"].menuItems["Undo Title None"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.isEnabled)
        undo.click()
        let back = NSPredicate(format: "label == %@ OR value == %@", "The Harbour Report", "The Harbour Report")
        wait(for: [expectation(for: back, evaluatedWith: value)], timeout: 20)
        _ = captureScreenshot("item-field-undone")
        XCTAssertTrue(try String(contentsOf: written, encoding: .utf8).contains("The Harbour Report"))
        XCTAssertEqual(try Data(contentsOf: pdf), bytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: corpus.appendingPathComponent(
                "Hoover Institution Archives/Glotzer papers, Mss 1036/Box 18/.archivesuite").path),
                       "the other folder is untouched")
    }
}
