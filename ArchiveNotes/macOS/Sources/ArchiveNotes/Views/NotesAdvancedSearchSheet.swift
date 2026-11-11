import SwiftUI
import AppKit
import ArchiveCore

/// The Advanced Search form (W40.notes-advanced-search), on the Reader's design: Finder-style rule rows under
/// "Match all/any of the following rules", each a field, an operator and a value, with − and + at the end of the
/// row and a group button for a nested all/any. It opens on the starter rows (text, tags, date) or on what the
/// list shows, and edits a smart folder in place. It only builds a `NotesAdvancedSearch` for the model.
struct NotesAdvancedSearchSheet: View {
    @ObservedObject var nav: NotesNavigationModel
    let request: NotesNavigationModel.AdvancedSearchRequest
    @State private var search: NotesAdvancedSearch
    @State private var matchCount: Int?
    @State private var naming = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(nav: NotesNavigationModel, request: NotesNavigationModel.AdvancedSearchRequest) {
        _nav = ObservedObject(wrappedValue: nav)
        self.request = request
        _search = State(initialValue: request.search)
    }

    private var editing: Bool { request.editingId != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing ? "Edit Smart Folder \u{201c}\(request.editingName)\u{201d}" : "Advanced Search")
                .font(.headline)
            HStack(spacing: 6) {
                Text("Match")
                Picker("Match", selection: $search.combine) {
                    Text("all").tag(RuleCombine.all)
                    Text("any").tag(RuleCombine.any)
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("an.advanced.combine")
                Text("of the following rules")
            }
            ScrollView {
                NotesRuleListView(rules: $search.rules, folders: folderChoices, depth: 0,
                                  tagSuggestions: { NoteTagChipsField.suggestions(in: nav.model.allItems) })
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 150, idealHeight: 260, maxHeight: 420)
            Text(countText)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("an.advanced.count")
            if naming {
                HStack {
                    TextField("Smart folder name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { saveAsSmartFolder() }
                        .accessibilityIdentifier("an.advanced.name")
                    Button("Save") { saveAsSmartFolder() }
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("an.advanced.saveNamed")
                }
            }
            HStack {
                Button("Clear") { search = .starter }
                    .help("Start again from the starter rows")
                    .accessibilityIdentifier("an.advanced.clear")
                Spacer()
                if !editing, !naming {
                    Button("Save as Smart Folder…") {
                        name = ""
                        naming = true
                        DispatchQueue.main.async { nameFocused = true }
                    }
                    .disabled(!search.isActive)
                    .accessibilityIdentifier("an.advanced.saveAs")
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing ? "Save" : "Search") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("an.advanced.search")
            }
        }
        .padding(18)
        .frame(minWidth: 760, idealWidth: 800)
        .task(id: search) {
            // A short pause, so typing a word runs one count, not one per key.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let n = await nav.countMatches(search)
            if !Task.isCancelled { matchCount = n }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var countText: String {
        guard let matchCount else { return "Counting…" }
        return matchCount == 1 ? "1 item matches" : "\(matchCount.formatted()) items match"
    }

    /// The normal folders, depth-first with their depth, for a folder rule's menu.
    private var folderChoices: [FolderChoice] {
        var out: [FolderChoice] = []
        func walk(_ nodes: [NotesFolderNode], _ depth: Int) {
            for n in nodes {
                out.append(FolderChoice(id: n.id, name: n.name, depth: depth))
                walk(n.children, depth + 1)
            }
        }
        walk(nav.model.normalTree, 0)
        return out
    }

    private func commit() {
        let s = search
        if let id = request.editingId {
            Task { await nav.updateSmartFolder(id, search: s) }
        } else {
            nav.runAdvancedSearch(s)
        }
        dismiss()
    }

    private func saveAsSmartFolder() {
        guard !trimmedName.isEmpty else { return }
        let s = search, n = trimmedName
        Task { await nav.saveAdvancedSearch(s, name: n) }
        dismiss()
    }
}

struct FolderChoice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let depth: Int
}

/// A list of rule rows; a group row holds another, indented.
private struct NotesRuleListView: View {
    @Binding var rules: [NotesSearchRule]
    let folders: [FolderChoice]
    let depth: Int
    let tagSuggestions: () -> [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rules) { $rule in
                NotesRuleRowView(rule: $rule, folders: folders, depth: depth, tagSuggestions: tagSuggestions,
                                 canRemove: rules.count > 1,
                                 onAdd: { add(after: rule.id, group: $0) },
                                 onRemove: { rules.removeAll { $0.id == rule.id } })
            }
        }
    }

    private func add(after id: UUID, group: Bool) {
        let new = group ? NotesSearchRule.group(.any, [NotesSearchRule(field: .text)]) : NotesSearchRule(field: .text)
        let i = rules.firstIndex { $0.id == id }.map { $0 + 1 } ?? rules.endIndex
        rules.insert(new, at: i)
    }
}

