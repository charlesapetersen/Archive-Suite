// NotesAppearanceUITestDefaults.swift — W48.appearance-notes: keep one UI test's Appearance choice out of the next.
//
// The Appearance setting (ArchiveCore `AppAppearance`) persists in the app's own defaults, which the per-test fixture
// restore does not reach. So a fixture launch (`-ANUITestStorePath`) starts from System, as a fresh install does,
// unless it passes `-ANUITestKeepAppearance` (the relaunch check). Only the persisted value is removed: an
// argument-domain value (`-archiveAppearance dark`, the runner's "via the setting" passes) still reads through.

#if DEBUG
import ArchiveCore
import Foundation

enum NotesAppearanceUITestDefaults {
    static let keepArgument = "-ANUITestKeepAppearance"

    static func clearStoredChoiceIfUITest(arguments: [String] = ProcessInfo.processInfo.arguments,
                                          defaults: UserDefaults = .standard) {
        guard arguments.contains("-ANUITestStorePath"), !arguments.contains(keepArgument) else { return }
        defaults.removeObject(forKey: AppAppearance.defaultsKey)
    }
}
#endif
