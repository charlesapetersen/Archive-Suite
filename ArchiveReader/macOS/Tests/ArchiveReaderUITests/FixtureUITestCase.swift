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

    /// Where a screenshot is written so a human can READ it after the run.
    ///
    /// ⚠️ **The VM's artifact share is NOT reachable from here, and that was measured, not assumed.**
    /// `ops/gui/vm-gui-runner.sh` mounts the host's `~/.tart-mirror/vm-artifacts` into the guest at
    /// `/Volumes/My Shared Files/out`, so writing a PNG there *would* land it on the host with no
    /// extraction step. But the XCUITest **runner is sandboxed** — the same trap as the GUI fixture path
    /// (see the class header) — so that share is not writable from inside a test, and the first version
    /// of this helper reported "no writable artifact dir" for all five shots of a run (2026-08-09).
    ///
    /// So write to the runner's own temporary directory, which the sandbox always permits, and print the
    /// path. `run_xcuitest` in `vm-gui-runner.sh` greps those `[shot] …: wrote <path>` lines out of the
    /// log afterwards and copies each file to the host over the *unsandboxed* `tart exec` — which is what
    /// makes STEP 3.5's "READ the screenshot from `~/.tart-mirror/vm-artifacts/`" true. The share is still
    /// tried first (it costs one `isWritableFile` call and works if a future runner is unsandboxed);
    /// `AR_UITEST_SHOT_DIR` overrides both, verbatim.
    ///
    /// This is a *diagnostic* channel, never an assertion: no test may pass or fail on where a shot went.
    static let screenshotDirectory: URL = {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["AR_UITEST_SHOT_DIR"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append("/Volumes/My Shared Files/out")
        for path in candidates where FileManager.default.isWritableFile(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }()

    /// Capture the whole screen, attach it to the result bundle, and write it as `uitest-<name>.png`
    /// where the VM lane can collect it (see `screenshotDirectory`).
    ///
    /// The whole screen rather than one window on purpose: these shots are read to answer "did it
    /// actually DRAW", and a window-scoped capture of a pane that rendered nothing looks much like one
    /// that rendered. Returns the written path (nil only if the write itself failed).
    ///
    /// Both the attachment and the file are kept. The attachment alone is not enough: `xcresulttool`
    /// refuses a result bundle that was never finalized (a killed or failed run leaves one with no
    /// `Info.plist`), and recovering shots from `…xcresult/Data` then means classifying blobs by magic
    /// bytes — which is how the shots for this test were read the first time.
    @discardableResult
    func captureScreenshot(_ name: String) -> URL? {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = Self.screenshotDirectory.appendingPathComponent("uitest-\(name).png")
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
