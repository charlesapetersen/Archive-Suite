import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore

extension Notification.Name {
    /// Posted when the API key changes in Settings, so the main window reloads it from the Keychain.
    static let apiKeyChanged = Notification.Name("APIKeyChanged")
}

/// A small clickable "?" that reveals an explanation in a popover (also shown on hover), so the
/// settings rows stay uncluttered.
struct HelpButton: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("Help")   // otherwise VoiceOver reads the symbol name (W40.fix-processor-a11y-labels)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

/// The app's durable settings, in the native Settings window (⌘,) as eight panels in the standard toolbar
/// (W47.settings-panels; `execution-plans/processing-review/settings-design/levels.md` §2). Each panel is one form and
/// owns its settings (`SettingsPanelOwnership`); Process Files' Tagging picker and segmentation chooser and the settings
/// sheet write the same `@AppStorage`/UserDefaults keys and layers as shortcuts, and say where the setting lives.
struct SettingsView: View {
    @State private var panel: SettingsPanel = .general

    var body: some View {
        TabView(selection: $panel) {
            ForEach(SettingsPanel.allCases) { p in
                content(p)
                    .frame(width: 720, height: p.height)
                    .accessibilityIdentifier("ap.settings.panel.\(p.rawValue)")
                    .tabItem { Label(p.title, systemImage: p.symbol) }
                    .tag(p)
            }
        }
    }

    @ViewBuilder private func content(_ p: SettingsPanel) -> some View {
        switch p {
        case .general: SettingsGeneralPanel()
        case .collection: SettingsCollectionPanel()
        case .reading: SettingsReadingPanel()
        case .documents: SettingsDocumentsPanel()
        case .datesAndNames: SettingsDatesNamesPanel()
        case .pagesAndOutput: SettingsPagesOutputPanel()
        case .capture: SettingsCapturePanel()
        case .accounts: SettingsAccountsPanel()
        }
    }
}

private extension SettingsPanel {
    /// Each panel's height: General's few rows sit in a short window, the panels with a stage card get room for it.
    var height: CGFloat {
        switch self {
        case .general:
            // Leave room below the longest wrapped Settings shown explanation.
            return 272
        case .capture, .accounts: return 560
        default: return 660
        }
    }
}

/// W40.fix-processor-settings-fields — in a grouped `Form` a `TextField`'s title becomes the row label and
/// the field itself draws borderless and right-aligned, so an empty field showed only its label (and a title
/// used as a placeholder landed, clipped, in the label column). Each text row puts its label on the left and
/// the field, bordered and with its placeholder inside, on the right; the field keeps its title as its
/// accessibility label.
struct SettingsField<Field: View>: View {
    let label: String
    @ViewBuilder var field: () -> Field

    init(_ label: String, @ViewBuilder field: @escaping () -> Field) {
        self.label = label
        self.field = field
    }

    var body: some View {
        LabeledContent(label) {
            field()
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(width: 260)
        }
    }
}
