// UITestLaunch.swift — how every Archive Notes UITest must build its app-under-test.
//
// W26.vmuitest-blind. The Notes half of the same fault the Reader hit, and it has to be fixed here too
// because the seam is per-bundle: `XCUIApplication` is constructed by the test, so nothing in ArchiveCore
// or the ops lane can supply this argument on the tests' behalf.
//
// WHAT GOES WRONG. XCUITest launches the app-under-test WITHOUT `-ApplePersistenceIgnoreState`, even
// though Xcode passes that very flag to its own test RUNNER — both were read off `ps` in the guest on
// 2026-08-10:
//
//     …/ArchiveNotesUITests-Runner.app/…/ArchiveNotesUITests-Runner -NSTreatUnknownArgumentsAsOpen NO \
//                                                                   -ApplePersistenceIgnoreState YES
//     …/ArchiveNotes.app/Contents/MacOS/ArchiveNotes -ANUITestStorePath /Users/admin/…/AN-GUI-Fixture
//
// So AppKit restores the app's saved window state, and when that state says "no windows were open",
// SwiftUI never opens the `Window` scene at all:
//
//     [AppKit:StateRestoration] -[NSApplication _reopenWindowsAsNecessary…]
//         shouldRestoreState=1 hasPersistentStateToRestore=1
//     [AppKit:AutomaticTermination] _NSEnableAutomaticTerminationAndLog(…) No windows open yet
//
// The app is healthy — measured the same minute, `CGWindowListCopyWindowInfo` showed **zero** windows
// under XCUITest and the full-size window under a plain `open` of the same build. Every window assertion
// in the bundle then fails as *"Main window should appear"*, which reads exactly like a product bug.
//
// AND IT IS SELF-PERPETUATING: a launch that restores "no windows" and is then terminated SAVES "no
// windows", so once any run leaves that state behind, every later launch is blind.
//
// `notes:prerun` in `ops/gui/tart-lib.sh` wipes this app's container before each attempt, which does
// clear the saved state — but only for the FIRST launch of a run. Each test launches and terminates the
// app again, so the second test onwards inherits whatever the first one saved. The container wipe is
// therefore not a substitute for this flag; it is why Notes looked intermittent while Reader (which has
// no prerun at all) looked permanently broken.
//
// Note the two faults were independent and BOTH had to be fixed: this one, and a guest Accessibility
// grant that had stopped being honoured (→ `ops/gui/vm-check-accessibility.swift`). Either alone still
// produces "Main window should appear" for every test, which is why fixing one and re-running looked
// like no progress at all.

import XCTest

enum UITestLaunch {

    /// Launch arguments every app-under-test needs so that a PREVIOUS run's window state cannot decide
    /// whether this run has a window at all.
    ///
    /// Always *prepend* these to a test's own arguments; never replace them.
    static let deterministicWindowState = ["-ApplePersistenceIgnoreState", "YES"]

    /// `deterministicWindowState` followed by `extra` — for a call site that must *assign*
    /// `launchArguments` (relaunching a fresh app mid-test) rather than append to them.
    static func arguments(_ extra: [String]) -> [String] {
        deterministicWindowState + extra
    }
}

extension XCUIApplication {

    /// The ONLY sanctioned way for an Archive Notes UITest to construct its app-under-test.
    ///
    /// A bare `XCUIApplication()` inherits whatever window state the last run left behind — see the file
    /// comment above. Guarded by `UITestLaunchTests`.
    static func archiveUITestApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += UITestLaunch.deterministicWindowState
        return app
    }
}
