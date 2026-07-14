import XCTest
import Darwin   // getpwuid / getuid — resolve the REAL home from the password DB

/// Base class for XCUITests that need the tagged-PDF fixture.
///
/// Launches Archive Reader with `-ARUITestRootPath` pointing to the pre-built
/// fixture at `~/Library/Application Support/ArchiveReader/AR-GUI-Fixture`.
/// If the fixture directory is absent, every test in the subclass is skipped
/// (the fixture is built by `scripts/make-gui-fixture.sh`).
class FixtureUITestCase: XCTestCase {

    /// Absolute path to the pre-built GUI fixture, resolved against the REAL home.
    ///
    /// The XCUITest runner is sandboxed, so `FileManager.homeDirectoryForCurrentUser`
    /// / `NSHomeDirectory()` resolve to the sandbox CONTAINER
    /// (`~/Library/Containers/com.archivereader.app/Data/…`) — NOT the real `~/` where
    /// `scripts/make-gui-fixture.sh` writes the fixture. That mismatch made every fixture
    /// test `XCTSkip` ("GUI fixture not found"). Resolve the real home via the password
    /// database (`getpwuid`), which the sandbox container does NOT redirect; the Debug-only
    /// Route-B temporary-exception entitlement (W7.3) grants read access to `/Users/`, so both
    /// the `fileExists` check (this test process) and the app's own read of the launch-arg
    /// path succeed. An explicit `AR_GUI_FIXTURE_PATH` env var, if set, overrides (verbatim).
    static let fixturePath: String = {
        if let override = ProcessInfo.processInfo.environment["AR_GUI_FIXTURE_PATH"],
           !override.isEmpty {
            return override
        }
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return "\(realHome)/Library/Application Support/ArchiveReader/AR-GUI-Fixture"
    }()

    var app: XCUIApplication!

    /// The table that holds the file list rows.
    var table: XCUIElement { app.tables["ar.table"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.fixturePath),
            "GUI fixture not found — run scripts/make-gui-fixture.sh first"
        )

        app = XCUIApplication()
        app.launchArguments += ["-ARUITestRootPath", Self.fixturePath]
        app.launch()

        // Wait for the main window + table to appear and populate.
        let mainWindow = app.windows["Archive Reader"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10), "Main window should appear")
        XCTAssertTrue(table.waitForExistence(timeout: 10), "Table should appear")

        // Give Spotlight + NSMetadataQuery time to deliver results.
        waitForRows(minimum: 1, timeout: 15)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    // MARK: - Helpers

    /// Wait until the table has at least `minimum` rows, up to `timeout` seconds.
    func waitForRows(minimum: Int, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while table.tableRows.count < minimum, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    /// The number of visible rows in the table.
    var rowCount: Int { table.tableRows.count }

    /// Type a string into a text field identified by its accessibility ID.
    func typeInField(_ id: String, text: String) {
        let field = app.textFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Field \(id) should exist")
        field.click()
        field.typeText(text)
    }

    /// Press a keyboard shortcut.
    func pressKey(_ key: String, modifiers: XCUIElement.KeyModifierFlags) {
        app.typeKey(key, modifierFlags: modifiers)
    }
}
