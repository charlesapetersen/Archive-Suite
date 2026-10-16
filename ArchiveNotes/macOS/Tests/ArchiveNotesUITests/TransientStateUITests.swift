import XCTest

/// W40.e13 — transient states between two settled screens (`packages/UITestSupport/Runner/TransientCheck.swift`).
/// The app's DEBUG recorder samples the watched sections after every committed run-loop pass; each transition here
/// must take them from the old settled state to the new one without showing anything else on the way. This is the
/// owner's report of the inspector flickering on every note change (`W40.fix-notes-inspector-jitter`), put where a
/// test can see it. Read-only: nothing here edits the fixture (the smart-folder sheet is cancelled).
final class TransientStateUITests: NotesFixtureUITestCase {

    /// The panes the transitions below change: the inspector (and its Locations block), the editor, the list,
    /// the sidebar and the filter bar, plus every sheet.
    static let sections = ["an.detail", "an.locations", "an.zotero", "an.editor", "an.list", "an.sidebar",
                           "an.filter", TransientCheck.sheets,
                           "!an.editor.test."]   // the UITest button strip, which reports internals

    private var plant = false
    override var extraLaunchArguments: [String] {
        TransientCheck.launchArguments(sections: Self.sections, plant: plant)
    }

    func testCommonTransitionsShowNoTransientState() throws {
        try withFixture {
            continueAfterFailure = true   // one flickering transition must not hide the next one's
            let window = mainWindow
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            row(Self.idPlain, in: window).click()

            TransientCheck.check("next note (click)", in: app, test: self) {
                row(Self.idReader, in: window).click()
            }
            TransientCheck.check("next note (down arrow)", in: app, test: self) {
                app.typeKey(.downArrow, modifierFlags: [])
            }
            TransientCheck.check("previous note (up arrow)", in: app, test: self) {
                app.typeKey(.upArrow, modifierFlags: [])
            }
            TransientCheck.check("switch folder (Reading)", in: app, test: self) {
                folder("Reading", in: window).click()
            }
            TransientCheck.check("switch folder (Ideas)", in: app, test: self) {
                folder("Ideas", in: window).click()
            }
            TransientCheck.check("switch to an empty folder (Inbox)", in: app, test: self) {
                folder("Inbox", in: window).click()
            }
            TransientCheck.check("switch to All Notes", in: app, test: self) {
                window.descendants(matching: .any)["an.sidebar.allNotes"].firstMatch.click()
            }
            TransientCheck.check("filter by kind", in: app, test: self) {
                kindFilter(in: window, to: "Extracts")
            }
            TransientCheck.check("filter back to all kinds", in: app, test: self) {
                kindFilter(in: window, to: "Both")
            }
            TransientCheck.check("open the smart-folder sheet", in: app, test: self) {
                window.buttons["an.filter.save"].click()
            }
            TransientCheck.check("close the smart-folder sheet", in: app, test: self) {
                window.sheets.firstMatch.buttons["Cancel"].click()
            }
            TransientCheck.check("hide the folder tree", in: app, test: self) {
                window.descendants(matching: .any)["an.toggleTree"].firstMatch.click()
            }
            TransientCheck.check("show the folder tree", in: app, test: self) {
                window.descendants(matching: .any)["an.toggleTree"].firstMatch.click()
            }
        }
    }

    /// The recorder must fail on a real flicker before its passes are trusted: with `-ArchiveTransientPlant
    /// blink` the app hides its window's content for one pass during each transition, and that must be reported.
    func testRecorderCatchesAPlantedFlicker() throws {
        plant = true
        try withFixture {
            let window = mainWindow
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            row(Self.idPlain, in: window).click()
            let findings = TransientCheck.check("next note, planted flicker", in: app, test: self,
                                                expectFindings: true) {
                row(Self.idReader, in: window).click()
            }
            XCTAssertTrue(findings.contains { $0.contains(" removed: ") },
                          "the planted blink should be reported as a section leaving and coming back: \(findings)")
        }
    }

    private func row(_ id: String, in window: XCUIElement) -> XCUIElement {
        let title = window.descendants(matching: .any)["an.cell.title.\(id)"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the seeded row \(id) should be listed")
        return title
    }

    private func folder(_ name: String, in window: XCUIElement) -> XCUIElement {
        let row = window.descendants(matching: .any).matching(identifier: "an.sidebar.folder")
            .matching(NSPredicate(format: "value ==[c] %@ OR label ==[c] %@", name, name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the \(name) folder row should be visible")
        return row
    }

    /// The kind picker is a segmented control; its segments surface as buttons or radio buttons.
    private func kindFilter(in window: XCUIElement, to title: String) {
        let kind = window.descendants(matching: .any)["an.filter.kind"].firstMatch
        XCTAssertTrue(kind.waitForExistence(timeout: 10), "the kind filter should exist")
        let segment = [kind.radioButtons[title], kind.buttons[title]].first { $0.exists }
        XCTAssertNotNil(segment, "the kind filter should offer \(title)")
        segment?.click()
    }
}

/// The analysis's self-test, outside the fixture class so it runs even where the GUI fixture is absent.
final class TransientCheckSelfTests: XCTestCase {
    func testTransientAnalysisCatchesPlantedFlickers() {
        TransientCheckSelfTest.run()
    }
}
