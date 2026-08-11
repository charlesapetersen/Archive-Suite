import XCTest

@MainActor   // XCUIApplication / XCUIElement are main-actor-isolated in the Swift 6 SDK
final class ArchiveReaderUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = .archiveUITestApp()   // never a bare XCUIApplication() — see UITestLaunch
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testAppLaunchesAndShowsMainWindow() throws {
        let window = app.windows["Archive Reader"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "The main Archive Reader window should appear within 10 seconds"
        )
    }

    /// W26.walk2 — the incident's replacement sentence, through the real window in the headless VM.
    /// A brand-new path has never been Spotlight-indexed; the sole file is genuinely untagged. The UI
    /// may say that only after a complete walk, and the denominator must be visible in the rendered copy.
    func testAnUntaggedFolderShowsTheScannedDenominator() throws {
        // The UI-test runner is sandboxed, so its redirected home is the one place it may create this
        // fixture. The Reader's DEBUG-only `/Users/` temporary exception can read that container path;
        // Release retains the production entitlements and none of this code ships in the app target.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ArchiveReader", isDirectory: true)
            .appendingPathComponent("AR-GUI-Untagged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("genuinely untagged scratch file".utf8).write(to: root.appendingPathComponent("one.pdf"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        app.terminate()
        // ASSIGNS rather than appends (a deliberately fresh argument list for the relaunch), so the
        // state-ignoring flag has to be put back explicitly — `+=` elsewhere keeps it for free.
        app.launchArguments = UITestLaunch.arguments(["-ARUITestRootPath", root.path])
        app.launch()
        app.activate()

        let emptyState = app.descendants(matching: .any)["ar.empty.nothingTagged"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                      "the empty state must quote what discovery actually examined")
        let accessibilityText = emptyState.accessibilityText   // label + value — see UITestText.swift
        XCTAssertTrue(accessibilityText.contains("No tagged documents"),
                      "a complete scan of an untagged scratch folder should reach the honest empty state")
        XCTAssertTrue(accessibilityText.contains("Scanned 1 file in this folder"),
                      "the rendered denominator must match the one file actually examined")
        XCTAssertTrue(accessibilityText.contains("none carry a Read or Unread tag"),
                      "the claim about tags is coupled to its measured denominator")
    }
}
