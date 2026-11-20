import SwiftUI
import ArchiveCore

/// Settings › General (W47.settings-panels): Appearance, the level (W47.settings-level-switch) and the setup questions,
/// whose first page holds the starting points.
struct SettingsGeneralPanel: View {
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = AppAppearance.defaultValue
    @AppStorage(DefaultsKeys.settingsLevel) private var level: SettingsLevel = SettingsLevel.defaultLevel
    @State private var showGeneralInterview = false

    var body: some View {
        Form {
            appearanceSection
            levelSection
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

    private var levelSection: some View {
        Section {
            SettingsLevelPicker(level: $level)
        } header: { Text("How much you adjust") }
    }
}

/// The three levels as one choice, with what the chosen one shows (Settings › General and the setup questions' last
/// question). A level only hides rows: it never changes a value, a default or the app's picks.
struct SettingsLevelPicker: View {
    @Binding var level: SettingsLevel

    var body: some View {
        Picker("Settings shown", selection: $level) {
            ForEach(SettingsLevel.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("ap.settings.level")
        Text(level.detail + " A setting you have changed is always shown, with its Reset, whatever the level.")
            .font(.caption).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ap.settings.level.detail")
    }
}
