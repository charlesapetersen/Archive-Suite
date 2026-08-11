import XCTest
import Darwin   // getpwuid / getuid — resolve the REAL home from the password DB

/// Trivial launch smoke test for the Archive Notes GUI harness (W8-S7 scaffold).
///
/// Mirrors the shipped Reader harness (`ArchiveReaderUITests` / `FixtureUITestCase`).
/// Running this needs owner-side auth (Accessibility + Screen Recording TCC, an unlocked session,
/// and `taskport` password-free for XCUITest) — so the *scaffold/build* is done unattended
/// (`xcodebuild build-for-testing`), and the actual RUN is GUI-gated (GUI mode `on`).
///
/// The app is launched against the pre-built SCRATCH fixture at
/// `~/Library/Application Support/ArchiveNotes/AN-GUI-Fixture` via the DEBUG `-ANUITestStorePath`
/// override (`RootFolderStore.adoptTestStore` — sets the root IN-MEMORY ONLY; never persists
/// `notesStoreRootBookmark`, never touches the real store). If the fixture directory is absent, the
/// test is skipped (build `scripts/make-notes-fixture.sh` first) — so a bare `build-for-testing`
/// stays green and no launch ever opens the owner's real store.
///
/// `@MainActor` + app-created-in-the-test (rather than setUp/tearDown, whose `nonisolated`
/// XCTestCase overrides can't touch main-actor state): XCUITest's `XCUIApplication`/`XCUIElement`
/// are main-actor-isolated under Swift 6 (and UI tests drive the app on the main thread), so this
/// shape keeps the UITest target warning-free.
@MainActor
final class SmokeUITest: XCTestCase {

    /// Absolute path to the pre-built GUI fixture, resolved against the REAL home.
    ///
    /// The XCUITest runner is sandboxed, so `FileManager.homeDirectoryForCurrentUser` /
    /// `NSHomeDirectory()` resolve to the sandbox CONTAINER — NOT the real `~/` where
    /// `scripts/make-notes-fixture.sh` writes the fixture (the pitfall that made the Reader Wave-7
    /// harness skip 13/14). Resolve the real home via the password database (`getpwuid`), which the
    /// sandbox container does NOT redirect; the Debug-only Route-B temporary-exception entitlement
    /// grants read access to `/Users/`, so both the `fileExists` check here and the app's own read
    /// of the launch-arg path succeed. An explicit `AN_GUI_FIXTURE_PATH` env var, if set, overrides.
    static let fixturePath: String = {
        if let override = ProcessInfo.processInfo.environment["AN_GUI_FIXTURE_PATH"],
           !override.isEmpty {
            return override
        }
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return "\(realHome)/Library/Application Support/ArchiveNotes/AN-GUI-Fixture"
    }()

    func testAppLaunchesAndShowsMainWindow() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.fixturePath),
            "GUI fixture not found — run scripts/make-notes-fixture.sh first"
        )

        let app = XCUIApplication.archiveUITestApp()   // never a bare init — see UITestLaunch
        // Open the SCRATCH fixture store (in-memory override — never persists / touches the real store).
        app.launchArguments += ["-ANUITestStorePath", Self.fixturePath]
        app.launch()
        app.activate()   // bring to front so the window is reliably on-screen even if another app had focus
        defer { app.terminate() }

        let window = app.windows["Archive Notes"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "The main Archive Notes window should appear within 10 seconds"
        )
    }
}
