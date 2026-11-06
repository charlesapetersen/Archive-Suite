import SwiftUI
import ArchiveCore

/// One subject per entry, so commas inside a subject need no ad-hoc escaping. Add/remove are deltas
/// against the actor's latest item, not replacements assembled from this view's potentially stale list.
///
/// The add field is the suite's shared tag field (`SubjectEntryField`, W40.fix-notes-tag-entry; owner session
/// notes-1 row 26): it autocompletes from the tags already on notes, and Return or a comma adds what is typed and
/// keeps the keyboard for the next tag. There is no Add button. Edits run one at a time in the order they were
/// made, so several tags typed in a row all land, and the field is never disabled while one saves (a disabled
/// field would lose the keyboard after every tag).
struct NoteTagsInspector: View {
    @ObservedObject var model: NotesModel
    let item: ItemSummary
    @State private var draft = ""
    private enum Edit: Equatable {
        case add(String), remove(String)
        var tag: String {
            switch self { case .add(let t), .remove(let t): NotesTagVocabulary.titleCased(t) }
        }
    }
    @State private var pending: [Edit] = []
    @State private var saving = false
    @State private var failedEdits: [Edit] = []

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
                                Button { enqueue(.remove(tag)) } label: {
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
            SubjectEntryField(draft: $draft, placeholder: "Add tag…", identifier: "an.detail.tags.input",
                              fillsInAnyCase: true,
                              suggestions: { Self.suggestions(for: item, in: model.allItems) },
                              onAdd: { enqueue(.add($0)) })
            if !failedEdits.isEmpty {
                HStack {
                    Text("Couldn't finish saving tags.").font(.caption).foregroundStyle(.red)
                    Button("Retry") { failedEdits.forEach(enqueue) }
                    .accessibilityIdentifier("an.detail.tags.retry")
                }
            }
        }
    }

    /// The tags on other notes, in the form a save would write them (`NotesTagVocabulary.titleCased`: a note's
    /// front matter may hold "intel" where another holds "Intel"), most used first, leaving out the ones `item` has.
    static func suggestions(for item: ItemSummary, in items: [ItemSummary]) -> [String] {
        let own = Set(item.managedTags.map(NotesTagVocabulary.titleCased))
        var counts: [String: Int] = [:]
        for other in items where other.id != item.id {
            for tag in Set(other.managedTags.map(NotesTagVocabulary.titleCased)) where !tag.isEmpty && !own.contains(tag) {
                counts[tag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    private func enqueue(_ edit: Edit) {
        if case .add(let tag) = edit, tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        // A later edit of the same tag supersedes a failed one, so Retry cannot put back a tag removed since.
        failedEdits.removeAll { $0.tag == edit.tag }
        pending.append(edit)
        drain()
    }

    /// Saves the queued edits in order. The view is keyed by the note (`NoteMetadataInspector`), so every edit in
    /// the queue is for `item`.
    private func drain() {
        guard !saving, !pending.isEmpty else { return }
        saving = true
        let id = item.id
        Task { @MainActor in
            while !pending.isEmpty {
                let edit = pending.removeFirst()
                // Replay the same idempotent delta whether the failed attempt saved YAML or not.
                let saved: Bool
                switch edit {
                case .add(let tag): saved = await model.addTag(tag, to: id)
                case .remove(let tag): saved = await model.removeTag(tag, from: id)
                }
                if !saved, !failedEdits.contains(edit) { failedEdits.append(edit) }
            }
            saving = false
        }
    }
}
