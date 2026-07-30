// TestHostWindowSuppressionTests.swift — the unit suite must never draw on the owner's screen.
//
// `ArchiveReaderTests` is app-hosted (`TEST_HOST` = ArchiveReader.app), so running it LAUNCHES the
// real app. Before 2026-07-30 that opened the navigation window and held focus for the whole suite
// (2m52s / 211 tests, measured from the health gate's .xcresult) — on every unattended daemon
// session and every health gate. `ArchiveTestHost` fixes it in two independent ways; this pins both,
// so a future edit to ArchiveReaderApp.swift can't silently put the window back.
//
// Real GUI verification is NOT lost — it moved off-screen into the Tart VM
// (ops/gui/vm-gui-runner.sh, ops/gui/README.md §3), which is the only sanctioned lane for it.

import XCTest
import AppKit
import ArchiveCore

final class TestHostWindowSuppressionTests: XCTestCase {

    /// Sanity: these assertions are only meaningful because we really are the injected host.
    func testRunningAsUnitTestHost() {
        XCTAssertTrue(ArchiveTestHost.isUnitTestHost,
                      "XCTestConfigurationFilePath must be set in the unit-test host process")
    }

    /// Guard 1 — the process is demoted, so it owns no Dock icon and cannot steal focus.
    @MainActor
    func testActivationPolicyIsProhibited() {
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited,
                       "ArchiveReaderApp.init() must call ArchiveTestHost.suppressWindowsIfUnitTestHost()")
    }

    /// Guard 2 — no window scene was built, so nothing is on screen for anyone to see.
    @MainActor
    func testNoVisibleWindows() {
        let visible = NSApplication.shared.windows.filter(\.isVisible)
        XCTAssertTrue(visible.isEmpty,
                      "unit-test host opened \(visible.count) window(s): \(visible.map(\.title)) — "
                      + "ArchiveReaderApp.body must build no Window scene under isUnitTestHost")
    }
}
