import SwiftUI

/// The Options panel (⌘,). Scaffolding for now.
/// M3 populates: link format, newlines-after-link, copy behavior (de-hyphenate, single-newline
/// handling, skip-OCR-header), viewer defaults (split ratio, zoom), list defaults, tag-editing prefs.
struct OptionsView: View {
    var body: some View {
        Form {
            Section("Options") {
                Text("Foundation scaffold — settings arrive in M3.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 260)
    }
}

#Preview {
    OptionsView()
}
