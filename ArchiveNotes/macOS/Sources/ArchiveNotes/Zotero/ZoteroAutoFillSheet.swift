import SwiftUI

/// The mandatory final decision before Zotero metadata changes a note's durable front matter. Empty
/// fields are selected by default; replacements remain visibly opt-in on each individual field.
struct ZoteroAutoFillSheet: View {
    @ObservedObject var model: ZoteroAutoFillModel
    let dismiss: () -> Void
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Auto-fill from Zotero")
                .font(.title2.weight(.semibold))
                // Putting this on the containing VStack makes AppKit assign the identifier to every
                // descendant, hiding the individual confirmation controls from accessibility clients.
                .accessibilityIdentifier("an.zotero.autofill.sheet")
            if model.plan.changes.isEmpty {
                Text("The note's title, authors, and date already match Zotero. Applying will refresh its citation.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose which metadata changes to apply. Empty fields are selected; replacements require opt-in.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.plan.changes, id: \.field) { change in
                        Toggle(isOn: selection(for: change.field)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.field.displayName)
                                Text("\(display(change.currentDisplay)) → \(display(change.proposedDisplay))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("an.zotero.autofill.field.\(change.field.rawValue)")
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("an.zotero.autofill.error")
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("an.zotero.autofill.cancel")
                Button("Apply") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("an.zotero.autofill.apply")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func selection(for field: AutoFillField) -> Binding<Bool> {
        Binding(
            get: { model.isSelected(field) },
            set: { selected in if selected != model.isSelected(field) { model.toggle(field) } }
        )
    }

    private func confirm() {
        Task {
            do { try await model.confirm(); dismiss() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func display(_ value: String) -> String { value.isEmpty ? "(empty)" : value }
}

private extension AutoFillField {
    var displayName: String {
        switch self {
        case .title: "Title"
        case .authors: "Authors"
        case .date: "Date"
        }
    }
}
