// UITestLaunch.swift — how every Archive Reader UITest must build its app-under-test.
//
// W26.vmuitest-blind. For a day every Reader XCUITest in the Tart VM failed with *"The main Archive
// Reader window should appear within 10 seconds"*, and the app was blameless. Measured in the guest,
// 2026-08-10:
//
//   * the app-under-test is alive and has FINISHED launching — `sample` shows the main thread parked in
//     `-[NSApplication run]` → `_DPSNextEvent` → `mach_msg`, i.e. an idle event loop, not a hang;
//   * it carries NO `XCTest*` environment variable at all (`ps -Eww` on pid 1144), so
//     `ArchiveTestHost.isUnitTestHost` is FALSE and the unit-host window suppression — the hypothesis
//     this item was filed on — is NOT involved. `XCTestConfigurationFilePath` reaches only the
//     `ArchiveReaderUITests-Runner` process, where it is set to the empty string;
//   * the guest's unified log names the real cause outright:
//
//         [AppKit:StateRestoration] -[NSApplication _reopenWindowsAsNecessary…]
//             shouldRestoreState=1 hasPersistentStateToRestore=1 shouldStillRestoreStateAfterPrompting=1
//         [AppKit:AutomaticTermination] _NSEnableAutomaticTerminationAndLog(…) No windows open yet
//
// AppKit restored saved application state whose window set was EMPTY, so SwiftUI never opened the
// `Window("Archive Reader")` scene declared in `ArchiveReaderApp`. There is nothing for XCUITest to see:
// `windows == 0`, no Dock icon, the a11y Application element `Disabled`.
//
// WHY IT STAYS BROKEN. The state is self-perpetuating. A launch that restores "no windows" and is then
// terminated re-saves "no windows", so once any run leaves that state on the guest disk EVERY later
// launch is blind — including the `sighted` lane, which is a plain `open` and was measured landing in
// exactly the same place. That is what makes this an ops bug rather than a flake: every GUI check routed
// here by `ops/autonomous/resume-prompt.txt` STEP 3.5 fails for a reason that has nothing to do with the
// change under test.
//
// THE FIX. `-ApplePersistenceIgnoreState YES` tells AppKit to ignore that state for this launch. It is
// what Xcode itself already passes to the XCUITest runner — observed on the runner's own command line in
// the same VM (`-NSTreatUnknownArgumentsAsOpen NO -ApplePersistenceIgnoreState YES`). It was simply never
// passed to the app-under-test, which is the process that has to draw a window.
//
// The lane keeps a second, independent guard for the launches this file cannot reach (the `sighted`
// lane's `open`, or a hand-run app in the guest): `reader:prerun` in `ops/gui/tart-lib.sh` deletes the
// guest container's saved application state before each attempt. Two layers on purpose — this one
// travels with the tests and works on the host too; that one covers every launch in the VM.

import XCTest

enum UITestLaunch {

    /// Launch arguments every app-under-test needs so that a PREVIOUS run's window state cannot decide
    /// whether this run has a window at all.
    ///
    /// Always *prepend* these to a test's own arguments; never replace them.
    static let deterministicWindowState = ["-ApplePersistenceIgnoreState", "YES"]

    /// `deterministicWindowState` followed by `extra` — for the one call site that must *assign*
    /// `launchArguments` (it relaunches a fresh app mid-test) rather than append to them.
    static func arguments(_ extra: [String]) -> [String] {
        deterministicWindowState + extra
    }
}

extension XCUIApplication {

    /// The ONLY sanctioned way for an Archive Reader UITest to construct its app-under-test.
    ///
    /// A bare `XCUIApplication()` inherits whatever window state the last run left behind — see the file
    /// comment above. Guarded by `UITestLaunchTests` (the arguments) and
    /// `UITestLaunchSiteLintTests` in the unit bundle (the call sites).
    static func archiveUITestApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += UITestLaunch.deterministicWindowState
        return app
    }
}
