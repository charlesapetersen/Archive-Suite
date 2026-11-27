import XCTest

/// Window ▸ Tags (W40.tag-window-processor): the shared Tags window over the Processor's two lists, seeded by
/// `-APUITestTagLists` (suggestions Labor, Environment, Environtment; subject list Labor, Strikes, Civil Rights) with
/// the scratch output folder made a Reader archive. A rename edits both lists, is recorded in the archive's change log,
/// and Edit ▸ Undo puts it back and withdraws the entry; a remove takes a tag off and says the other apps keep it.
@MainActor
final class TagsWindowUITests: XCTestCase {
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)",
                                                                                         isDirectory: true)
    private var output: URL { scratch.appendingPathComponent("Output", isDirectory: true) }

    /// What the count column says on a tag's own row.
    private func lists(_ window: XCUIElement, _ tag: String) -> XCUIElement {
        let cell = window.descendants(matching: .any)["tags.items.\(tag)"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "the count column of \(tag)")
        return cell
    }

    private func label(_ element: XCUIElement) -> String { (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label }

    /// The archive's change log entries, as (from, to, app, withdrawn).
    private func logEntries() -> [(String, String, String, Bool)] {
        let url = output.appendingPathComponent(".archivesuite/tag-changes.json")
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let changes = doc["changes"] as? [[String: Any]] else { return [] }
        return changes.map {
            ($0["from"] as? String ?? "", $0["to"] as? String ?? "", $0["app"] as? String ?? "",
             $0["withdrawn"] as? Bool ?? false)
        }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(condition(), what)
    }

    private func shoot(_ app: XCUIApplication, _ name: String) throws {
        let shot = FileManager.default.temporaryDirectory.appendingPathComponent("processor-tags-\(name)-\(UUID()).png")
        try app.screenshot().pngRepresentation.write(to: shot)
        print("[shot] processor-tags-\(name): wrote \(shot.path)")
    }

    func testRenameIsRecordedAndUndoneAndRemoveSaysTheOtherAppsKeepIt() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode", "-APUITestTagLists", "-APUITestOutputDirectory", output.path
        ])
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
        app.launchEnvironment["ARCHIVEPROC_TAGVOCAB_FILE"] = scratch.appendingPathComponent("vocab.json").path
        app.launch()

        XCTAssertTrue(app.menuBars.menuBarItems["Window"].waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems["Tags"].click()
        let window = app.windows["Tags"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), app.debugDescription)

        let labor = window.descendants(matching: .any)["tags.row.Labor"].firstMatch
        XCTAssertTrue(labor.waitForExistence(timeout: 10), window.debugDescription)
        XCTAssertEqual(label(lists(window, "Labor")), "Both", window.debugDescription)
        XCTAssertEqual(label(lists(window, "Strikes")), "Subject list")
        XCTAssertEqual(label(lists(window, "Environment")), "Suggestions")
        try shoot(app, "lists")

        // Rename Labor → Labour: both lists, one log entry.
        labor.click()
        window.buttons["tags.rename"].click()
        let name = app.textFields["tags.rename.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Labour")
        app.buttons["tags.rename.commit"].firstMatch.click()
        let status = window.staticTexts["tags.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        waitFor("the rename's status line") { self.label(status).contains("on 2 lists") }
        XCTAssertTrue(window.descendants(matching: .any)["tags.row.Labour"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(window.descendants(matching: .any)["tags.row.Labor"].firstMatch.exists)
        XCTAssertEqual(label(lists(window, "Labour")), "Both")
        waitFor("the rename is recorded in the archive") {
            logEntries().contains { $0.0 == "Labor" && $0.1 == "Labour" && $0.2 == "processor" && !$0.3 }
        }
        try shoot(app, "renamed")

        // Edit ▸ Undo puts Labor back in both lists and withdraws the entry.
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo'")).firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.isEnabled, "Undo is offered after the rename: \(undo.title)")
        undo.click()
        XCTAssertTrue(window.descendants(matching: .any)["tags.row.Labor"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(label(lists(window, "Labor")), "Both", "Labor is back in both lists")
        waitFor("the Undo withdraws the entry") {
            logEntries().contains { $0.0 == "Labor" && $0.1 == "Labour" && $0.3 }
        }

        // Remove Environtment (suggestions only): gone, and the window says the files keep it.
        let typo = window.descendants(matching: .any)["tags.row.Environtment"].firstMatch
        XCTAssertTrue(typo.waitForExistence(timeout: 5))
        typo.click()
        window.buttons["tags.remove"].click()
        let confirm = app.buttons["tags.remove.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.click()
        XCTAssertTrue(typo.waitForNonExistence(timeout: 5))
        let note = window.descendants(matching: .any)["ap.tags.note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(logEntries().count, 1, "a removal is not recorded")
        try shoot(app, "removed")
    }
}
