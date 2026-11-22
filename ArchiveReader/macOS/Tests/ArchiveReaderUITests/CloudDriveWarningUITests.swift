import XCTest

@MainActor
final class CloudDriveWarningUITests: XCTestCase {
    func testFirstLaunchAndCancelCloudFolder() throws {
        continueAfterFailure = false
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cloud = scratch.appendingPathComponent("Cloud fixture", isDirectory: true)
        let nested = cloud.appendingPathComponent("Archive", isDirectory: true)
        let original = scratch.appendingPathComponent("Original", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: original, withIntermediateDirectories: true)

        let app = XCUIApplication.archiveUITestApp()
        defer { app.terminate() }
        app.launchArguments += ["-ARUITestRootPath", original.path]
        app.launchEnvironment["ARCHIVE_CLOUD_WARNING_TEST_SUITE"] = "archive-reader-warning-\(UUID())"
        app.launchEnvironment["ARCHIVE_CLOUD_WARNING_TEST_PATH"] = cloud.path
        app.launch()

        let launchWarning = app.staticTexts["Keep archive material on this Mac"].firstMatch
        XCTAssertTrue(launchWarning.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["OK"].firstMatch.click()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows["Archive Reader"].waitForExistence(timeout: 10))
        XCTAssertFalse(launchWarning.exists)

        app.typeKey("o", modifierFlags: [.command, .shift])
        let choose = app.buttons["Choose Common Archive Folder"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(nested.path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(choose.isEnabled)
        choose.click()

        let warning = app.staticTexts["This selection is in a cloud drive"].firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10), app.debugDescription)
        let shot = fm.temporaryDirectory.appendingPathComponent("reader-cloud-warning-\(UUID()).png")
        try app.screenshot().pngRepresentation.write(to: shot)
        print("[shot] reader-cloud-folder-warning: wrote \(shot.path)")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: nested.path), [],
                       "Cancel must leave the chosen folder untouched, without even an archive marker.")
    }
}
