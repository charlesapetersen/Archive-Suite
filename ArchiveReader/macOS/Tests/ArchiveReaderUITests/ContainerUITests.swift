import XCTest

/// W47.ct-reader-view: the folder levels offered when a root is first added, the Container column, the Containers
/// facet menu and the Inspector's Container section, on a scratch corpus built here. The only file the app writes is
/// the level map, in the scratch corpus's `.archivesuite` folder, when the test presses Save.
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

        let sheet = app.descendants(matching: .any)["ar.containerLevels"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 60), "offered once the scan has settled")
        let preview = app.staticTexts["ar.containerLevels.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.accessibilityText.contains("Container: Box 1"), preview.accessibilityText)
        XCTAssertTrue(preview.accessibilityText.contains("Repository: Hoover Institution Archives"))
        _ = captureScreenshot("containers-level-sheet")
        let mapURL = corpus.appendingPathComponent(".archivesuite/container-levels.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mapURL.path), "nothing is written before Save")
        app.buttons["ar.containerLevels.save"].click()
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
        XCTAssertFalse(again.descendants(matching: .any)["ar.containerLevels"].exists, "a root with a map is not asked")
    }
}
