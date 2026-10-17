import XCTest

/// W40.e13 — transient states between two settled screens (`packages/UITestSupport/Runner/TransientCheck.swift`).
/// The app's DEBUG recorder samples the watched sections after every committed run-loop pass; each transition here
/// must take them from the old settled state to the new one without showing anything else on the way. This is the
/// owner's report of the inspector flickering on every note change (`W40.fix-notes-inspector-jitter`), put where a
/// test can see it, with a link holding the inspector's header and the editor's text to the same pass. Read-only: nothing here edits the fixture (the smart-folder sheet is cancelled).
final class TransientStateUITests: NotesFixtureUITestCase {

    /// The panes the transitions below change: the inspector (and its Locations block), the editor, the list,
    /// the sidebar and the filter bar, plus every sheet.
    static let sections = ["an.detail", "an.locations", "an.zotero", "an.editor", "an.list", "an.sidebar",
                           "an.filter", TransientCheck.sheets,
                           "!an.editor.test."]   // the UITest button strip, which reports internals

    /// The inspector's header and the editor's text both show the selected note, so a note change must change them in
    /// the same pass (`W40.fix-notes-inspector-jitter`: the screen video showed the new header over the previous body
    /// for 100–133 ms, which each section alone passes).
    static let links = [TransientLink(first: "an.detail.header", second: "an.editor.text")]

    /// `W40.fix-notes-editor-frame-jump`: when the shown note changes (next or previous note, a folder switch), the
    /// editor's text view is sometimes laid out at 0×0 off the window (x -429) for one pass and then back (first seen
    /// by this recorder 2026-10-16; on 3 of 5 VM runs, 2026-10-17). Carried by each transition that changes the
    /// shown note.
    static let editorJump = TransientCheck.KnownIssue(tag: "W40.fix-notes-editor-frame-jump", intermittent: true) {
        $0.hasPrefix("an.editor geometry: an.editor.text ") && $0.contains(" 0×0 against ")
    }

    /// `W40.fix-split-animation-wobble`: while the folder tree animates, a list row's or the header's width turns
    /// back by 1–2 points (1010→1012→1008), on some runs and not others (measured in the VM, 2026-10-17).
    static let splitWobble = TransientCheck.KnownIssue(tag: "W40.fix-split-animation-wobble", intermittent: true) {
        $0.hasPrefix("an.list geometry: ") && $0.contains(" width ")
    }

    private var plant = false
    override var extraLaunchArguments: [String] {
        TransientCheck.launchArguments(sections: Self.sections, links: Self.links, plant: plant)
    }

    func testCommonTransitionsShowNoTransientState() throws {
        try withFixture {
            continueAfterFailure = true   // one flickering transition must not hide the next one's
            let window = mainWindow
            XCTAssertTrue(window.waitForExistence(timeout: 15))
            row(Self.idPlain, in: window).click()

            TransientCheck.check("next note (click)", in: app, test: self, known: [Self.editorJump]) {
                row(Self.idReader, in: window).click()
            }
            TransientCheck.check("next note (down arrow)", in: app, test: self, known: [Self.editorJump]) {
                app.typeKey(.downArrow, modifierFlags: [])
            }
            TransientCheck.check("previous note (up arrow)", in: app, test: self, known: [Self.editorJump]) {
                app.typeKey(.upArrow, modifierFlags: [])
            }
            TransientCheck.check("switch folder (Reading)", in: app, test: self, known: [Self.editorJump]) {
                folder("Reading", in: window).click()
            }
            TransientCheck.check("switch folder (Ideas)", in: app, test: self, known: [Self.editorJump]) {
                folder("Ideas", in: window).click()
            }
            TransientCheck.check("switch to an empty folder (Inbox)", in: app, test: self, known: [Self.editorJump]) {
                folder("Inbox", in: window).click()
            }
            TransientCheck.check("switch to All Notes", in: app, test: self, known: [Self.editorJump]) {
                window.descendants(matching: .any)["an.sidebar.allNotes"].firstMatch.click()
            }
            TransientCheck.check("filter by kind", in: app, test: self, known: [Self.editorJump]) {
                kindFilter(in: window, to: "Extracts")
            }
            TransientCheck.check("filter back to all kinds", in: app, test: self, known: [Self.editorJump]) {
                kindFilter(in: window, to: "Both")
            }
            TransientCheck.check("open the smart-folder sheet", in: app, test: self) {
                window.buttons["an.filter.save"].click()
            }
            TransientCheck.check("close the smart-folder sheet", in: app, test: self) {
                window.sheets.firstMatch.buttons["Cancel"].click()
            }
            TransientCheck.check("hide the folder tree", in: app, test: self, known: [Self.splitWobble]) {
                window.descendants(matching: .any)["an.toggleTree"].firstMatch.click()
            }
            TransientCheck.check("show the folder tree", in: app, test: self, known: [Self.splitWobble]) {
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
