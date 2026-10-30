// AppAppearance+AppKit.swift — applies ArchiveCore's Appearance setting to the app (W48.appearance-processor).
//
// The value type and its defaults key are in ArchiveCore; this half needs AppKit, which ArchiveCore may not import
// (W9.c3), so it lives in the app target. It is applied through `NSApplication.shared.appearance`, which every
// window, sheet, panel and AppKit-hosted view inherits, and SwiftUI's `colorScheme` follows it. `follow(_:)` applies
// the stored value at once and again on every change to the defaults, so a Settings picker bound to the key with
// `@AppStorage` changes every open window live, and the value is back before the first window on the next launch.

import AppKit
import ArchiveCore

extension AppAppearance {
    /// The appearance to set on `NSApp`; nil follows the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    @MainActor
    func apply(to app: NSApplication = .shared) {
        let target = appearanceName.flatMap(NSAppearance.init(named:))
        // Skip a no-op so a defaults change to some other key does not reset every window's appearance.
        guard app.appearance?.name != target?.name else { return }
        app.appearance = target
    }

    /// Applies the stored choice now and after every change to `defaults`. Call it once at launch, before the first
    /// window. Not called while a UI test forces the appearance (`-ArchiveUITestAppearance`), so the argument wins.
    @MainActor
    static func follow(_ defaults: UserDefaults = .standard) {
        stored(in: defaults).apply()
        guard observer == nil else { return }
        followed = defaults
        // queue nil, then a hop: a `.main` queue would make a background writer of any key wait on the main thread.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in
            Task { @MainActor in followed.map { stored(in: $0).apply() } }
        }
    }

    @MainActor private static var observer: NSObjectProtocol?
    @MainActor private static var followed: UserDefaults?
}
