import SwiftUI
import ArchiveCore
import ArchiveCoreUI

/// The tags on a set of notes, for a multi-selection's inspector and context menu (W49.notes-multiselect-actions):
/// each tag once, in the form a save writes it (`NotesTagVocabulary.titleCased`, so "intel" on one note and "Intel"
/// on another are one tag), with how many of the notes have it, the tags on every note first, then by name.
enum NoteBulkTags {
    struct Entry: Equatable {
        let tag: String
        let count: Int
    }

    static func tags(in items: [ItemSummary]) -> [Entry] {
        var counts: [String: Int] = [:]
        for item in items {
            for tag in Set(item.managedTags.map(NotesTagVocabulary.titleCased)) where !tag.isEmpty {
                counts[tag, default: 0] += 1
            }
        }
        return counts.map { Entry(tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}

/// The inspector with several notes selected (W49.notes-multiselect-actions; it used to say only "N items selected"):
/// Quality and Tags for all of them at once. A Quality button sets every selected note; the tags shown are those on
/// any selected note, each with how many have it when not all do, and its ✕ takes it off every one; the field adds a
/// tag to every one on Return, as the tag bar's does. Each note is saved on its own through the same atomic
/// front-matter and Finder-mirror writes as a single note's edit, and the edits run one after another in the order
/// they were made. Delete is ⌘⌫ or the list's context menu.
struct NoteBulkInspector: View {
    @ObservedObject var nav: NotesNavigationModel
    @State private var draft = ""
    @State private var tail: Task<Void, Never>?

    var body: some View {
        let items = selectedItems
        let ids = items.map(\.id)
        VStack(alignment: .leading, spacing: 14) {
            Text("\(nav.selection.count) items selected")
                .font(.headline)
                .accessibilityIdentifier("an.bulk.count")
            qualitySection(items, ids: ids)
            tagsSection(items, ids: ids)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("an.inspector.bulk")
    }

    /// The selected notes, in list order.
    private var selectedItems: [ItemSummary] {
        let ordered = nav.exportableSelection
        let byID = Dictionary(nav.model.allItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ordered.compactMap { byID[$0] }
    }

    @ViewBuilder private func qualitySection(_ items: [ItemSummary], ids: [UUID]) -> some View {
        let qualities = Set(items.map(\.quality))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Quality").font(.subheadline.bold())
                if qualities.count > 1 {
                    Text("Mixed").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("an.bulk.quality.mixed")
                }
            }
            QualityFacetRow(quality: qualities.first ?? nil, isMixed: qualities.count > 1,
                            identifier: "an.bulk.quality") { q in
                enqueue { await nav.setQuality(q, for: ids) }
            }
        }
    }

    @ViewBuilder private func tagsSection(_ items: [ItemSummary], ids: [UUID]) -> some View {
        let tags = NoteBulkTags.tags(in: items)
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.subheadline.bold())
            if !tags.isEmpty {
                FlowLayout(spacing: 4, lineSpacing: 2) {
                    ForEach(tags, id: \.tag) { entry in
                        TagChip(entry.count == items.count ? entry.tag : "\(entry.tag) · \(entry.count)",
                                removeIdentifier: "an.bulk.tags.remove.\(entry.tag)") {
                            enqueue { await nav.removeTag(entry.tag, from: ids) }
                        }
                        .help(entry.count == items.count
                              ? "On every selected note. ✕ removes it from them all."
                              : "On \(entry.count) of the \(items.count) selected notes. ✕ removes it from them.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("an.bulk.tags.tokens")
            }
            SubjectEntryField(draft: $draft, placeholder: "Add tag to all…", identifier: "an.bulk.tags.input",
                              fillsInAnyCase: true,
                              suggestions: { Self.suggestions(excluding: tags, count: items.count, in: nav.model.allItems) },
                              onAdd: { raw in
                                  let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                                  guard !tag.isEmpty else { return }
                                  enqueue { await nav.addTag(tag, to: ids) }
                              })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("an.bulk.tags")
    }

    /// The tags on notes, most used first, less the ones every selected note already has.
    private static func suggestions(excluding tags: [NoteBulkTags.Entry], count: Int,
                                    in all: [ItemSummary]) -> [String] {
        let onAll = Set(tags.filter { $0.count == count }.map(\.tag))
        return NoteBulkTags.tags(in: all).map(\.tag).filter { !onAll.contains($0) }
    }

    /// Runs the edits one after another in the order they were made.
    private func enqueue(_ edit: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await edit()
        }
    }
}
