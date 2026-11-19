import SwiftUI
import ArchiveCore

/// Settings › General (W47.settings-panels): Appearance and the setup questions, whose first page holds the starting points.
struct SettingsGeneralPanel: View {
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = AppAppearance.defaultValue
    @State private var showGeneralInterview = false

    var body: some View {
        Form {
            appearanceSection
        }
        .formStyle(.grouped)
    }

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("ap.settings.appearance")
            LabeledContent("This Mac and how you work") {
                Button("Answer the setup questions…") { showGeneralInterview = true }
            }
            .help("The questions asked at first start: what this Mac has, spending, how long a batch may run.")
        }
        .sheet(isPresented: $showGeneralInterview) { GeneralInterviewView { showGeneralInterview = false } }
    }
}
