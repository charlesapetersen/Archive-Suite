import XCTest
import Darwin   // getpwuid / getuid — resolve the REAL home from the password DB

/// Base class for XCUITests that need the tagged-PDF fixture.
///
/// Launches Archive Reader with `-ARUITestRootPath` pointing to the pre-built
/// fixture at `~/Library/Application Support/ArchiveReader/AR-GUI-Fixture`.
/// If the fixture directory is absent, every test in the subclass is skipped
/// (the fixture is built by `scripts/make-gui-fixture.sh`).
/// `@MainActor` because XCUIApplication / XCUIElement are main-actor-isolated in the Swift 6 SDK;
/// UI tests drive the UI and belong on the main actor. Subclasses inherit this isolation.
@MainActor
class FixtureUITestCase: XCTestCase {

    /// Canonical, generated GUI-fixture root, resolved against the REAL home.
    ///
    /// The XCUITest runner is sandboxed, so `FileManager.homeDirectoryForCurrentUser`
    /// / `NSHomeDirectory()` resolve to the sandbox CONTAINER
    /// (`~/Library/Containers/com.archivereader.app/Data/…`) — NOT the real `~/` where
    /// `scripts/make-gui-fixture.sh` writes the fixture. That mismatch made every fixture
    /// test `XCTSkip` ("GUI fixture not found"). Resolve the real home via the password
    /// database (`getpwuid`), which the sandbox container does NOT redirect; the Debug-only
    /// Route-B temporary-exception entitlement (W7.3) grants read access to `/Users/`, so both
    /// the `fileExists` check (this test process) and the app's own read of the launch-arg
    /// path succeed. Non-mutating fixture tests may use an explicit `AR_GUI_FIXTURE_PATH` override;
    /// a test that edits Finder tags must reject it before it can write (see
    /// `requireGeneratedScratchFixtureForTagWrites`).
    static let canonicalFixturePath: String = {
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return "\(realHome)/Library/Application Support/ArchiveReader/AR-GUI-Fixture"
    }()

    static let fixturePath: String = {
        if let override = ProcessInfo.processInfo.environment["AR_GUI_FIXTURE_PATH"],
           !override.isEmpty {
            return override
        }
        return canonicalFixturePath
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

        app = .archiveUITestApp()   // never a bare XCUIApplication() — see UITestLaunch
        app.launchArguments += ["-ARUITestRootPath", Self.fixturePath]
        app.launch()
        app.activate()   // bring to front so row/header clicks are hittable even if another app had focus

        // Wait for the main window + table to appear and populate.
        let mainWindow = app.windows["Archive Reader"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10), "Main window should appear")
        XCTAssertTrue(table.waitForExistence(timeout: 10), "Table should appear")

        // The fixture loads synchronously off disk (DEBUG `-ARUITestRootPath` path), so rows are
        // present almost immediately; still give a brief settle window.
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

    /// Click a table row robustly. XCUITest reports a valid on-screen element as "not hittable" when
    /// another app briefly holds window-server focus (e.g. someone is using the Mac while the suite
    /// runs), so bring the app forward and wait for the row to become hittable before clicking, with
    /// a coordinate tap as a last resort. Returns the row element.
    @discardableResult
    func clickRow(_ index: Int, timeout: TimeInterval = 10) -> XCUIElement {
        app.activate()
        let row = table.tableRows.element(boundBy: index)
        _ = row.waitForExistence(timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while !row.isHittable, Date() < deadline {
            app.activate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        if row.isHittable {
            row.click()
        } else {
            // Fallback: tap near the row's left edge by coordinate (still exercises selection).
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }
        return row
    }

    /// Type a string into a text field identified by its accessibility ID.
    func typeInField(_ id: String, text: String) {
        let field = app.textFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Field \(id) should exist")
        field.click()
        field.typeText(text)
    }

    /// A tag-mutating UI test may run ONLY against the root rebuilt by
    /// `make-gui-fixture.sh`. `AR_GUI_FIXTURE_PATH` remains useful for read-only fixture tests, but
    /// accepting it here would make a misconfigured scheme capable of marking, editing, and renaming a
    /// real archive. The fixed root, non-symlink check, and exact marker together fail closed before
    /// the app launches any write action.
    func requireGeneratedScratchFixtureForTagWrites() throws {
        guard Self.fixturePath == Self.canonicalFixturePath else {
            throw FixtureSafetyError("refusing tag writes through AR_GUI_FIXTURE_PATH; use the generated "
                                     + "AR-GUI-Fixture root")
        }
        let root = URL(fileURLWithPath: Self.canonicalFixturePath, isDirectory: true)
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw FixtureSafetyError("refusing tag writes: the canonical GUI fixture root is not a real directory")
        }
        let marker = try Data(contentsOf: root.appendingPathComponent(".archive-suite-root.json"))
        let expected = Data((#"{"guid":"a4f1c2d8-0e3b-4a71-9c55-6d8e1f2a3b40","name":"AR-GUI-Fixture","kind":"reader","createdAt":"2026-07-30T00:00:00Z"}"# + "\n").utf8)
        guard marker == expected else {
            throw FixtureSafetyError("refusing tag writes: the canonical GUI fixture marker is missing or altered")
        }
    }

    /// Press a keyboard shortcut.
    func pressKey(_ key: String, modifiers: XCUIElement.KeyModifierFlags) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    // MARK: - Pixels
    //
    // `captureScreenshot` moved to `UITestScreenshots.swift` as an `XCTestCase` extension so
    // `WarmStartUITests` — which builds and launches its own corpus, and therefore cannot inherit this
    // class's fixture `setUp` — shares the one implementation rather than copying it (`W26.verify-fu2`).

    /// A navigation-window toolbar button, resolved robustly.
    ///
    /// On macOS 26 the SwiftUI toolbar can surface one `accessibilityIdentifier` on more than one
    /// accessibility element (the visible item plus an overflow/duplicate representation), so a bare
    /// `app.buttons[id]` fails to *click* with "Multiple matching elements found". Scope to the main
    /// window and prefer the hittable match (the on-screen toolbar item).
    func toolbarButton(_ id: String, timeout: TimeInterval = 5) -> XCUIElement {
        let matches = app.windows["Archive Reader"].buttons.matching(identifier: id)
        _ = matches.firstMatch.waitForExistence(timeout: timeout)
        for i in 0..<matches.count where matches.element(boundBy: i).isHittable {
            return matches.element(boundBy: i)
        }
        return matches.firstMatch
    }
}

private struct FixtureSafetyError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
