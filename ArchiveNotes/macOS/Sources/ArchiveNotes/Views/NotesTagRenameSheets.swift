import SwiftUI
import ArchiveCore

// MARK: - Tags ▸ Rename Tag…, Find Similar Tags… and Tag Changes from Other Apps… (W40.tag-rename-suite)
//
// The sheets only choose; every write is `NotesNavigationModel.renameSubjects` / `applyTagChange`: front matter
// first, then the Finder mirror, one Undo, recorded for the other apps (SPEC/tag-format.md invariant 8).

/// Which of the tag sheets a window shows.
enum NotesTagSheet: Identifiable, Equatable {
    case rename(from: String?, to: String)
    case similar
    case changes

    var id: String {
        switch self {
        case .rename(let from, let to): "rename-\(from ?? "")-\(to)"
        case .similar: "similar"
        case .changes: "changes"
        }
    }
}

/// Rename one subject on every note and extract that carries it; into an existing subject it merges.
struct NotesRenameTagSheet: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var nav: NotesNavigationModel
    @State private var from: String
    @State private var to: String
    /// The browser window's, not the sheet's own: Edit ▸ Undo Rename Tag belongs to the window.
    let undoManager: UndoManager?
    /// Back to the similar-tags list when it opened this sheet.
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool

    init(model: NotesModel, nav: NotesNavigationModel, from: String?, to: String, undoManager: UndoManager?,
         onDone: @escaping () -> Void = {}) {
        self.model = model
        self.nav = nav
        self.undoManager = undoManager
        self.onDone = onDone
        let subjects = model.subjectCounts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // The listed spelling of the seed, so the picker shows it selected whatever case the note's file holds.
        let seed = from.flatMap { f in subjects.first { tagKey($0) == tagKey(f) } }
        _from = State(initialValue: seed ?? subjects.first ?? "")
        _to = State(initialValue: to)
    }

    private var subjects: [String] {
        model.subjectCounts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var count: Int { model.notesCarrying(from).count }
    private var target: String? { model.subjectSpelling(for: to) }
    private var merges: Bool {
        guard let target else { return false }
        return tagKey(target) != tagKey(from) && model.subjectCounts.keys.contains { tagKey($0) == tagKey(target) }
    }
    private var canRename: Bool {
        guard let target, count > 0 else { return false }
        return tagKey(target) != tagKey(from) && !keepsExactCase(target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tag").font(.headline)
            if subjects.isEmpty {
                Text("No note or extract has a tag yet.").foregroundStyle(.secondary)
            } else {
                Picker("Tag", selection: $from) {
                    ForEach(subjects, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("an.renameTag.from")
                HStack {
                    Text("New name")
                    TextField(from, text: $to)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(commit)
                        .accessibilityIdentifier("an.renameTag.newName")
                }
                Text("Affects \(count) note\(count == 1 ? "" : "s") and extract\(count == 1 ? "" : "s"). "
                     + "Edit ▸ Undo puts them back in one step. The Reader is told, and asks before it renames its files.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if merges, let target {
                    Label("“\(target)” already exists: the notes are merged into it.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("an.renameTag.mergeNote")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss(); onDone() }.keyboardShortcut(.cancelAction)
                Button(merges ? "Merge" : "Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
                    .accessibilityIdentifier("an.renameTag.commit")
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }

    private func commit() {
        guard canRename else { return }
        let (old, new, undo) = (from, to, undoManager)
        dismiss()
        Task {
            await nav.renameSubjects([old], to: new, undo: undo)
            onDone()
        }
    }
}

/// Near-duplicate subjects (`TagSimilarity`, shared with the Reader), each group merged into the spelling chosen.
struct NotesSimilarTagsSheet: View {
    @ObservedObject var model: NotesModel
    /// Opens Rename Tag… on one variant, seeded with the chosen spelling.
    let merge: (_ variant: String, _ into: String) -> Void
    @State private var chosen: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    private var clusters: [[TagSimilarity.TagVariant]] { TagSimilarity.clusters(subjectCounts: model.subjectCounts) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Similar Tags").font(.headline)
            if clusters.isEmpty {
                Text("No tags look alike.").foregroundStyle(.secondary)
                    .accessibilityIdentifier("an.similarTags.none")
            } else {
                Text("Tags that may be one tag spelled differently. Choose the spelling to keep and merge the others into it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(clusters, id: \.first!.tag) { card($0) }
                    }
                }
                .frame(maxHeight: 360)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func card(_ cluster: [TagSimilarity.TagVariant]) -> some View {
        let key = cluster.first!.tag
        let keep = chosen[key] ?? key
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Keep", selection: Binding(get: { keep }, set: { chosen[key] = $0 })) {
                ForEach(cluster, id: \.tag) { Text("\($0.tag) (\($0.count))").tag($0.tag) }
            }
            ForEach(cluster.filter { $0.tag != keep }, id: \.tag) { variant in
                HStack {
                    Text("“\(variant.tag)” · \(variant.count) note\(variant.count == 1 ? "" : "s")")
                    Spacer()
                    Button("Merge into “\(keep)”…") { merge(variant.tag, keep) }
                        .accessibilityIdentifier("an.similarTags.merge")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}

/// Other apps' renames and merges, each applied to the notes or skipped; and undone ones Notes had applied.
struct NotesTagChangesSheet: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var nav: NotesNavigationModel
    /// The browser window's, not the sheet's own (see `NotesRenameTagSheet`).
    let undoManager: UndoManager?
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag Changes from Other Apps").font(.headline)
            if model.tagChangeOffers.isEmpty {
                Text("Nothing waiting. A tag renamed or merged in the Reader shows here, to apply to your notes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("an.tagChanges.none")
            } else {
                Text("Apply renames a tag on your notes as Rename Tag… would; Skip leaves them as they are. "
                     + "Either way it is not asked again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.tagChangeOffers) { row($0) }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                if model.tagChangeOffers.contains(where: { !$0.isWithdrawal }) {
                    Button("Apply All") { applyAll() }
                        .disabled(working)
                        .accessibilityIdentifier("an.tagChanges.applyAll")
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("an.tagChanges.done")
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func row(_ offer: TagChangeOffer) -> some View {
        HStack(alignment: .top) {
            Text(offer.summary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("an.tagChanges.summary")
            Spacer()
            if offer.isWithdrawal {
                Button("OK") { model.dismissTagChange(offer) }
            } else {
                Button("Skip") { model.dismissTagChange(offer) }
                    .disabled(working)
                    .accessibilityIdentifier("an.tagChanges.skip")
                Button("Apply") { apply([offer]) }
                    .disabled(working)
                    .accessibilityIdentifier("an.tagChanges.apply")
            }
        }
    }

    private func applyAll() { apply(model.tagChangeOffers.filter { !$0.isWithdrawal }) }

    private func apply(_ offers: [TagChangeOffer]) {
        working = true
        let undo = undoManager
        Task {
            for offer in offers { await nav.applyTagChange(offer, undo: undo) }
            working = false
        }
    }
}
