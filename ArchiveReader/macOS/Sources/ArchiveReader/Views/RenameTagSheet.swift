import SwiftUI
import ArchiveCore

/// Corpus-wide tag rename (D1). Renames a subject tag on EVERY file that carries it, via the audited
/// `TagWriter` batch in `NavigationModel.renameTag` (one grouped undo). Shows the affected-file count
/// so the historian sees the blast radius before committing.
struct RenameTagSheet: View {
    @ObservedObject var model: NavigationModel
    let oldTag: String
    @State private var newTag: String
    /// Whether some file spells `oldTag` another way, so renaming it to itself still re-spells it. Worked out
    /// once when the sheet opens (a scan of the library), not on every keystroke.
    @State private var otherSpellings = false
    @Environment(\.dismiss) private var dismiss

    /// `initialNewName` pre-fills the field — used by the similar-tags finder to seed the chosen
    /// canonical when merging a variant into it. Defaults to empty so the plain rename call site is
    /// unchanged.
    init(model: NavigationModel, oldTag: String, initialNewName: String = "") {
        _model = ObservedObject(wrappedValue: model)
        self.oldTag = oldTag
        _newTag = State(initialValue: initialNewName)
    }

    private var count: Int { model.affectedFileCount(forTag: oldTag) }
    private var trimmedNew: String { newTag.trimmingCharacters(in: .whitespaces) }
    private var canRename: Bool {
        !trimmedNew.isEmpty && count > 0 && (trimmedNew != oldTag || otherSpellings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename tag").font(.headline)
            Text("Rename “\(oldTag)” to a new name on every file that carries it. Affects **\(count)** file\(count == 1 ? "" : "s"). Undoable as a single step.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("New name").frame(width: 80, alignment: .leading)
                TextField(oldTag, text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
                    .accessibilityIdentifier("ar.renameTag.newName")
            }
            // Tags that differ only in case are one tag. Renaming into another existing tag merges into its
            // spelling; a case-only rename of this tag changes its spelling on every file.
            if isSameTag(trimmedNew, oldTag), trimmedNew != oldTag || otherSpellings {
                Label("Changes the spelling of this tag on every file that carries it.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !isSameTag(trimmedNew, oldTag), let existing = model.librarySpelling(of: trimmedNew) {
                Label("“\(existing)” already exists: the files are merged into it, in that spelling.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename \(count) File\(count == 1 ? "" : "s")") { commit() }
                    .keyboardShortcut(.defaultAction).disabled(!canRename)
                    .accessibilityIdentifier("ar.renameTag.commit")
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { otherSpellings = model.hasOtherSpellings(of: oldTag) }
    }

    private func commit() {
        guard canRename else { return }
        model.renameTag(from: oldTag, to: trimmedNew)
        dismiss()
    }
}