private struct NotesRuleRowView: View {
    @Binding var rule: NotesSearchRule
    let folders: [FolderChoice]
    let depth: Int
    let tagSuggestions: () -> [String]
    let canRemove: Bool
    let onAdd: (_ group: Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        if rule.field == .group {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Picker("Group", selection: $rule.combine) {
                        Text("Any").tag(RuleCombine.any)
                        Text("All").tag(RuleCombine.all)
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("an.advanced.group.combine")
                    Text("of the following are true")
                    Spacer(minLength: 8)
                    rowButtons
                }
                NotesRuleListView(rules: $rule.children, folders: folders, depth: depth + 1,
                                  tagSuggestions: tagSuggestions)
                    .padding(.leading, 22)
            }
        } else {
            HStack(spacing: 6) {
                Picker("Field", selection: fieldBinding) {
                    ForEach(NotesRuleField.allCases.filter { $0 != .group }, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("an.advanced.rule.field")
                Picker("Operator", selection: $rule.op) {
                    ForEach(rule.field.operators, id: \.self) { Text($0.label(for: rule.field)).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("an.advanced.rule.op")
                NotesRuleValueView(rule: $rule, folders: folders, tagSuggestions: tagSuggestions)
                    .frame(maxWidth: .infinity, alignment: .leading)
                rowButtons
            }
        }
    }

    /// Changing the field keeps the operator when the new field has it, else takes the field's first; the text
    /// is cleared when the new field reads it as something else.
    private var fieldBinding: Binding<NotesRuleField> {
        Binding(get: { rule.field }, set: { field in
            if field.textKind != rule.field.textKind { rule.text = ""; rule.text2 = "" }
            rule.field = field
            if !field.operators.contains(rule.op) { rule.op = field.operators[0] }
        })
    }

    private var rowButtons: some View {
        HStack(spacing: 2) {
            Button { onRemove() } label: { Image(systemName: "minus") }
                .disabled(!canRemove)
                .help("Remove this rule")
                .accessibilityIdentifier("an.advanced.remove")
            Button { onAdd(false) } label: { Image(systemName: "plus") }
                .help("Add a rule below")
                .accessibilityIdentifier("an.advanced.add")
            Button { onAdd(true) } label: { Image(systemName: "ellipsis") }
                .help("Add a group of rules below, with its own any or all")
                .accessibilityIdentifier("an.advanced.addGroup")
        }
        .controlSize(.small)
    }
}

/// The value part of a row, by field.
private struct NotesRuleValueView: View {
    @Binding var rule: NotesSearchRule
    let folders: [FolderChoice]
    let tagSuggestions: () -> [String]
    /// The tag being typed in a tags row, not yet a chip.
    @State private var tagDraft = ""


    /// A tags row's tags, chips one way and its comma-separated text the other; a tag already there in another
    /// case is not added again, as the rule matches tags in any case.
    private var tagsBinding: Binding<[String]> {
        Binding(get: { rule.tagList }, set: { new in
            var seen = Set<String>()
            rule.text = new.filter { seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
        })
    }
    var body: some View {
        switch rule.field {
        case .text, .noteText, .title, .authors:
            TextField(rule.op == .phrase ? "phrase" : (rule.field.isText ? "words" : "text"), text: $rule.text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: .infinity)
                .help(rule.field.isText
                      ? "Words separated by spaces; end a word with * to match its beginning (budg* finds budget)"
                      : (rule.field == .title ? "Part of the title" : "Part of an author's name"))
                .accessibilityIdentifier("an.advanced.rule.text")
        case .tags:
            // Chips and the suite's tag field (W40.fix-notes-tag-fields; owner session notes-2 row 24). The rule
            // keeps its tags as text separated by commas, which the field cannot type into a tag.
            NoteTagChipsField(tags: tagsBinding, draft: $tagDraft, placeholder: "Add tag…",
                              identifier: "an.advanced.rule.tags", chipIdentifier: "an.advanced.rule.tagChip",
                              suggestions: tagSuggestions)
                .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
        case .kind:
            Picker("Kind", selection: $rule.kind) {
                Text("a note").tag(Item.Kind.note)
                Text("an extract").tag(Item.Kind.extract)
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier("an.advanced.rule.kind")
        case .quality:
            HStack(spacing: 6) {
                ForEach([1, 2, 3, 0], id: \.self) { q in
                    Toggle(q == 0 ? "none" : "\(q)", isOn: Binding(
                        get: { rule.qualities.contains(q) },
                        set: { if $0 { rule.qualities.insert(q) } else { rule.qualities.remove(q) } }))
                    .toggleStyle(.checkbox)
                    .help(q == 0 ? "No quality" : "Quality \(q)")
                }
            }
        case .date:
            HStack(spacing: 6) {
                if rule.op != .undated {
                    dateField($rule.text, rule.op == .between ? "from" : "date")
                    if rule.op == .between {
                        Text("and")
                        dateField($rule.text2, "to")
                    }
                }
                Picker("Which date", selection: $rule.dateRole) {
                    Text("either date").tag(DateRoleChoice.either)
                    Text("own date").tag(DateRoleChoice.own)
                    Text("sent-with date").tag(DateRoleChoice.sentWith)
                }
                .labelsHidden().fixedSize()
                .help("The item's own date, the date of the letter it was sent with, or either")
            }
        case .folder:
            Picker("Folder", selection: $rule.folderId) {
                Text("Choose Folder").tag(Optional<UUID>.none)
                ForEach(folders) { f in
                    Text(String(repeating: "\u{2003}", count: f.depth) + f.name).tag(Optional(f.id))
                }
            }
            .labelsHidden().fixedSize()
            .help("The folder, or any folder inside it")
            .accessibilityIdentifier("an.advanced.rule.folder")
        case .uncertainDate, .roundup, .group:
            EmptyView()
        }
    }

    private func dateField(_ text: Binding<String>, _ prompt: String) -> some View {
        let bad = !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
            && AdvancedSearchText.dateKeys(text.wrappedValue) == nil
        return TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)
            .foregroundStyle(bad ? Color.red : Color.primary)
            .help("A year (1981), a month (1981-06), a day (1981-06-30) or a decade (1980s)")
            .accessibilityIdentifier("an.advanced.rule.date")
    }
}

extension NotesRuleField {
    var label: String {
        switch self {
        case .text: return "Any text"
        case .noteText: return "Note text"
        case .title: return "Title"
        case .authors: return "Authors"
        case .tags: return "Tags"
        case .kind: return "Kind"
        case .quality: return "Quality"
        case .date: return "Date"
        case .uncertainDate: return "Date uncertain"
        case .folder: return "Folder"
        case .roundup: return "Round-up note"
        case .group: return "Group"
        }
    }
}

extension RuleOperator {
    func label(for field: NotesRuleField) -> String {
        switch self {
        case .allWords: return "contains all of"
        case .phrase: return "contains the phrase"
        case .anyWords: return "contains any of"
        case .noWords: return "contains none of"
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .beginsWith: return "begins with"
        case .endsWith: return "ends with"
        case .hasAll: return "has all of"
        case .hasAny: return "has any of"
        case .hasNone: return "has none of"
        case .between: return "is between"
        case .after: return "is on or after"
        case .before: return "is on or before"
        case .undated: return "is missing"
        case .is, .isNot:
            let yes = self == .is
            switch field {
            case .quality: return yes ? "is one of" : "is none of"
            case .folder: return yes ? "is inside" : "is not inside"
            case .uncertainDate, .roundup: return yes ? "yes" : "no"
            default: return yes ? "is" : "is not"
            }
        }
    }
}
