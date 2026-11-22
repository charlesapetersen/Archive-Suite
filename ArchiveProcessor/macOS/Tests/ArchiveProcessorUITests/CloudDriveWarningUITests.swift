import XCTest

@MainActor
final class CloudDriveWarningUITests: XCTestCase {
    func testFirstLaunchAndCancelCloudInput() throws {
        continueAfterFailure = false
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let input = scratch.appendingPathComponent("Cloud fixture", isDirectory: true)
        let output = scratch.appendingPathComponent("Output", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: input, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let file = input.appendingPathComponent("scratch-input.png")
        try Data().write(to: file)

        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode", "-APUITestInputDirectory", input.path, "-APUITestOutputDirectory", output.path
        ])
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
        app.launchEnvironment["ARCHIVE_CLOUD_WARNING_TEST_SUITE"] = "archive-processor-warning-\(UUID())"
        app.launchEnvironment["ARCHIVE_CLOUD_WARNING_TEST_PATH"] = input.path
        app.launch()

        let launchWarning = app.staticTexts["Keep archive material on this Mac"].firstMatch
        XCTAssertTrue(launchWarning.waitForExistence(timeout: 10), app.debugDescription)
        let shot = fm.temporaryDirectory.appendingPathComponent("processor-cloud-warning-\(UUID()).png")
        try app.screenshot().pngRepresentation.write(to: shot)
        print("[shot] processor-first-launch-warning: wrote \(shot.path)")
        app.buttons["OK"].firstMatch.click()
        app.terminate()
        app.launch()
        let addFiles = app.buttons["Add Files…"].firstMatch
        XCTAssertTrue(addFiles.waitForExistence(timeout: 10))
        XCTAssertFalse(launchWarning.exists)

        func pickInput() {
            addFiles.click()
            let open = app.buttons["Open"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 10))
            app.typeKey("g", modifierFlags: [.command, .shift])
            app.typeText(file.path)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(open.isEnabled)
            open.click()
        }
        let warning = app.staticTexts["This selection is in a cloud drive"].firstMatch
        let row = app.staticTexts[file.lastPathComponent].firstMatch
        pickInput()
        XCTAssertTrue(warning.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
        XCTAssertFalse(row.exists)

        pickInput()
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        app.buttons["Use Anyway"].firstMatch.click()
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
    }
}
