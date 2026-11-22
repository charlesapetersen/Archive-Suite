import XCTest

final class CloudDocumentUITests: FixtureUITestCase {
    override var extraLaunchArguments: [String] {
        ["-ARUITestCloudFile", Self.fixturePath + "/00001 IMG — Brown.pdf",
         "-ar.doc.thumbnailsVisible", "YES", "-ar.preview.thumbnailsVisible", "YES"]
    }

    func testDocumentWindowAsksBeforeDownloading() {
        selectFixture("00001")
        pressKey("o", modifiers: .command)
        checkPrompt("ar.doc")
        captureScreenshot("reader-document-cloud-prompt")
        app.buttons["ar.doc.downloadCloudFile"].click()
        checkTwoPagePDF("ar.doc", screenshot: "reader-document-cloud-downloaded")
        pressKey("w", modifiers: .command)

        selectFixture("00002")
        pressKey("o", modifiers: .command)
        checkTwoPagePDF("ar.doc")
    }

    func testSpacePreviewAsksBeforeDownloading() {
        selectFixture("00001")
        app.typeKey(.space, modifierFlags: [])
        checkPrompt("ar.preview")
        captureScreenshot("reader-space-cloud-prompt")
        app.buttons["ar.preview.downloadCloudFile"].click()
        checkTwoPagePDF("ar.preview", screenshot: "reader-space-cloud-downloaded")
        app.buttons["ar.preview.done"].click()

        selectFixture("00002")
        app.typeKey(.space, modifierFlags: [])
        checkTwoPagePDF("ar.preview")
    }

    private func selectFixture(_ number: String) {
        let name = app.textFields["ar.filter.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText(number)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(rowCount, 1)
        clickRow(0)
    }

    private func checkPrompt(_ prefix: String) {
        XCTAssertTrue(app.buttons["\(prefix).downloadCloudFile"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["This PDF is in the cloud"].exists
                      || app.descendants(matching: .any)["\(prefix).cloudFile"].firstMatch.exists)
    }

    private func checkTwoPagePDF(_ prefix: String, screenshot: String? = nil) {
        let prompt = app.descendants(matching: .any)["\(prefix).cloudFile"].firstMatch
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 8))
        let contactSheet = app.buttons["\(prefix).allPages"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: contactSheet)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        XCTAssertTrue(app.buttons["\(prefix).thumb.1.1"].waitForExistence(timeout: 5))
        if let screenshot { captureScreenshot(screenshot) }
        contactSheet.click()
        XCTAssertTrue(app.buttons["\(prefix).pageTile.1.2"].waitForExistence(timeout: 5),
                      "the loaded PDF has both fixture pages")
    }
}
