import SwiftUI

/// The Options panel (⌘,). Settings persist via `@AppStorage`; the models read them through
/// `AppSettings` at point of use, so changes take effect on the next action.
struct OptionsView: View {
    @AppStorage(SettingsKey.linkFormat) private var linkFormat: LinkFormat = .fileURL
    @AppStorage(SettingsKey.linkNewlines) private var linkNewlines: Int = 1
    @AppStorage(SettingsKey.copyCollapse) private var copyCollapse: Bool = true
    @AppStorage(SettingsKey.copyParagraph) private var copyParagraph: Bool = true
    @AppStorage(SettingsKey.copyDehyphenate) private var copyDehyphenate: Bool = true
    @AppStorage(SettingsKey.viewerSplit) private var viewerSplit: Double = 0.667
    @AppStorage(SettingsKey.subjectCombineAny) private var subjectCombineAny: Bool = false
    @AppStorage(SettingsKey.readFilterDefault) private var readFilterDefault: ReadFilter = .all
    @AppStorage(SettingsKey.warnNearDuplicate) private var warnNearDuplicate: Bool = true

    var body: some View {
        Form {
            Section("Copying links") {
                Picker("Link format", selection: $linkFormat) {
                    ForEach(LinkFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper(value: $linkNewlines, in: 0...5) {
                    Text("Blank lines between links: \(linkNewlines)")
                }
            }
            Section("Copying text") {
                Toggle("Collapse single line breaks into spaces", isOn: $copyCollapse)
                Toggle("Blank line = paragraph break", isOn: $copyParagraph)
                Toggle("Rejoin hyphenated line-splits (wel-/fare → welfare)", isOn: $copyDehyphenate)
            }
            Section("Document viewer") {
                VStack(alignment: .leading) {
                    Text("Default split: image \(Int(viewerSplit * 100))% / text \(Int((1 - viewerSplit) * 100))%")
                    Slider(value: $viewerSplit, in: 0.2...0.8)
                }
            }
            Section("Navigation defaults") {
                Picker("Default read-state filter", selection: $readFilterDefault) {
                    Text("All").tag(ReadFilter.all)
                    Text("Unread").tag(ReadFilter.unread)
                    Text("Read").tag(ReadFilter.read)
                    Text("No read-state").tag(ReadFilter.noReadState)
                }
                Toggle("Combine multiple subject filters with ANY (off = ALL)", isOn: $subjectCombineAny)
            }
            Section("Tag editing") {
                Toggle("Warn when a new subject differs only by case from an existing one", isOn: $warnNearDuplicate)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 520)
    }
}
