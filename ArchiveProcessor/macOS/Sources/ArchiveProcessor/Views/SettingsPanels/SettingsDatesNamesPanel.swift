import SwiftUI
import ArchiveCore

/// Settings › Dates and names (W47.settings-panels): the dating card and its switch, and the entities card.
struct SettingsDatesNamesPanel: View {
    var body: some View {
        Form {
            Section {
                SettingsStageCards(cards: ["dating", "entities"])
            } header: { Text("The app's picks") }
        }
        .formStyle(.grouped)
    }

}
