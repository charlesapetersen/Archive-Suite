import SwiftUI

/// Pieces the Advisor sheet (`SettingsAdvisorSheet`), its Range charts and Settings › Advanced share. Kept from the old
/// settings sheet (W46.settings-sheet) when the Advisor replaced it (W49.proc-settings-advisor-advanced).

/// The per-format editor for the one-page searchable form (W42.int-s5-compress), in Settings › Advanced.
struct SearchableFormatControls: View {
    let forms: SettingsSheetModel.FormsRow
    let setEntries: ([String]) -> Void
    @State private var format = "*"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Write as one searchable page, with no text page").padding(.top, 4)
            Text("Search and select the reading on the page image. If the words cannot be placed, search still works "
                 + "but selections may not line up. Handwritten, mixed and register pages keep their separate text page. "
                 + "Pages of unknown kind keep their text page if the handwriting check is inconclusive. "
                 + "Searchable images use less space when the compression tools are available.")
                .font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Text(forms.source).font(.caption2).foregroundStyle(.primary)
            Picker("Input format", selection: $format) {
                ForEach(SettingsSheetModel.FormsRow.formats, id: \.self) { value in
                    Text(value == "*" ? "All formats" : value.uppercased()).tag(value)
                }
            }
            .accessibilityIdentifier("ap.sheet.forms.format")
            if format != "*", forms.all || SettingsSheetModel.FormsRow.kinds.contains(where: { forms.inherited($0, format: format) }) {
                Text("Choices checked and dimmed here come from All formats.")
                    .font(.caption2).foregroundStyle(.primary)
            }
            Toggle("Every page, pages of no known kind too",
                   isOn: Binding(get: { forms.isOn(format: format) || forms.inherited(format: format) },
                                 set: { setEntries(forms.settingAll($0, format: format)) }))
                .disabled(forms.inherited(format: format))
                .accessibilityIdentifier("ap.sheet.forms.all")
            ForEach(SettingsSheetModel.FormsRow.kinds, id: \.self) { kind in
                Toggle(kind.label,
                       isOn: Binding(get: { forms.isOn(kind, format: format) || forms.inherited(kind, format: format) },
                                     set: { setEntries(forms.setting(kind, $0, format: format)) }))
                    .disabled(forms.inherited(kind, format: format))
                    .padding(.leading, 16)
                    .accessibilityIdentifier("ap.sheet.forms.\(kind.rawValue)")
            }
            if !forms.others.isEmpty {
                Text("Other settings file entries: " + forms.others.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.sheet.forms")
    }
}

/// A disclosure drawn as a button (W47.settings-panels): SwiftUI's `DisclosureGroup` triangle carries no accessibility
/// action, which the audit fails now that the sheet's boxes sit in Settings.
struct SheetDisclosure<Content: View>: View {
    let title: String
    let identifier: String?
    @ViewBuilder var content: () -> Content
    @State private var expanded = false

    init(_ title: String, identifier: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.identifier = identifier
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let identifier {
                disclosureButton.accessibilityIdentifier(identifier)
            } else {
                disclosureButton
            }
            if expanded { content().padding(.leading, 18) }
        }
    }

    private var disclosureButton: some View {
        Button { expanded.toggle() } label: {
            Label(title, systemImage: expanded ? "chevron.down" : "chevron.right")
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
    }
}

/// A titled box drawn in SwiftUI alone (a `GroupBox` draws nothing offscreen, so the self-test could not see it).
struct SheetBox<Title: View, Content: View>: View {
    @ViewBuilder var title: () -> Title
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title()
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}
