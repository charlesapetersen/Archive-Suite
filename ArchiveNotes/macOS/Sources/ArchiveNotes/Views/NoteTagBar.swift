import SwiftUI
import ArchiveCore

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
struct NoteTagBar: View {
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
    /// The tokens' laid-out height, so the bar is as tall as its lines up to `maxLines` and scrolls past them.
    @State private var tokensHeight: CGFloat = 0

    static let lineHeight: CGFloat = 22
    static let maxLines: CGFloat = 3

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Tags").font(.caption.weight(.semibold))
                .frame(height: Self.lineHeight)
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
            .frame(width: 180)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // A container, so the controls inside keep their own identifiers (an outer one replaced them).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("an.tagbar")
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

/// Lays its subviews out in rows, left to right, starting a new row when the next one does not fit: the tag bar's
/// tokens. Each subview is placed at its ideal size, cut to the width offered.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if width.isFinite { size.width = min(size.width, width) }
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
