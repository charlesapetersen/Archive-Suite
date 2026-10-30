// UITestAppearance.swift — the APP-side half of the layout guard's dark pass (W40.e9). Compiled into each macOS
// app target (Reader, Notes, Processor) through its `project.yml`, DEBUG only.
//
// Why the app has to do it: `-AppleInterfaceStyle Dark` in the launch arguments does NOT darken a modern AppKit
// app — measured in the VM on 2026-10-11, the Notes window came up light with it — and the UI-test runner is
// sandboxed, so it cannot flip the guest's system appearance either. So the test passes
// `-ArchiveUITestAppearance dark|light` and the app sets its own `NSApp.appearance` before any window exists.
//
// Read from the process ARGUMENTS only, never from `UserDefaults`, so nothing persisted can ever change a real
// launch's appearance.

#if DEBUG
import AppKit

enum UITestAppearance {
    static let argument = "-ArchiveUITestAppearance"

    /// True when the argument forced an appearance; the app then leaves its stored Appearance setting
    /// (ArchiveCore `AppAppearance`) unapplied, so the light and dark tours keep their mode (W48.appearance-*).
    @MainActor @discardableResult
    static func applyIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        guard let i = arguments.firstIndex(of: argument), i + 1 < arguments.count else { return false }
        switch arguments[i + 1] {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: return false
        }
        return true
    }
}
#endif
