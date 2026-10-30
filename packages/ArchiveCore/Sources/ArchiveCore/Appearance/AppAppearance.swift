// AppAppearance.swift — the Appearance setting every app offers: System, Light or Dark (W48.appearance-*).
//
// One key and one value type for all three apps, so the choice reads the same way in each. The value is stored in
// the app's own standard defaults under `defaultsKey`; `.system` (the default, and what an unknown or missing value
// reads as) leaves `NSApp.appearance` nil, so the app follows macOS as it always did.
//
// Applying it needs AppKit, which ArchiveCore may not import (W9.c3, the write-surface lint's UI-import rule), so
// `apply` and `follow` live in each app's target, as the app-host window helper does: the Processor's is
// `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Models/AppAppearance+AppKit.swift`, the Notes's
// `ArchiveNotes/macOS/Sources/ArchiveNotes/Core/AppAppearance+AppKit.swift`.

import Foundation

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

    /// The stored choice, `.system` when nothing (or something unrecognised) is stored.
    public static func stored(in defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? defaultValue
    }
}
