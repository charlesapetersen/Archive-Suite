// TestHostWindowSuppressionTests.swift — the unit suite must never draw on the owner's screen.
//
// `ArchiveNotesTests` is app-hosted (`TEST_HOST` = ArchiveNotes.app), so running it LAUNCHES the real
// app. Before 2026-07-30 that opened the Notes + Extracts windows and held focus for the whole suite
// (49s / 709 tests, measured from the health gate's .xcresult) — on every unattended daemon session
// and every health gate. `ArchiveTestHost` fixes it in two independent ways; this pins both, so a
// future edit to ArchiveNotesApp.swift can't silently put the windows back.
//
// Real GUI verification is NOT lost — it moved off-screen into the Tart VM
// (ops/gui/vm-gui-runner.sh, ops/gui/README.md §3), which is the only sanctioned lane for it.

import Testing
import AppKit
import ArchiveCore
@testable import ArchiveNotes

@Suite("Test-host window suppression — the unit suite draws nothing")
struct TestHostWindowSuppressionTests {

    /// Sanity: these assertions are only meaningful because we really are the injected host.
    @Test("running as the injected unit-test host")
    func runningAsUnitTestHost() {
        #expect(ArchiveTestHost.isUnitTestHost,
                "XCTestConfigurationFilePath must be set in the unit-test host process")
    }

    /// Guard 1 — the process is demoted, so it owns no Dock icon and cannot steal focus.
    @Test("activation policy is .prohibited") @MainActor
    func activationPolicyIsProhibited() {
        #expect(NSApplication.shared.activationPolicy() == .prohibited,
                "ArchiveNotesApp.init() must call ArchiveTestHost.suppressWindowsIfUnitTestHost()")
    }

    /// Guard 2 — no window scene was built, so nothing is on screen for anyone to see.
    @Test("no visible windows") @MainActor
    func noVisibleWindows() {
        let visible = NSApplication.shared.windows.filter(\.isVisible)
        #expect(visible.isEmpty,
                "unit-test host showed \(visible.count) window(s) \(visible.map(\.title)) — every auto-opening Window scene in ArchiveNotesApp must render ArchiveTestHost.HiddenWindowStub under isUnitTestHost")
    }
}
