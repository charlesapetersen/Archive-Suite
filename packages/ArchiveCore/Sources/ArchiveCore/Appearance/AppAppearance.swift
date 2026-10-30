// AppAppearance.swift — the Appearance setting every app offers: System, Light or Dark (W48.appearance-*).
//
// One key and one helper for all three apps, so the choice reads and applies the same way in each. The value is
// stored in the app's own standard defaults under `defaultsKey`; `.system` (the default, and what an unknown or
// missing value reads as) leaves `NSApp.appearance` nil, so the app follows macOS as it always did.
//
// It is applied through `NSApplication.shared.appearance`, which every window, sheet, panel and AppKit-hosted view
// inherits, and SwiftUI's `colorScheme` follows it. `follow(_:)` applies the stored value at once and again on
// every change to the defaults, so a Settings picker bound to the key with `@AppStorage` changes every open window
// live, and the value is back before the first window on the next launch.

import AppKit

public enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    /// The defaults key, shared by Reader, Processor and Notes.
    public static let defaultsKey = "archiveAppearance"
    public static let defaultValue: AppAppearance = .system

    /// The label a Settings picker shows.
    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The appearance to set on `NSApp`; nil follows the system.
    public var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    /// The stored choice, `.system` when nothing (or something unrecognised) is stored.
    public static func stored(in defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? defaultValue
    }

    @MainActor
    public func apply(to app: NSApplication = .shared) {
        let target = appearanceName.flatMap(NSAppearance.init(named:))
        // Skip a no-op so a defaults change to some other key does not reset every window's appearance.
        guard app.appearance?.name != target?.name else { return }
        app.appearance = target
    }

    /// Applies the stored choice now and after every change to `defaults`. Call it once at launch, before the first
    /// window. Not called while a UI test forces the appearance (`-ArchiveUITestAppearance`), so the argument wins.
    @MainActor
    public static func follow(_ defaults: UserDefaults = .standard) {
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
