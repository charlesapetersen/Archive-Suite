import SwiftUI

/// Settings rows shown by the user's level (W47.settings-level-switch, `levels.md` §3): drawn at their level and
/// above; below it, drawn only while their value differs from its default, then marked with their level and a Reset,
/// so a user never runs a setting they cannot see. An Advanced row says why it sits there when it is drawn. The rows
/// stay separate rows of the form they sit in (a container, not a modifier: a modifier on a `Group` would repeat
/// the note under every row).
struct SettingsLevelRows<Content: View>: View {
    let row: SettingsLevels.Row
    /// Read by the caller while it draws (its own `@AppStorage` redraws it when a value changes).
    let changed: Bool
    /// Puts the row back to its defaults; nil leaves the Reset out.
    let reset: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @AppStorage(DefaultsKeys.settingsLevel) private var levelRaw = SettingsLevel.defaultLevel.rawValue

    /// `changed` defaults to whether any of the row's stored keys differs from its default, read now, while the
    /// caller draws; `reset` to removing them.
    init(_ row: SettingsLevels.Row, changed: Bool? = nil, reset: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.row = row
        self.changed = changed ?? SettingsLevels.changed(row)
        self.reset = reset ?? (row.keys.isEmpty ? nil : { SettingsLevels.reset(row) })
        self.content = content
    }

    var body: some View {
        let current = SettingsLevel(rawValue: levelRaw) ?? .defaultLevel
        if current >= row.level {
            content()
            if row.level == .advanced, let why = row.why {
                Text("Advanced: \(why).")
                    .font(.caption2).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.settings.level.why.\(row.id)")
            }
        } else if changed {
            content()
            SettingsLevelChangedNote(level: row.level, rowID: row.id, reset: reset)
        }
    }
}

/// The line under a row shown above the user's level because its value is not the default.
struct SettingsLevelChangedNote: View {
    let level: SettingsLevel
    let rowID: String
    var reset: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("\(level.title) setting, changed from its default. Shown because it is in use.",
                  systemImage: "slider.horizontal.3")
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let reset {
                Button("Reset") { reset() }
                    .controlSize(.small)
                    .help("Puts this setting back to its default.")
                    .accessibilityIdentifier("ap.settings.level.reset.\(rowID)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.settings.level.changed.\(rowID)")
    }
}

/// A whole section (or block) drawn while any of its rows would be, so a level never leaves an empty heading.
struct SettingsLevelSection<Content: View>: View {
    let rows: [SettingsLevels.Row]
    let changed: Bool
    @ViewBuilder let content: () -> Content
    @AppStorage(DefaultsKeys.settingsLevel) private var levelRaw = SettingsLevel.defaultLevel.rawValue

    init(_ rows: [SettingsLevels.Row], changed: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.rows = rows
        self.changed = changed || rows.contains { SettingsLevels.changed($0) }
        self.content = content
    }

    var body: some View {
        let current = SettingsLevel(rawValue: levelRaw) ?? .defaultLevel
        if changed || rows.contains(where: { current >= $0.level }) { content() }
    }
}

extension View {
    /// Shows this one row by the user's level (`SettingsLevelRows`).
    func settingsLevel(_ row: SettingsLevels.Row, changed: Bool? = nil, reset: (() -> Void)? = nil) -> some View {
        SettingsLevelRows(row, changed: changed, reset: reset) { self }
    }
}
