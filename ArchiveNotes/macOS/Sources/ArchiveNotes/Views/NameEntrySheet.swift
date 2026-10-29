import SwiftUI

/// The sheet behind every "give it a name" prompt (New / Rename Folder, New / Rename Template, Save as
/// Smart Folder). A SwiftUI `.alert` with a `TextField` left the focus ring on Cancel and the field
/// without a caret, so typing did nothing, and it offered its confirm button for an empty name
/// (W40.fix-notes-visual-polish). Here the field takes the caret as the sheet opens, Return confirms,
/// Escape cancels, and confirm is disabled until the trimmed name is non-empty.
struct NameEntrySheet: View {
    let title: String
    var message: String?
    let confirmLabel: String
    @Binding var name: String
    let onConfirm: (String) -> Void
    var onCancel: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let message { Text(message).font(.callout).foregroundStyle(.primary) }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($fieldFocused)
                .onSubmit(confirm)
                .accessibilityIdentifier("an.nameSheet.field")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        // A sheet's first responder is not settled until it is on screen; focusing in the same pass as
        // `onAppear` is dropped on macOS 14, so defer one turn.
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private func confirm() {
        guard !trimmed.isEmpty else { return }
        onConfirm(name)
        dismiss()
    }
}
