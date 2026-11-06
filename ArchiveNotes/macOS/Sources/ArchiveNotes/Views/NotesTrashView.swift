import SwiftUI

/// The per-window **Trash** (W40.fix-notes-delete-undo): shown in the item pane when the sidebar
/// "Trash" row is active. Lists every deleted note waiting in the store's `Trash/`, newest first,
/// with Put Back (home to the folders that held it) and Empty Trash (on to the Finder's Trash,
/// still recoverable there). Shape follows `TemplatesManagerView`.
struct NotesTrashView: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var nav: NotesNavigationModel

    @State private var selected: Set<UUID> = []
    @State private var confirmEmpty = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $selected) {
                ForEach(model.trashedNotes) { note in
                    HStack(spacing: 6) {
                        Image(systemName: note.kind == .extract ? "quote.opening" : "doc.text")
                            .foregroundStyle(.secondary)
                        Text(note.title.isEmpty ? "Untitled" : note.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(formerPlace(note)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(note.deletedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                            .font(.caption).monospacedDigit().foregroundStyle(.primary)
                    }
                    .tag(note.id)
                    .accessibilityIdentifier("an.trash.row")
                    .contextMenu {
                        Button("Put Back") { putBack(selected.contains(note.id) ? Array(selected) : [note.id]) }
                    }
                }
            }
            .overlay { if model.trashedNotes.isEmpty { emptyState } }
            Divider()
            bottomBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task { await model.reloadTrash() }
        .onChange(of: model.trashedNotes.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmEmpty) {
            Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
                .accessibilityIdentifier("an.trash.emptyConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = model.trashedNotes.count
            Text("\(n) note\(n == 1 ? "" : "s") will leave Archive Notes and go to the Finder's Trash, "
                 + "where they can still be recovered until the Finder's Trash is emptied.")
        }
    }

    private var header: some View {
        HStack {
            Text("Trash").font(.headline)
            Spacer()
            Text("Deleted notes wait here until you put them back or empty the Trash.")
                .font(.caption).foregroundStyle(.primary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var emptyState: some View {
        Text("The Trash is empty.")
            .font(.callout).foregroundStyle(.primary)
            .accessibilityIdentifier("an.trash.empty")
    }

    private var bottomBar: some View {
        HStack {
            Button("Put Back") { putBack(Array(selected)) }
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("an.trash.putBack")
            Spacer()
            Button("Empty Trash…") { confirmEmpty = true }
                .disabled(model.trashedNotes.isEmpty)
                .accessibilityIdentifier("an.trash.empty.button")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.bar)
    }

    /// Where Put Back files the note: its first former folder that still exists, else All Notes.
    private func formerPlace(_ note: TrashedNote) -> String {
        let names = note.formerFolderIds.compactMap { id in model.organization.folders.first { $0.id == id }?.name }
        guard let first = names.first else { return "All Notes" }
        return names.count == 1 ? first : "\(first) +\(names.count - 1)"
    }

    private func putBack(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        Task { _ = await model.putBack(ids) }
    }
}
