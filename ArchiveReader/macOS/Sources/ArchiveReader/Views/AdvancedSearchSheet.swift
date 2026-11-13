import SwiftUI
import AppKit
import ArchiveCore

/// The Advanced Search form (W40.reader-advanced-search): Finder-style rule rows under "Match all/any of the
/// following rules", each a field, an operator and a value, with + and − at the end of the row and a group button
/// for a nested all/any. It opens on the starter rows (OCR text, tags, date) or on what the list shows, and edits
/// a smart folder in place. Read-only over the corpus: it only builds an `AdvancedSearch` for the model.
struct AdvancedSearchSheet: View {
    @ObservedObject var model: NavigationModel
    let request: AdvancedSearchRequest
    /// The rules as edited, held by the request (W40.fix-reader-advanced-many-rules): view state would fall back
    /// to the opening rules whenever the sheet is presented again.
    @ObservedObject private var draft: AdvancedSearchDraft
    /// A row just added, to scroll into view.
    @State private var revealRule: UUID?
    @State private var matchCount: Int?
    @State private var naming = false
    @State private var confirmingSaveTo = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: NavigationModel, request: AdvancedSearchRequest) {
        _model = ObservedObject(wrappedValue: model)
        self.request = request
        _draft = ObservedObject(wrappedValue: request.draft)
    }

    private var editing: SavedSearch? { request.editing }
    private var origin: SavedSearch? { request.origin }
    private var search: AdvancedSearch { draft.search }

    /// Tall enough for every row up to the cap, so the list grows as rules are added before it scrolls.
    private var listHeight: CGFloat {
        func rows(_ rules: [SearchRule]) -> Int { rules.reduce(0) { $0 + 1 + ($1.field == .group ? rows($1.children) : 0) } }
        return min(420, max(150, CGFloat(rows(search.rules)) * 30 + 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editing.map { "Edit Smart Folder \u{201c}\($0.name)\u{201d}" } ?? "Advanced Search").font(.headline)
            HStack(spacing: 6) {
                Text("Match")
                Picker("Match", selection: $draft.search.combine) {
                    Text("all").tag(RuleCombine.all)
                    Text("any").tag(RuleCombine.any)
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("ar.advanced.combine")
                Text("of the following rules")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    RuleListView(rules: $draft.search.rules, model: model, depth: 0, onAdded: { revealRule = $0 })
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: revealRule) { _, id in
                    guard let id else { return }
                    // After the layout that holds the new row.
                    DispatchQueue.main.async { proxy.scrollTo(id); revealRule = nil }
                }
            }
            .frame(minHeight: 150, idealHeight: listHeight, maxHeight: 420)
            .accessibilityIdentifier("ar.advanced.rules")
            Text(countText)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ar.advanced.count")
            if naming {
                HStack {
                    TextField("Smart folder name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { saveAsSmartFolder() }
                        .accessibilityIdentifier("ar.advanced.name")
                    Button("Save") { saveAsSmartFolder() }
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("ar.advanced.saveNamed")
                }
            }
            HStack {
                Button("Clear") { draft.search = .starter }
                    .help("Start again from the starter rows")
                    .accessibilityIdentifier("ar.advanced.clear")
                Spacer()
                if editing == nil, !naming {
                    Button(origin == nil ? "Save as Smart Folder…" : "Save as New Smart Folder…") {
                        name = ""
                        naming = true
                        DispatchQueue.main.async { nameFocused = true }
                    }
                    .disabled(!search.isActive)
                    .accessibilityIdentifier("ar.advanced.saveAs")
                }
                if let origin, !naming {
                    Button("Save to \u{201c}\(origin.name)\u{201d}") { confirmingSaveTo = true }
                        .disabled(!search.isActive || search == origin.search)
                        .help("Replace this smart folder's rules with these")
                        .accessibilityIdentifier("ar.advanced.saveTo")
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Search" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ar.advanced.search")
            }
        }
        .padding(18)
        .frame(minWidth: 880, idealWidth: 900)
        .alert(origin.map { SmartFolderReplace.title($0.name) } ?? "", isPresented: $confirmingSaveTo) {
            Button("Replace") { saveToOrigin() }.accessibilityIdentifier("ar.advanced.saveTo.replace")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SmartFolderReplace.message)
        }
        .task(id: search) {
            // A short pause, so typing a word runs one count, not one per key. The next edit cancels this count.
            let search = search
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let n = await model.countMatches(search)
            if !Task.isCancelled { matchCount = n }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var countText: String {
        guard let matchCount else { return "Counting…" }
        return matchCount == 1 ? "1 document matches" : "\(matchCount.formatted()) documents match"
    }

    private func commit() {
        model.commitAdvancedSearch(request)
        dismiss()
    }

    private func saveAsSmartFolder() {
        guard !trimmedName.isEmpty else { return }
        model.saveAdvancedSearch(search, name: trimmedName)
        dismiss()
    }

    private func saveToOrigin() {
        guard let origin else { return }
        model.saveToSmartFolder(origin.id, search: search)
        dismiss()
    }
}

/// The question Save to "<name>" asks before it replaces a smart folder's rules (W40.reader-smart-folder-update).
/// It asks rather than offering undo: the store keeps no history and the window's undo stack is the text fields'
/// (`TextUndoGuard`), so an undo entry there would sit among typing steps.
enum SmartFolderReplace {
    static func title(_ name: String) -> String { "Replace the rules of \u{201c}\(name)\u{201d}?" }
    static let message = "The smart folder will match these rules from now on. Its old rules are not kept."
}

/// A list of rule rows; a group row holds another, indented.
private struct RuleListView: View {
    @Binding var rules: [SearchRule]
    @ObservedObject var model: NavigationModel
    let depth: Int
    let onAdded: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rules) { $rule in
                RuleRowView(rule: $rule, model: model, depth: depth,
                            canRemove: rules.count > 1,
                            onAdd: { onAdded(rules.insertRule(after: rule.id, group: $0)) },
                            onRemove: { rules.removeAll { $0.id == rule.id } },
                            onAdded: onAdded)
                    .id(rule.id)
            }
        }
    }
}

