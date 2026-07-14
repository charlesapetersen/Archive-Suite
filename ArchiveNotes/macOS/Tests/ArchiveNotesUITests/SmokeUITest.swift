import XCTest

/// Trivial launch smoke test for the Archive Notes GUI harness (W8-S7 scaffold).
///
/// Mirrors the shipped Reader harness (`ArchiveReaderUITests.testAppLaunchesAndShowsMainWindow`).
/// Running this needs owner-side auth (Accessibility + Screen Recording TCC, an unlocked session,
/// and `taskport` password-free for XCUITest) — so the *scaffold/build* is done unattended
/// (`xcodebuild build-for-testing`), and the actual RUN is GUI-gated (deferred to W8-S8 / GUI-on).
///
/// `@MainActor` + app-created-in-the-test (rather than setUp/tearDown, whose `nonisolated`
/// XCTestCase overrides can't touch main-actor state): XCUITest's `XCUIApplication`/`XCUIElement`
/// are main-actor-isolated under Swift 6 (and UI tests drive the app on the main thread), so this
/// shape keeps the UITest target warning-free.
@MainActor
final class SmokeUITest: XCTestCase {

    func testAppLaunchesAndShowsMainWindow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let window = app.windows["Archive Notes"]
        XCTAssertTrue(
            window.waitForExistence(timeout: 10),
            "The main Archive Notes window should appear within 10 seconds"
        )
    }
}
