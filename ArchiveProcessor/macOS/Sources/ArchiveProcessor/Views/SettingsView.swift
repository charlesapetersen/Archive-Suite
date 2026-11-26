import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore

extension Notification.Name {
    /// Posted when the API key changes in Settings, so the main window reloads it from the Keychain.
    static let apiKeyChanged = Notification.Name("APIKeyChanged")
}

/// A small clickable "?" that reveals an explanation in a popover (also shown on hover), so the
/// settings rows stay uncluttered. With a `handbook` section, the popover links to the long form of how a figure was
/// measured, which the redesign moved out of the window (W49.proc-settings-docs-tests-cleanup).
struct HelpButton: View {
    let text: String
    var handbook: Handbook.Section? = nil
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("Help")   // otherwise VoiceOver reads the symbol name (W40.fix-processor-a11y-labels)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let handbook {
                    Link("How this was measured", destination: handbook.url)
                        .font(.callout)
                        .accessibilityIdentifier("ap.help.handbook.\(handbook.rawValue)")
                }
            }
            .frame(width: 300, alignment: .leading)
            .padding(14)
        }
    }
}

/// The Settings Handbook: `ArchiveProcessor/REFERENCE.md` §"Settings Handbook" in the public repository, where the
/// measurements behind the Settings and Advisor figures are written out in full.
enum Handbook {
    static let base = "https://github.com/charlesapetersen/Archive-Suite/blob/main/ArchiveProcessor/REFERENCE.md"

    /// Each value is the section heading's anchor; `scripts/test-settings-tabs.sh` holds them to REFERENCE.md.
    enum Section: String, CaseIterable {
        case handbook = "settings-handbook"
        case reading = "reading-figures"
        case documentBreaks = "document-break-figures"
        case checking = "checking-time"
        case datesAndNames = "dates-and-names"
        case stages = "what-each-processing-stage-does"

        var url: URL { URL(string: "\(Handbook.base)#\(rawValue)")! }
    }
}

/// The app's durable settings, in the native Settings window (⌘,) as five tabs in the standard toolbar
/// (W49.proc-settings-redesign-core; `execution-plans/processor-settings-redesign.md` §5, Option B, approved by the owner
/// 2026-11-25). Every tab is one form at one window size, so the window never jumps; the tabs share one scope (general
/// defaults or the output folder's collection, `SettingsScopeModel`). Process Files' Tagging picker and segmentation
/// chooser write the same keys as shortcuts and say where the setting lives.
struct SettingsView: View {
    @State private var tab: SettingsTab = .processing
    @StateObject private var scope = SettingsScopeModel()
    @ObservedObject private var store = SettingsLayerStore.shared
    @AppStorage(DefaultsKeys.outputDirectory) private var outputPath: String = ""

    static let size = CGSize(width: 660, height: 620)

    var body: some View {
        TabView(selection: $tab) {
            ForEach(SettingsTab.allCases) { t in
                content(t)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .accessibilityIdentifier("ap.settings.panel.\(t.rawValue)")
                    .tabItem { Label(t.title, systemImage: t.symbol) }
                    .tag(t)
            }
        }
        .environmentObject(scope)
        .onChange(of: outputPath) { _, _ in scope.reload() }
        .onChange(of: store.collectionRevision) { _, _ in scope.reload() }
    }

    @ViewBuilder private func content(_ t: SettingsTab) -> some View {
        switch t {
        case .processing: SettingsProcessingTab(showAdvanced: { tab = .advanced })
        case .output: SettingsOutputTab()
        case .capture: SettingsCaptureTab()
        case .accounts: SettingsAccountsTab()
        case .advanced: SettingsAdvancedTab()
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
