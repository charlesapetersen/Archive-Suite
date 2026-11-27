import SwiftUI
import ArchiveCore

/// The shared Tags window (W40.tag-window-core; design: execution-plans/tag-rename-suite.md §"The Tags window").
/// Every subject tag in use with how many items carry it, searchable and sortable; Rename (into an existing tag it
/// merges), Merge of several selected into one spelling, Remove from every item after a confirmation that names the
/// count, Find Similar as a filter of the same list, and Show Items. The suite's own tokens are listed apart, read
/// only. `accessory` is an app's own section above the list (Tag Changes from Other Apps).
public struct TagsWindowView<Accessory: View>: View {
    @ObservedObject private var model: TagsWindowModel
    private let accessory: Accessory

    @State private var renaming: TagInventory.Entry?
    @State private var merging: [TagInventory.Entry] = []
    @State private var removing: TagChangePlan?
    @State private var showsSuiteTokens = false

    public init(model: TagsWindowModel, @ViewBuilder accessory: () -> Accessory) {
        self.model = model
        self.accessory = accessory()
    }

    public var body: some View {
        VStack(spacing: 0) {
            accessory
            controls
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 460, minHeight: 360)
        .sheet(item: $renaming) { entry in
            TagRenameSheet(model: model, entry: entry) { renaming = nil }
        }
        .sheet(isPresented: Binding(get: { !merging.isEmpty }, set: { if !$0 { merging = [] } })) {
            TagMergeSheet(model: model, entries: merging) { merging = [] }
        }
        .confirmationDialog(removing.map { $0.summary(noun: model.noun) + "?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { plan in
            Button("Remove from \(model.noun.count(plan.itemCount))", role: .destructive) {
                Task { await model.perform(plan) }
            }
            .accessibilityIdentifier("tags.remove.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The tag is taken off every \(model.noun.singular) that carries it. Edit ▸ Undo puts it back.")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("Search tags", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tags.search")
            Toggle("Find Similar", isOn: $model.similarOnly)
                .toggleStyle(.checkbox)
                .help("Only tags that look like a typo, spacing or case variant of another, grouped")
                .accessibilityIdentifier("tags.similar")
            Picker("Sort by", selection: $model.sort) {
                ForEach(TagsWindowModel.Sort.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .disabled(model.similarOnly)
            .accessibilityIdentifier("tags.sort")
        }
        .padding(10)
    }

    private var list: some View {
        let rows = model.rows
        return Table(rows, selection: $model.selection) {
            TableColumn("Tag") { entry in
                HStack(spacing: 6) {
                    if model.similarOnly, let group = model.similarGroup(of: entry) {
                        Text("\(group + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                    }
                    Text(entry.name)
                    if entry.hasVariantSpellings {
                        Text("also " + entry.spellings.dropFirst().map(\.tag).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityIdentifier("tags.row.\(entry.name)")
            }
            TableColumn(model.noun.plural.capitalized) { entry in
                Text("\(entry.itemCount)").monospacedDigit()
            }
            .width(min: 50, ideal: 70, max: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: entries(ids))
        } primaryAction: { ids in
            let picked = entries(ids)
            if picked.count == 1, let show = model.showItems { show(picked[0]) }
        }
        .overlay {
            if rows.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("tags.list")
    }

    @ViewBuilder
    private func menu(for picked: [TagInventory.Entry]) -> some View {
        if picked.count == 1 {
            Button("Rename…") { renaming = picked[0] }
            if let show = model.showItems { Button("Show \(model.noun.plural.capitalized)") { show(picked[0]) } }
        }
        if picked.count > 1 { Button("Merge \(picked.count) Tags…") { merging = picked } }
        if !picked.isEmpty {
            Button("Remove…") { removing = model.removePlan(picked) }
        }
    }

    private var emptyText: String {
        if model.inventory.subjects.isEmpty { return "No tags are in use." }
        if model.similarOnly { return "No tags look like variants of each other." }
        return "No tags match “\(model.search)”."
    }

    private var footer: some View {
        let picked = model.selectedEntries
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Rename…") { renaming = picked.first }
                    .disabled(picked.count != 1)
                    .accessibilityIdentifier("tags.rename")
                Button("Merge…") { merging = picked }
                    .disabled(picked.count < 2)
                    .accessibilityIdentifier("tags.merge")
                Button("Remove…") { removing = model.removePlan(picked) }
                    .disabled(picked.isEmpty)
                    .accessibilityIdentifier("tags.remove")
                if let show = model.showItems {
                    Button("Show \(model.noun.plural.capitalized)") { picked.first.map(show) }
                        .disabled(picked.count != 1)
                        .accessibilityIdentifier("tags.show")
                }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            .disabled(model.isWorking)
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("tags.status")
            }
            if !model.suiteTokens.isEmpty {
                DisclosureGroup("The suite’s own tags (\(model.suiteTokens.count))", isExpanded: $showsSuiteTokens) {
                    Text("Ratings, dates, read state, item types, colours and checks are set by the apps’ own "
                         + "controls and are not changed here.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.suiteTokens.map { "\($0.name) (\($0.itemCount))" }.joined(separator: " · "))
                        .font(.caption).textSelection(.enabled)
                }
                .font(.caption)
                .accessibilityIdentifier("tags.suiteTokens")
            }
        }
        .padding(10)
    }

    private func entries(_ ids: Set<String>) -> [TagInventory.Entry] {
        model.rows.filter { ids.contains($0.id) }
    }
}

extension TagsWindowView where Accessory == EmptyView {
    public init(model: TagsWindowModel) {
        self.init(model: model) { EmptyView() }
    }
}

/// Rename one tag. Into an existing tag it merges, in that tag's spelling; a case-only change re-spells it.
struct TagRenameSheet: View {
    @ObservedObject var model: TagsWindowModel
    let entry: TagInventory.Entry
    let done: () -> Void
    @State private var name: String

    init(model: TagsWindowModel, entry: TagInventory.Entry, done: @escaping () -> Void) {
        self.model = model
        self.entry = entry
        self.done = done
        _name = State(initialValue: entry.name)
    }

    private var plan: TagChangePlan? { model.renamePlan(entry, to: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename “\(entry.name)”").font(.headline)
            Text("Carried by \(model.noun.count(entry.itemCount)). Undoable as one step.")
                .foregroundStyle(.secondary)
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .accessibilityIdentifier("tags.rename.name")
            if let existing = model.existingTag(named: name, except: [entry]) {
                Label("“\(existing.name)” already exists: the \(model.noun.plural) are merged into it, in that spelling.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            } else if isSameTag(name.trimmingCharacters(in: .whitespacesAndNewlines), entry.name), plan != nil {
                Label("Changes the spelling of this tag on every \(model.noun.singular) that carries it.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            } else if TagInventory.isSuiteToken(name) {
                Label("That name is one of the suite’s own tags.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(plan.map { "Rename on \(model.noun.count($0.itemCount))" } ?? "Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil)
                    .accessibilityIdentifier("tags.rename.commit")
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func commit() {
        guard let plan else { return }
        done()
        Task { await model.perform(plan) }
    }
}

/// Merge several tags into one spelling: one of theirs, chosen from the list, or a name typed.
struct TagMergeSheet: View {
    @ObservedObject var model: TagsWindowModel
    let entries: [TagInventory.Entry]
    let done: () -> Void
    @State private var name: String

    init(model: TagsWindowModel, entries: [TagInventory.Entry], done: @escaping () -> Void) {
        self.model = model
        self.entries = entries
        self.done = done
        // The most carried one is the suggestion, as Find Similar Tags suggests it.
        _name = State(initialValue: entries.max { $0.itemCount < $1.itemCount }?.name ?? "")
    }

    private var plan: TagChangePlan? { model.mergePlan(entries, into: name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge \(entries.count) tags").font(.headline)
            Text("Every \(model.noun.singular) carrying one of them carries the name below instead. Undoable as one step.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries) { entry in
                    Button {
                        name = entry.name
                    } label: {
                        HStack {
                            Image(systemName: isSameTag(entry.name, name) ? "largecircle.fill.circle" : "circle")
                            Text(entry.name)
                            Text("\(entry.itemCount)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tags.merge.pick.\(entry.name)")
                }
            }
            TextField("Merged name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .accessibilityIdentifier("tags.merge.name")
            if let existing = model.existingTag(named: name, except: entries) {
                Label("“\(existing.name)” already exists: they are merged into it, in that spelling.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(plan.map { "Merge on \(model.noun.count($0.itemCount))" } ?? "Merge", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil)
                    .accessibilityIdentifier("tags.merge.commit")
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func commit() {
        guard let plan else { return }
        done()
        Task { await model.perform(plan) }
    }
}
