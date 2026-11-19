import SwiftUI

/// Save the current filters and text search as a smart folder, under a name pre-filled from the active facets.
///
/// A sheet rather than the `.alert` with a `TextField` it was until W40.fix-reader-visual-polish: that alert
/// opened with the keyboard on Cancel, not the name field, so typing a name went nowhere. The focus is set one
/// main-queue turn after the sheet appears, for the reason `DocumentWindowView.focusFindField` gives: set in the
/// same update that inserts the field, it targets a field not yet in the window.
struct SaveSearchSheet: View {
    @ObservedObject var model: NavigationModel
    @State private var name: String
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: NavigationModel) {
        _model = ObservedObject(wrappedValue: model)
        _name = State(initialValue: model.suggestedSmartFolderName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Search").font(.headline)
            Text("Save the current filters and text search as a reusable smart folder.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { commit() }
                .accessibilityIdentifier("ar.saveSearch.name")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
                    .accessibilityIdentifier("ar.saveSearch.save")
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        model.saveCurrentSearch(name: trimmed)
        dismiss()
    }
}
