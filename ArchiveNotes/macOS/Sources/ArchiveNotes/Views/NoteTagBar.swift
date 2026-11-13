import SwiftUI
import ArchiveCore
import ArchiveCoreUI

/// The tag bar under the note's editor (W40.notes-detail-layout; owner session notes-1 row 23: "'Tags' should
/// appear in a separate editing pane below the note, not in the Inspector or in Details"). The tags show as tokens
/// with a remove button, wrapping to at most `maxLines` lines and then scrolling inside the bar, so the editor keeps
/// its height; the add field sits at the bar's end.
///
/// One subject per entry, so commas inside a subject need no ad-hoc escaping. Add/remove are deltas
/// against the actor's latest item, not replacements assembled from this view's potentially stale list.
///
/// The add field is the suite's shared tag field (`SubjectEntryField`, W40.fix-notes-tag-entry; owner session
/// notes-1 row 26): it autocompletes from the tags already on notes, and Return or a comma adds what is typed and
/// keeps the keyboard for the next tag. There is no Add button. Edits run one at a time in the order they were
/// made, so several tags typed in a row all land, and the field is never disabled while one saves (a disabled
/// field would lose the keyboard after every tag).
///
/// `inInspector` lays the same editor out for the inspector, the field under the tokens: with the bar hidden (View ▸
/// Hide Tag Bar, W40.notes-window-panes; owner, notes-2 row 22) the inspector shows it, so tagging stays possible.
struct NoteTagBar: View {
    @ObservedObject var model: NotesModel
    let item: ItemSummary
    var inInspector = false
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
    /// The tokens' laid-out height, so the bar is as tall as its lines up to `maxLines` and scrolls past them.
    @State private var tokensHeight: CGFloat = 0

    static let lineHeight: CGFloat = 22
    static let maxLines: CGFloat = 3

    var body: some View {
        if inInspector {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tags").font(.caption.weight(.semibold))
                if !item.managedTags.isEmpty { tokens }
                entry
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("an.inspector.tags")
        } else {
            bar
        }
    }

    private var bar: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Tags").font(.caption.weight(.semibold))
                .frame(height: Self.lineHeight)
            tokens
            entry
                .frame(width: 180)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // A container, so the controls inside keep their own identifiers (an outer one replaced them).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("an.tagbar")
    }

    private var tokens: some View {
        ScrollView(.vertical) {
            FlowLayout(spacing: 4, lineSpacing: 2) {
                ForEach(item.managedTags, id: \.self) { tag in token(tag) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tokensHeight = $0 }
        }
        .scrollIndicators(.automatic)
        .frame(height: max(Self.lineHeight, min(tokensHeight, Self.lineHeight * Self.maxLines + 4)))
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("an.tagbar.tokens")
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 2) {
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

    private func token(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text(tag).font(.caption).lineLimit(1)
            Button { enqueue(.remove(tag)) } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Remove \(tag)")
            .accessibilityLabel("Remove \(tag)")
            .accessibilityIdentifier("an.detail.tags.remove.\(tag)")
        }
        .padding(.horizontal, 7)
        .frame(height: Self.lineHeight - 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
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

    /// What the list's Tags cell does when its tags are edited in place (W40.notes-detail-layout): the tags to add
    /// and to remove, each once, in the form a save writes them, comparing case-insensitively, so retyping a tag in
    /// another case changes nothing.
    static func edits(from edited: [String], current: [String]) -> (add: [String], remove: [String]) {
        func key(_ t: String) -> String { NotesTagVocabulary.titleCased(t).lowercased() }
        var seen = Set<String>(), wanted: [String] = []
        for raw in edited {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(key(tag)).inserted else { continue }
            wanted.append(tag)
        }
        let have = Set(current.map(key))
        return (wanted.filter { !have.contains(key($0)) }, current.filter { !seen.contains(key($0)) })
    }

    private func enqueue(_ edit: Edit) {
        if case .add(let tag) = edit, tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        // A later edit of the same tag supersedes a failed one, so Retry cannot put back a tag removed since.
        failedEdits.removeAll { $0.tag == edit.tag }
        pending.append(edit)
        drain()
    }

    /// Saves the queued edits in order. The view is keyed by the note (`DetailPane`), so every edit in the queue is
    /// for `item`.
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
