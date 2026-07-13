import SwiftUI

/// Notes ⌘, Options — Zotero integration (05-zotero §D.8). `@AppStorage` binds directly to the
/// `ZoteroSettingsKey` defaults so edits persist immediately; the models resolve/validate those
/// raw values through `ZoteroSettings(reading:)` at point of use.
struct NotesSettingsView: View {
    @AppStorage(ZoteroSettingsKey.enabled) private var enabled = true
    @AppStorage(ZoteroSettingsKey.clipboardDetect) private var clipboardDetect = true
    @AppStorage(ZoteroSettingsKey.styleID) private var styleID = ZoteroSettings.defaultStyleID
    @AppStorage(ZoteroSettingsKey.host) private var host = ZoteroSettings.defaultHost
    @AppStorage(ZoteroSettingsKey.port) private var port = ZoteroSettings.defaultPort

    var body: some View {
        Form {
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
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                TextField("Host", text: $host, prompt: Text(ZoteroSettings.defaultHost))
                TextField("Port", value: $port, format: .number.grouping(.never))
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 340)
    }
}
