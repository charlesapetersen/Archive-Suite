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

    /// Press a keyboard shortcut.
    func pressKey(_ key: String, modifiers: XCUIElement.KeyModifierFlags) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    // MARK: - Pixels

    /// Where a screenshot can be written so a human can READ it after the run, or `nil` if nowhere is
    /// writable (in which case `captureScreenshot` still attaches it to the result bundle).
    ///
    /// The VM GUI lane mounts the host's `~/.tart-mirror/vm-artifacts` into the guest at
    /// `/Volumes/My Shared Files/out` (`--dir=out:` in `ops/gui/vm-gui-runner.sh`), so a PNG written
    /// there appears on the host with no extraction step — which is what STEP 3.5 of the resume prompt
    /// means by "READ the screenshot from `~/.tart-mirror/vm-artifacts/`". Outside the VM that share does
    /// not exist and nothing is written. `AR_UITEST_SHOT_DIR` overrides it (verbatim).
    ///
    /// This is a *diagnostic* channel, never an assertion: no test may pass or fail on whether a
    /// directory happened to be writable.
    static let screenshotDirectory: URL? = {
        let candidates: [String]
        if let override = ProcessInfo.processInfo.environment["AR_UITEST_SHOT_DIR"], !override.isEmpty {
            candidates = [override]
        } else {
            candidates = ["/Volumes/My Shared Files/out"]
        }
        for path in candidates where FileManager.default.isWritableFile(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }()

    /// Capture the whole screen, attach it to the result bundle, and — when the VM's artifact share is
    /// mounted — also drop it beside the run's logs as `uitest-<name>.png` for a human to look at.
    ///
    /// The whole screen rather than one window on purpose: these shots are read to answer "did it
    /// actually DRAW", and a window-scoped capture of a pane that rendered nothing looks much like one
    /// that rendered. Returns the written path (nil if it was only attached).
    @discardableResult
    func captureScreenshot(_ name: String) -> URL? {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = Self.screenshotDirectory else {
            print("[shot] \(name): no writable artifact dir — attached to the result bundle only")
            return nil
        }
        let url = dir.appendingPathComponent("uitest-\(name).png")
        do {
            try shot.pngRepresentation.write(to: url, options: .atomic)
            print("[shot] \(name): wrote \(url.path)")
            return url
        } catch {
            print("[shot] \(name): could not write \(url.path) — \(error)")
            return nil
        }
    }

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
