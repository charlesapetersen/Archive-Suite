import SwiftUI
import ArchiveCore

/// Notes ⌘, Options — the Appearance choice (W48.appearance-notes), Zotero integration (05-zotero §D.8) and the display-calendar switch (W24.cal1-toggle). `@AppStorage` binds directly to the
/// `ZoteroSettingsKey` defaults so edits persist immediately; the models resolve/validate those
/// raw values through `ZoteroSettings(reading:)` at point of use.
struct NotesSettingsView: View {
    @AppStorage(ZoteroSettingsKey.enabled) private var enabled = true
    @AppStorage(ZoteroSettingsKey.clipboardDetect) private var clipboardDetect = true
    @AppStorage(ZoteroSettingsKey.styleID) private var styleID = ZoteroSettings.defaultStyleID
    @AppStorage(ZoteroSettingsKey.host) private var host = ZoteroSettings.defaultHost
    @AppStorage(ZoteroSettingsKey.port) private var port = ZoteroSettings.defaultPort
    @AppStorage(DisplayCalendarSettings.enabledKey) private var calendarsEnabled = false
    // Applied app-wide by `AppAppearance.follow()`, which watches this key (W48.appearance-notes).
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = AppAppearance.defaultValue

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("an.settings.appearance")
            }

            Section {
                Toggle("Enable Zotero integration", isOn: $enabled)
                Toggle("Detect Zotero links on the clipboard", isOn: $clipboardDetect)
                    .disabled(!enabled)
                TextField("Citation style ID", text: $styleID,
                          prompt: Text(ZoteroSettings.defaultStyleID))
                    .disabled(!enabled)
            } header: {
                Text("Zotero")
            } footer: {
                Text("Reads item metadata over Zotero's local API or Better BibTeX to auto-fill a "
                   + "note's author/date/title and a formatted citation. Attaching a link and opening "
                   + "a citation in Zotero work even when Zotero isn't running.")
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }

            Section("Advanced") {
                TextField("Host", text: $host, prompt: Text(ZoteroSettings.defaultHost))
                TextField("Port", value: $port, format: .number.grouping(.never))
            }
            .disabled(!enabled)

            // W24.cal1-toggle. Off by default; off, every date reads exactly as stored.
            Section {
                Toggle("Show dates in other calendars", isOn: $calendarsEnabled)
                    .accessibilityIdentifier("an.settings.calendars")
            } header: {
                Text("Dates")
            } footer: {
                Text("Lets each note choose a calendar (Julian, French Republican, Hebrew, Islamic…) "
                   + "for showing its dates. Dates are always stored in ISO 8601; choosing a calendar "
                   + "changes only how they are shown.")
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
        }
        .formStyle(.grouped)
        // Tall enough that the Dates footer, the last section, shows whole (W40.fix-notes-visual-polish), with
        // the Appearance row above Zotero (W48.appearance-notes).
        .frame(width: 460, height: 570)
    }
}
