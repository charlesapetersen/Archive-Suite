// ReaderUITestDefaults.swift — keep one UI test's stored choices out of the next.
//
// The Appearance setting (ArchiveCore `AppAppearance`, W48.appearance-reader) and the navigation window's two pane
// toggles (`ar.showSidebar`, `ar.showTagCloud`) persist in the app's own defaults, which nothing between UI tests
// resets. So a fixture launch (`-ARUITestRootPath`) starts as a fresh install does: System, the sidebar shown, the
// tag cloud closed. A test that stopped with the sidebar hidden hid it from every later test, so the folder and
// smart-folder rows they looked for were never there (W40.fix-reader-vm-suite-red). `-ARUITestKeepAppearance` keeps
// the Appearance choice (the relaunch check); the panes are reset on every fixture launch. Only the persisted value
// is removed: an argument-domain value (`-archiveAppearance dark`, the runner's "via the setting" passes;
// `-ar.showTagCloud YES` in the audits) still reads through. The Notes twin is `NotesAppearanceUITestDefaults`.

#if DEBUG
import ArchiveCore
import Foundation

enum ReaderUITestDefaults {
    static let keepArgument = "-ARUITestKeepAppearance"
    static let paneKeys = ["ar.showSidebar", "ar.showTagCloud"]

    static func clearStoredStateIfUITest(arguments: [String] = ProcessInfo.processInfo.arguments,
                                         defaults: UserDefaults = .standard) {
        guard arguments.contains("-ARUITestRootPath") else { return }
        for key in paneKeys { defaults.removeObject(forKey: key) }
        if !arguments.contains(keepArgument) { defaults.removeObject(forKey: AppAppearance.defaultsKey) }
    }
}
#endif
