import SwiftUI

/// One subject per entry, so commas inside a subject need no ad-hoc escaping. Add/remove are deltas
/// against the actor's latest item, not replacements assembled from this view's potentially stale list.
struct NoteTagsInspector: View {
    @ObservedObject var model: NotesModel
    let item: ItemSummary
    @State private var draft = ""
    @State private var saving = false
    private enum Edit { case add(String), remove(String) }
    @State private var failedEdit: Edit?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.subheadline.bold())
            if !item.managedTags.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(item.managedTags, id: \.self) { tag in
                            HStack {
                                Text(tag).font(.caption).lineLimit(1)
                                Spacer()
                                Button { save(.remove(tag)) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(tag)")
                                .accessibilityLabel("Remove \(tag)")
                                .accessibilityIdentifier("an.detail.tags.remove.\(tag)")
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(item.managedTags.count) * 22, 66))
            }
            HStack {
                TextField("New tag", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("an.detail.tags.input")
                    .onSubmit { add() }
                Button("Add") { add() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("an.detail.tags.add")
            }
            if let failedEdit {
                HStack {
                    Text("Couldn't finish saving tags.").font(.caption).foregroundStyle(.red)
                    Button("Retry") { save(failedEdit) }
                        .accessibilityIdentifier("an.detail.tags.retry")
                }
            }
        }
        .disabled(saving)
    }

    private func add() {
        let tag = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        save(.add(tag))
    }

    private func save(_ edit: Edit) {
        guard !saving else { return }
        saving = true
        failedEdit = nil
        Task { @MainActor in
            // Replay the same idempotent delta whether the failed attempt saved YAML or not.
            let saved: Bool
            switch edit {
            case .add(let tag):
                saved = await model.addTag(tag, to: item.id)
                if saved { draft = "" }
            case .remove(let tag): saved = await model.removeTag(tag, from: item.id)
            }
            if !saved { failedEdit = edit }
            saving = false
        }
    }
}
