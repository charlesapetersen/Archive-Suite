import XCTest

/// W44.reocr-reader: Flag as Poor OCR (⌃⌘P) writes the `OCR Poor` tag and its shared flag record, Show Poor OCR Only
/// lists the flagged file alone, Improve OCR… hands it to Archive Processor, and a second ⌃⌘P removes the flag.
/// Scratch fixture only. The shared folder is the fixture script's `AR-GUI-ImproveOCR`, beside (never inside) the
/// archive, connected by path; no Processor is installed in the VM, so the DEBUG hand-off recorder stands in for
/// Launch Services and the status line says what was sent.
final class ImproveOCRUITests: FixtureUITestCase {
    static var supportPath: String { (fixturePath as NSString).deletingLastPathComponent + "/AR-GUI-ImproveOCR" }

    override var extraLaunchArguments: [String] {
        ["-ARUITestImproveOCRSupport", Self.supportPath, "-ARUITestImproveOCRHandoff"]
    }

    private let fileName = "00004 IMG — Brown.pdf"

    func testFlagFilterHandOffAndUnflag() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        typeInField("ar.filter.name", text: "00004")
        XCTAssertTrue(waitForRowCount(1), "the name filter should isolate the scratch document")
        clickRow(0)
        if isFlagged() {   // left by an earlier run
            pressKey("p", modifiers: [.command, .control])
            XCTAssertTrue(waitForFlag(false))
        }

        pressKey("p", modifiers: [.command, .control])
        XCTAssertTrue(waitForFlag(true), "⌃⌘P should write OCR Poor to the file")
        XCTAssertTrue(waitForStatus(containing: "Flagged 1 file as poor OCR"), "the status line should say so")
        XCTAssertTrue(waitForFlagRecord(), "the flag should be recorded in the shared folder")
        _ = captureScreenshot("w44-reader-flagged")

        // The filter: every file but the flagged one leaves the list.
        let nameField = app.textFields["ar.filter.name"]
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeKey(.delete, modifierFlags: [])
        waitForRows(minimum: 2, timeout: 10)
        clickMenuItem("Sort & Filter", "Show Poor OCR Only")
        let chip = app.descendants(matching: .any)["ar.filter.poorOCR"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the poor-OCR filter should show its chip")
        XCTAssertTrue(waitForRowCount(1), "only the flagged file should be listed")
        _ = captureScreenshot("w44-reader-poor-ocr-filter")

        // The hand-off.
        clickRow(0)
        clickMenuItem("Tags", "Improve OCR…")
        XCTAssertTrue(waitForStatus(containing: "Opening Archive Processor to improve the OCR of 1 file"),
                      "Improve OCR… should hand the file to the Processor")

        // Unflag: the title follows the selection, and the file leaves the filtered list once its write verified.
        let menuBar = app.menuBars.element(boundBy: 0)
        menuBar.menuBarItems["Tags"].click()
        XCTAssertTrue(app.menuItems["Remove Poor OCR Flag"].waitForExistence(timeout: 5),
                      "with a flagged file selected the command should offer to remove the flag")
        app.typeKey(.escape, modifierFlags: [])
        pressKey("p", modifiers: [.command, .control])
        XCTAssertTrue(waitForFlag(false), "a second ⌃⌘P should remove the flag")
        XCTAssertTrue(waitForRowCount(0), "the unflagged file should leave the poor-OCR list")
    }

    // MARK: Helpers

    private var filePath: String { URL(fileURLWithPath: Self.fixturePath).appendingPathComponent(fileName).path }

    private func isFlagged() -> Bool {
        let names = ((try? URL(fileURLWithPath: filePath).resourceValues(forKeys: [.tagNamesKey]))?.tagNames) ?? []
        return names.contains { $0.caseInsensitiveCompare("OCR Poor") == .orderedSame }
    }

    private func waitForFlag(_ flagged: Bool, timeout: TimeInterval = 10) -> Bool {
        wait(timeout) { self.isFlagged() == flagged }
    }

    /// A finished event under `Flags/` (the digest folder's name is the store's, so any one will do: the support
    /// folder is rebuilt empty with the fixture).
    private func waitForFlagRecord(timeout: TimeInterval = 10) -> Bool {
        wait(timeout) {
            let flags = Self.supportPath + "/Flags"
            let dirs = (try? FileManager.default.contentsOfDirectory(atPath: flags)) ?? []
            return dirs.contains { dir in
                let events = (try? FileManager.default.contentsOfDirectory(atPath: flags + "/" + dir + "/events")) ?? []
                return !events.isEmpty
            }
        }
    }

    private func waitForStatus(containing text: String, timeout: TimeInterval = 10) -> Bool {
        let status = app.staticTexts["ar.status.message"]
        return wait(timeout) { status.exists && status.accessibilityText.contains(text) }
    }

    private func clickMenuItem(_ menu: String, _ item: String) {
        app.activate()
        app.menuBars.element(boundBy: 0).menuBarItems[menu].click()
        let entry = app.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(menu) should offer \(item)")
        entry.click()
    }

    private func waitForRowCount(_ expected: Int, timeout: TimeInterval = 10) -> Bool {
        wait(timeout) { self.rowCount == expected }
    }

    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }
}
