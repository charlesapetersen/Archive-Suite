// ReaderAppearanceUITestDefaults.swift — W48.appearance-reader: keep one UI test's Appearance choice out of the next.
//
// The Appearance setting (ArchiveCore `AppAppearance`) persists in the app's own defaults, which nothing between UI
// tests resets. So a fixture launch (`-ARUITestRootPath`) starts from System, as a fresh install does, unless it
// passes `-ARUITestKeepAppearance` (the relaunch check). Only the persisted value is removed: an argument-domain value
// (`-archiveAppearance dark`, the runner's "via the setting" passes) still reads through. The Notes twin is
// `NotesAppearanceUITestDefaults`.

#if DEBUG
import ArchiveCore
import Foundation

enum ReaderAppearanceUITestDefaults {
    static let keepArgument = "-ARUITestKeepAppearance"

    static func clearStoredChoiceIfUITest(arguments: [String] = ProcessInfo.processInfo.arguments,
                                          defaults: UserDefaults = .standard) {
        guard arguments.contains("-ARUITestRootPath"), !arguments.contains(keepArgument) else { return }
        defaults.removeObject(forKey: AppAppearance.defaultsKey)
    }
}
#endif