private struct RuleRowView: View {
    @Binding var rule: SearchRule
    @ObservedObject var model: NavigationModel
    let depth: Int
    let canRemove: Bool
    let onAdd: (_ group: Bool) -> Void
    let onRemove: () -> Void
    let onAdded: (UUID) -> Void

    var body: some View {
        if rule.field == .group {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Picker("Group", selection: $rule.combine) {
                        Text("Any").tag(RuleCombine.any)
                        Text("All").tag(RuleCombine.all)
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("ar.advanced.group.combine")
                    Text("of the following are true")
                    Spacer(minLength: 8)
                    rowButtons
                }
                RuleListView(rules: $rule.children, model: model, depth: depth + 1, onAdded: onAdded)
                    .padding(.leading, 22)
            }
        } else {
            HStack(spacing: 6) {
                Picker("Field", selection: fieldBinding) {
                    ForEach(RuleField.allCases.filter { $0 != .group }, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("ar.advanced.rule.field")
                Picker("Operator", selection: $rule.op) {
                    ForEach(rule.field.operators, id: \.self) { Text($0.label(for: rule.field)).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("ar.advanced.rule.op")
                RuleValueView(rule: $rule, model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                rowButtons
            }
        }
    }

    /// Changing the field keeps the operator when the new field has it, else takes the field's first.
    private var fieldBinding: Binding<RuleField> {
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
                .accessibilityIdentifier("ar.advanced.remove")
            Button { onAdd(false) } label: { Image(systemName: "plus") }
                .help("Add a rule below")
                .accessibilityIdentifier("ar.advanced.add")
            Button { onAdd(true) } label: { Image(systemName: "ellipsis") }
                .help("Add a group of rules below, with its own any or all")
                .accessibilityIdentifier("ar.advanced.addGroup")
        }
        .controlSize(.small)
    }
}

/// The value part of a row, by field.
private struct RuleValueView: View {
    @Binding var rule: SearchRule
    @ObservedObject var model: NavigationModel

    var body: some View {
        switch rule.field {
        case .text, .ocrText, .fileName:
            TextField(rule.op == .phrase ? "phrase" : (rule.field == .fileName ? "text" : "words"), text: $rule.text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: .infinity)
                .help(rule.field == .fileName ? "Part of the file name"
                      : "Words separated by spaces; end a word with * to match its beginning (news* finds newspaper)")
                .accessibilityIdentifier("ar.advanced.rule.text")
        case .tags:
            SubjectFilterTokenField(subjects: Binding(get: { Set(rule.tags) }, set: { rule.tags = $0.sorted() }),
                                    suggestions: model.allSubjects, placeholder: "tags")
                .frame(minWidth: 160, maxWidth: .infinity)
                .accessibilityIdentifier("ar.advanced.rule.tags")
        case .quality:
            HStack(spacing: 6) {
                ForEach(QualityLevels.all + [0], id: \.self) { q in
                    Toggle(q == 0 ? "none" : "\(q)", isOn: Binding(
                        get: { rule.qualities.contains(q) },
                        set: { if $0 { rule.qualities.insert(q) } else { rule.qualities.remove(q) } }))
                    .toggleStyle(.checkbox)
                    .help(q == 0 ? "No quality tag" : "Quality \(q)")
                    .accessibilityIdentifier("ar.advanced.rule.quality.\(q == 0 ? "none" : "Q\(q)")")
                }
            }
        case .readState:
            Picker("Read state", selection: $rule.read) {
                Text("Unread").tag(ReadFilter.unread)
                Text("Read").tag(ReadFilter.read)
                Text("No read state").tag(ReadFilter.noReadState)
            }
            .labelsHidden().fixedSize()
        case .date:
            HStack(spacing: 6) {
                if rule.op != .undated {
                    dateField($rule.text, rule.op == .between ? "from" : "date")
                    if rule.op == .between {
                        Text("and")
                        dateField($rule.text2, "to")
                    }
                }
                // The own date first and by default; the sent-with date is a separate, rarer search (W40.suite-date-design).
                Picker("Which date", selection: $rule.dateRole) {
                    Text("own date").tag(DateRoleChoice.own)
                    Text("sent-with date").tag(DateRoleChoice.sentWith)
                    Divider()
                    Text("either date").tag(DateRoleChoice.either)
                }
                .labelsHidden().fixedSize()
                .help("The document's own date; or the date of the letter it was sent with, or either")
            }
        case .folder:
            Button(rule.text.isEmpty ? "Choose Folder…" : model.relativeFolderName(rule.text)) {
                if let path = model.chooseFolderForRule(startingAt: rule.text) { rule.text = path }
            }
            .help(rule.text.isEmpty ? "Choose a folder in the archive" : rule.text)
            .accessibilityIdentifier("ar.advanced.rule.folder")
        case .needsAttention, .ambiguousDate, .flagged, .group:
            EmptyView()
        }
    }

    private func dateField(_ text: Binding<String>, _ prompt: String) -> some View {
        let bad = !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
            && AdvancedSearch.dateKeys(text.wrappedValue) == nil
        return TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)
            .foregroundStyle(bad ? Color.red : Color.primary)
            .help("A year (1981), a month (1981-06), a day (1981-06-30) or a decade (1980s)")
            .accessibilityIdentifier("ar.advanced.rule.date")
    }
}

extension RuleField {
    var label: String {
        switch self {
        case .text: return "Any text"
        case .ocrText: return "OCR text"
        case .fileName: return "File name"
        case .tags: return "Tags"
        case .quality: return "Quality"
        case .readState: return "Read state"
        case .date: return "Date"
        case .folder: return "Folder"
        case .needsAttention: return "Needs attention"
        case .ambiguousDate: return "Ambiguous date"
        case .flagged: return "Flagged"
        case .group: return "Group"
        }
    }
}

extension RuleOperator {
    func label(for field: RuleField) -> String {
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
            case .needsAttention, .ambiguousDate, .flagged: return yes ? "yes" : "no"
            default: return yes ? "is" : "is not"
            }
        }
    }
}
