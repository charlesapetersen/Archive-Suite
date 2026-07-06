import SwiftUI

/// Corpus-wide tag rename (D1). Renames a subject tag on EVERY file that carries it, via the audited
/// `TagWriter` batch in `NavigationModel.renameTag` (one grouped undo). Shows the affected-file count
/// so the historian sees the blast radius before committing.
struct RenameTagSheet: View {
    @ObservedObject var model: NavigationModel
    let oldTag: String
    @State private var newTag = ""
    @Environment(\.dismiss) private var dismiss

    private var count: Int { model.affectedFileCount(forTag: oldTag) }
    private var trimmedNew: String { newTag.trimmingCharacters(in: .whitespaces) }
    private var canRename: Bool { !trimmedNew.isEmpty && trimmedNew != oldTag && count > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename tag").font(.headline)
            Text("Rename “\(oldTag)” to a new name on every file that carries it. Affects **\(count)** file\(count == 1 ? "" : "s"). Undoable as a single step.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("New name").frame(width: 80, alignment: .leading)
                TextField(oldTag, text: $newTag).textFieldStyle(.roundedBorder).onSubmit { commit() }
            }
            if model.nearDuplicateSubjects(of: trimmedNew).isEmpty == false {
                Label("A tag differing only by case already exists.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename \(count) File\(count == 1 ? "" : "s")") { commit() }
                    .keyboardShortcut(.defaultAction).disabled(!canRename)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func commit() {
        guard canRename else { return }
        model.renameTag(from: oldTag, to: trimmedNew)
        dismiss()
    }
}
