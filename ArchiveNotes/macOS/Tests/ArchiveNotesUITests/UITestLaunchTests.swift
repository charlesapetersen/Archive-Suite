// UITestLaunchTests.swift — the launch seam that keeps the Notes VM GUI lane from going blind.
//
// W26.vmuitest-blind. These launch nothing, so they are fast and they run wherever the UITest bundle runs
// (including the Tart VM). They guard the ARGUMENTS the factory seeds — a factory that quietly stopped
// seeding the flag would take all 15 ArchiveNotesUITests down at once, with a message ("Main window
// should appear") that points at the product rather than at the launch. That is exactly the day this
// item cost, in both apps.

import XCTest

@MainActor
final class UITestLaunchTests: XCTestCase {

    /// The flag itself, spelled the way AppKit reads it. Written out literally rather than referencing
    /// the constant, so a typo in `UITestLaunch` cannot be "confirmed" by comparing it to itself.
    func testTheStateIgnoringFlagIsSpelledTheWayAppKitReadsIt() {
        XCTAssertEqual(UITestLaunch.deterministicWindowState, ["-ApplePersistenceIgnoreState", "YES"],
                       "AppKit reads this as a user default; a different spelling silently does nothing "
                       + "and every window assertion in the bundle starts failing for the wrong reason")
    }

    /// The factory seeds it. This is the property every launching test depends on.
    func testFactorySeedsTheStateIgnoringFlag() {
        let app = XCUIApplication.archiveUITestApp()
        XCTAssertTrue(app.launchArguments.contains("-ApplePersistenceIgnoreState"),
                      "archiveUITestApp() must seed the flag — got \(app.launchArguments)")
        guard let i = app.launchArguments.firstIndex(of: "-ApplePersistenceIgnoreState") else { return }
        XCTAssertEqual(app.launchArguments[safe: i + 1], "YES",
                       "the flag needs its YES value; a bare switch is not a boolean default")
    }

    /// A test appending its OWN arguments must not lose the flag. This is the `+=` shape both Notes launch
    /// sites use, so the check is on the real composition rather than on the constant alone.
    func testAppendingTestArgumentsKeepsTheFlag() {
        let app = XCUIApplication.archiveUITestApp()
        app.launchArguments += ["-ANUITestStorePath", "/tmp/does-not-need-to-exist"]
        XCTAssertTrue(app.launchArguments.contains("-ApplePersistenceIgnoreState"),
                      "appending must not drop the flag — got \(app.launchArguments)")
        XCTAssertTrue(app.launchArguments.contains("-ANUITestStorePath"),
                      "…and must not drop the test's own arguments either")
    }

    /// `UITestLaunch.arguments(_:)` is the shape for a site that ASSIGNS `launchArguments`. The flag must
    /// come FIRST and the caller's arguments must survive verbatim.
    func testAssignmentHelperPutsTheFlagFirstAndKeepsTheRest() {
        let composed = UITestLaunch.arguments(["-ANUITestStorePath", "/tmp/x"])
        XCTAssertEqual(composed, ["-ApplePersistenceIgnoreState", "YES", "-ANUITestStorePath", "/tmp/x"])
    }

    /// Adversarial: the helper must not silently swallow an empty argument list into nothing, because a
    /// caller that passes none still needs the flag.
    func testAssignmentHelperWithNoExtraArgumentsIsStillTheFlag() {
        XCTAssertEqual(UITestLaunch.arguments([]), UITestLaunch.deterministicWindowState)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
