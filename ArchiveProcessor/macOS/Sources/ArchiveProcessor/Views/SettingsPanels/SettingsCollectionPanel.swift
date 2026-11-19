import SwiftUI
import ArchiveCore

/// Settings › Collection (W47.settings-panels): the output folder as the collection, its project, interview and held
/// values, this batch's limits and totals, and the estimate for 1,000 files.
struct SettingsCollectionPanel: View {
    /// Where the keyboard focus starts when Settings opens: on the first real control, not a "?" button
    /// (W40.fix-processor-visual-polish: the help button held the focus ring on open).
    @FocusState private var initialFocus: CollectionSettingsSection.Focus?

    var body: some View {
        Form {
            CollectionSettingsSection(focus: $initialFocus)
            Section {
                SettingsStageCards(limits: true)
            } header: { Text("This batch") }
            Section {
                SettingsEstimateStrip()
            }
        }
        .formStyle(.grouped)
        .defaultFocus($initialFocus, .project)
    }

}
