import SwiftUI
import ArchiveCoreUI

/// The tags a search asks for, as chips with a remove button, and the suite's tag field to add more
/// (W40.fix-notes-tag-fields; owner session notes-2 rows 20 and 24: the filter bar's tag field was far too small and
/// neither it nor Advanced Search autocompleted, and Advanced Search kept its tags as plain words). The field is the
/// tag bar's `SubjectEntryField`: it suggests the tags already on notes, and Return or a comma adds what is typed and
/// keeps the keyboard for the next tag. The chips wrap (`FlowLayout`), so the field keeps its width however many tags
/// are chosen.
struct NoteTagChipsField: View {
    @Binding var tags: [String]
    @Binding var draft: String
    var placeholder: String = "Tag…"
    let identifier: String
    let chipIdentifier: String
    /// The tags to suggest, asked for when a completion is wanted.
    let suggestions: () -> [String]

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 3) {
            ForEach(tags, id: \.self) { chip($0) }
            SubjectEntryField(draft: $draft, placeholder: placeholder, identifier: identifier, fillsInAnyCase: true,
                              suggestions: { let chosen = Set(tags); return suggestions().filter { !chosen.contains($0) } },
                              onAdd: add)
                .frame(width: Self.fieldWidth)
        }
        .accessibilityElement(children: .contain)
    }

    /// Wide enough for a long tag ("Corporate Culture") and its filled-in completion.
    static let fieldWidth: CGFloat = 170

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text(tag).font(.caption).lineLimit(1)
            Button { tags.removeAll { $0 == tag } } label: {
                Image(systemName: "xmark").font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Remove \(tag)")
            .accessibilityLabel("Remove \(tag)")
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(chipIdentifier).\(tag)")
    }

    private func add(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        tags.append(tag)
    }

    /// The tags on notes, each in every spelling a note has (a search matches the spelling exactly in the filter
    /// bar), most used first, then by name.
    static func suggestions(in items: [ItemSummary]) -> [String] {
        var counts: [String: Int] = [:]
        for item in items {
            for tag in Set(item.managedTags) where !tag.trimmingCharacters(in: .whitespaces).isEmpty {
                counts[tag, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}
