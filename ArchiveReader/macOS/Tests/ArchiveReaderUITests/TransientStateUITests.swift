import XCTest

/// W40.e13 — transient states between two settled screens (`packages/UITestSupport/Runner/TransientCheck.swift`).
/// The app's DEBUG recorder samples the watched sections after every committed run-loop pass; each transition here
/// must take them from the old settled state to the new one without showing anything else on the way. Read-only:
/// nothing here writes a tag (the quality filter and the panes change only what is shown).
final class TransientStateUITests: FixtureUITestCase {

    /// The file list, the sidebar, the filter bar, the toolbar, the status bar, the tag cloud, the empty states
    /// and the preview sheet, plus every sheet.
    static let sections = ["ar.table", "ar.sidebar", "ar.filter", "ar.toolbar", "ar.status", "ar.tagCloud",
                           "ar.empty", "ar.preview", TransientCheck.sheets]

    func testCommonTransitionsShowNoTransientState() throws {
        relaunch(TransientCheck.launchArguments(sections: Self.sections))
        continueAfterFailure = true   // one flickering transition must not hide the next one's
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)

        TransientCheck.check("next file (click)", in: app, test: self) { clickRow(1) }
        TransientCheck.check("next file (down arrow)", in: app, test: self) {
            app.typeKey(.downArrow, modifierFlags: [])
        }
        TransientCheck.check("previous file (up arrow)", in: app, test: self) {
            app.typeKey(.upArrow, modifierFlags: [])
        }
        // No folder switch: the sidebar's folders come from the rows' paths, and the GUI fixture's only subfolder
        // (`Archival Photos JPEGS`) holds a JPEG that is not a row, so it lists none (measured in the VM, 2026-10-17).
        // Covering it needs a fixture subfolder with a PDF in it; see execution-plans/items/W40.e13.md.
        TransientCheck.check("filter to Q3", in: app, test: self) {
            app.descendants(matching: .any)["ar.filter.quality.Q3"].firstMatch.click()
        }
        TransientCheck.check("clear the Q3 filter", in: app, test: self) {
            app.descendants(matching: .any)["ar.filter.quality.Q3"].firstMatch.click()
        }
        clickRow(0)
        TransientCheck.check("open the preview sheet", in: app, test: self) {
            toolbarButton("ar.toolbar.preview").click()
        }
        TransientCheck.check("close the preview sheet", in: app, test: self) {
            app.buttons["ar.preview.done"].firstMatch.click()
        }
        TransientCheck.check("hide the sidebar", in: app, test: self) { toolbarButton("ar.toolbar.sidebar").click() }
        TransientCheck.check("show the sidebar", in: app, test: self) { toolbarButton("ar.toolbar.sidebar").click() }
        TransientCheck.check("toggle the tag cloud", in: app, test: self) {
            toolbarButton("ar.toolbar.tagCloud").click()
        }
        TransientCheck.check("toggle the tag cloud back", in: app, test: self) {
            toolbarButton("ar.toolbar.tagCloud").click()
        }
    }

    /// The recorder must fail on a real flicker before its passes are trusted: with `-ArchiveTransientPlant
    /// blink` the app hides its window's content for one pass during each transition, and that must be reported.
    func testRecorderCatchesAPlantedFlicker() throws {
        relaunch(TransientCheck.launchArguments(sections: Self.sections, plant: true))
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        let findings = TransientCheck.check("next file, planted flicker", in: app, test: self,
                                            expectFindings: true) { clickRow(1) }
        XCTAssertTrue(findings.contains { $0.contains(" removed: ") },
                      "the planted blink should be reported as a section leaving and coming back: \(findings)")
    }

    /// `FixtureUITestCase.setUp` has already launched with the fixture; relaunch with the recorder switched on.
    private func relaunch(_ arguments: [String]) {
        app.terminate()
        app.launchArguments += arguments
        app.launch()
        app.activate()
        XCTAssertTrue(table.waitForExistence(timeout: 10), "Table should appear after the relaunch")
        waitForRows(minimum: 1, timeout: 15)
    }
}

/// The analysis's self-test, outside the fixture class so it runs even where the GUI fixture is absent.
final class TransientCheckSelfTests: XCTestCase {
    func testTransientAnalysisCatchesPlantedFlickers() {
        TransientCheckSelfTest.run()
    }
}
