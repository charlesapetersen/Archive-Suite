import SwiftUI
import ArchiveCore
import ArchiveCoreUI

/// Tag editor for the current selection (single file or group), or for the document window's open file. Every control applies immediately
/// via `NavigationModel.applyEdit` → `TagWriter` (delta-based, verified, grouped-undoable). Group
/// edits show Finder-style tri-state: subjects on all vs. some; facets show "(mixed)" when they differ.
struct TagEditorView: View {
    /// Observed through `feed`, and only while shown (`TagInspectorView`).
    let model: NavigationModel
    @StateObject private var feed = InspectorFeed()
    /// Immutable for this editor instance, so a departing field always writes its original targets.
    /// (W40.fix-reader-menus-follow-window). Every write still goes through `NavigationModel` → `TagWriter`.
    let targetPaths: [String]
    var isVisible = true
    var onClose: () -> Void = {}
    @State private var subjectDraft = ""
    @State private var dateDrafts: [DateField: String] = [:]
    /// The fields typed in since they were last applied or seeded: only these are written.
    @State private var editedFields: Set<DateField> = []
    @State private var seededText: [DateField: String?] = [:]
    @FocusState private var focusedField: DateField?

    var body: some View {
        let files = targetFiles
        let s = GroupTagSummary(files.map(\.tags))
        VStack(spacing: 0) {
            HStack {
                Text(s.count == 1 ? "Inspector" : "Inspector — \(s.count) files").font(.headline)
                Spacer()
                Button("Close") { addSubject(); commitDateFields(); if invalidFields.isEmpty { onClose() } }
                    .help("Hide Inspector (\(ReaderCommand.showInspector.glyph))")
                    .accessibilityIdentifier("ar.tagEditor.done")
            }
            .padding()
            Text(files.count == 1 ? (files.first?.name ?? "") : "Changes apply to all selected files.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).padding(.horizontal).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    subjectsSection(s)
                    Divider()
                    dateSection(s, files)
                    Divider()
                    qualitySection(s)
                    Divider()
                    itemTypeSection(s, files)
                    Divider()
                    readStateSection(s)
                    Divider()
                    flagSection
                    if let file = collectionRecordFile {
                        Divider()
                        CollectionRecordView(fileURL: file, root: model.rootStore.root, identifierPrefix: "ar")
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { feed.follow(model, visible: isVisible) }
        .onChange(of: ObjectIdentifier(model)) { feed.follow(model, visible: isVisible) }   // a new library window
        .onChange(of: isVisible) { _, visible in
            feed.follow(model, visible: visible)
            if !visible {
                focusedField = nil
                addSubject()
                commitDateFields()
            }
        }
    }

    /// The file whose collection record the inspector shows (W46.settings-reader-notes): the selection's when every
    /// selected file sits in one folder, else none. A selection over `maxCollectionCheck` files shows none, so the
    /// body never walks a huge selection's paths on each redraw.
    private var collectionRecordFile: URL? {
        guard let first = targetPaths.first, targetPaths.count <= Self.maxCollectionCheck else { return nil }
        let folder = (first as NSString).deletingLastPathComponent
        guard targetPaths.allSatisfy({ ($0 as NSString).deletingLastPathComponent == folder }) else { return nil }
        return URL(fileURLWithPath: first)
    }

    private static let maxCollectionCheck = 500

    // MARK: Subjects

    @ViewBuilder private func subjectsSection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Tags")
            if s.subjectsOnAll.isEmpty && s.subjectsOnSome.isEmpty {
                Text("None").foregroundStyle(.secondary).font(.callout)
            }
            // Wrapped, not one horizontal row: a row clipped every subject past the first few, so they could not
            // be removed (W40.fix-reader-tag-editor-chips).
            FlowLayout(spacing: 6) {
                ForEach(s.subjectsOnAll, id: \.self) { chip($0, partial: false) }
                ForEach(s.subjectsOnSome, id: \.self) { chip($0, partial: true) }
            }
            // Return adds the typed tag; there is no Add button (owner, notes-1 rows 25-26).
            SubjectEntryField(draft: $subjectDraft, placeholder: "Add tag…", identifier: "ar.tagEditor.addSubject",
                              suggestions: { let onAll = Set(s.subjectsOnAll.map(tagKey)); return model.allSubjects.filter { !onAll.contains(tagKey($0)) } },
                              onAdd: { apply(.addSubject($0)) })
            // Tags that differ only in case are one tag: say which spelling the new one is written in.
            if let existing = model.existingSpelling(differingFrom: subjectDraft) {
                Label("Added as “\(existing)”, the existing spelling of this tag.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !s.subjectsOnSome.isEmpty {
                Text("Faded, dashed tags are on some, not all, selected files.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A removable subject. A partial one (on some of the selected files) is drawn faded with a dashed outline
    /// and no fill, so it reads as partial on its own: when every chip was partial, a uniform fade showed nothing.
    private func chip(_ subject: String, partial: Bool) -> some View {
        Button { apply(.removeSubject(subject)) } label: {
            HStack(spacing: 3) {
                Text(subject).lineLimit(1).truncationMode(.middle)
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .font(.callout)
            .foregroundStyle(partial ? .secondary : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(partial ? Color.clear : Color.accentColor.opacity(0.18)))
            .overlay(Capsule().strokeBorder(partial ? Color.secondary.opacity(0.7) : Color.accentColor.opacity(0.55),
                                            style: StrokeStyle(lineWidth: 1, dash: partial ? [3, 2] : [])))
            .contentShape(Capsule())
            .frame(maxWidth: 420)   // a very long subject truncates rather than overrunning the inspector
        }
        .buttonStyle(.plain)
        .help(partial ? "On some of the selected files. Click to remove “\(subject)” from all of them."
                      : "Remove “\(subject)”")
        .accessibilityIdentifier("ar.tagEditor.chip." + subject)
        .accessibilityValue(partial ? "on some selected files" : "on all selected files")
    }

    private func addSubject() {
        let t = subjectDraft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        apply(.addSubject(t))
        subjectDraft = ""
    }

    // MARK: Date

    /// The typed date fields. Each applies on Return or on leaving it, and an emptied field clears its facet:
    /// there is no Set or Clear button (owner, notes-1 row 25; AGENTS.md §UI conventions).
    enum DateField: Hashable { case year, day, sentWith }

    @ViewBuilder private func dateSection(_ s: GroupTagSummary, _ files: [ArchiveFile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Date")
            dateAmbiguityNotice(files)
            HStack {
                Text("Year").frame(width: 52, alignment: .leading)
                dateField(.year, placeholder: yearPlaceholder(s), width: 90)
                    .help("Type a year from 100 to 9999; empty the field to remove the year")
                    .accessibilityIdentifier("ar.tagEditor.year")
            }
            if let hint = invalidHint(.year) { hint }
            HStack {
                Text("Month").frame(width: 52, alignment: .leading)
                Menu(monthLabel(files)) {
                    Button("None") { apply(.setMonth(nil)) }
                    ForEach(1...12, id: \.self) { m in
                        Button(TagEditing.monthToken(m)) { apply(.setMonth(m)) }
                    }
                }
                .frame(width: 150)
                .accessibilityIdentifier("ar.tagEditor.month")
            }
            HStack {
                Text("Day").frame(width: 52, alignment: .leading)
                dateField(.day, placeholder: dayPlaceholder(files), width: 90)
                    .help("Type a day from 1 to 31; empty the field to remove the day")
                    .accessibilityIdentifier("ar.tagEditor.day")
            }
            if let hint = invalidHint(.day) { hint }
            uncertainToggle(relevant: files, op: TagEditOp.setDateUncertain) { $0.tags.dateUncertain }
                .accessibilityIdentifier("ar.tagEditor.dateUncertain")
            Divider()
            // W37: the covering letter's date, for an enclosure that has its own date above. The inspector is the one
            // date editor (owner, 2026-10-12), so Sent-With lives here too (W40.fix-reader-sent-with-date).
            HStack {
                Text("Sent with").frame(width: 68, alignment: .leading)
                dateField(.sentWith, placeholder: sentWithPlaceholder(files), width: 110)
                    .help("The date of the letter this was enclosed with: 1958, 1958-03, 1958-03-12 or 1950s. Empty the field to remove it.")
                    .accessibilityIdentifier("ar.tagEditor.sentWith")
            }
            if let hint = invalidHint(.sentWith) { hint }
            // Enabled for a file with a stray flag and no Sent-With date too, so that flag can be turned off.
            uncertainToggle(relevant: files.filter { $0.tags.sentWith != nil || $0.tags.sentWithUncertain },
                            op: TagEditOp.setSentWithUncertain) { $0.tags.sentWithUncertain }
                .accessibilityIdentifier("ar.tagEditor.sentWithUncertain")
        }
        .onAppear { seedDateFields(files) }
        // A date changed by this inspector or elsewhere shows here, unless the field is being typed in or holds
        // text not applied yet, which a reseed would throw away.
        .onChange(of: DateFacets(files)) { seedDateFields(files) }
        .onChange(of: focusedField) { old, _ in if let old { commit(old) } }
        .onDisappear { commitDateFields() }
    }

    private func dateField(_ field: DateField, placeholder: String, width: CGFloat) -> some View {
        // Only typing goes through this setter, so a reseed never counts as an edit.
        TextField(placeholder, text: Binding(get: { dateDrafts[field] ?? "" },
                                             set: { text in
                                                 guard text != (dateDrafts[field] ?? "") else { return }
                                                 dateDrafts[field] = text; editedFields.insert(field) }))
            .textFieldStyle(.roundedBorder).frame(width: width)
            .focused($focusedField, equals: field)
            .onSubmit { commit(field) }
    }

    @ViewBuilder private func uncertainToggle(relevant: [ArchiveFile], op: @escaping @Sendable (Bool) -> TagEditOp,
                                              isFlagged: (ArchiveFile) -> Bool) -> some View {
        let flagged = relevant.filter(isFlagged).count
        HStack {
            Toggle("Uncertain", isOn: Binding(get: { !relevant.isEmpty && flagged == relevant.count },
                                                set: { apply(op($0)) }))
                .toggleStyle(.checkbox)
                .disabled(relevant.isEmpty)
            if flagged > 0 && flagged < relevant.count {
                Text("(mixed)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The edit a field's text makes: `nil` for text that is not a valid value (kept, never written), else
    /// the op, an emptied field clearing its facet.
    static func dateOp(_ field: DateField, _ text: String) -> TagEditOp? {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch field {
        case .year:
            if t.isEmpty { return .setYear(nil) }
            guard let y = Int(t), (100...9999).contains(y) else { return nil }
            return .setYear(y)
        case .day:
            if t.isEmpty { return .setDay(nil) }
            guard let d = Int(t), (1...31).contains(d) else { return nil }
            return .setDay(d)
        case .sentWith:
            if t.isEmpty { return .setSentWith(nil) }
            guard let d = ArchiveDate.parse(wireValue: t) else { return nil }
            return .setSentWith(d)
        }
    }

    /// What a typed-in field writes when it is applied, or `nil` for nothing. `shared` is the field's text when
    /// the inspector seeded it (`DateFacets`): the value every file shares, or `.some(nil)` when the files differ.
    static func edit(_ field: DateField, typed text: String, shared: String??) -> TagEditOp? {
        guard let op = dateOp(field, text) else { return nil }
        let typed = text.trimmingCharacters(in: .whitespaces)
        switch shared {
        // Unchanged from the value all the files share: nothing to write.
        case .some(.some(let seeded)) where typed == seeded: return nil
        // A mixed field emptied again is left alone: an empty mixed field means "keep each file's own", never
        // "clear them all" (a cleared year also drops a decade-only file's decade).
        case .some(.none) where typed.isEmpty: return nil
        default: return op
        }
    }

    /// Apply a field that was typed in. Leaving one untouched writes nothing, so tabbing past a group's mixed
    /// value never overwrites it; an invalid entry stays marked as typed, its hint showing.
    private func commit(_ field: DateField) {
        let text = dateDrafts[field] ?? ""
        guard editedFields.contains(field), Self.dateOp(field, text) != nil else { return }
        editedFields.remove(field)
        // Never seeded counts as mixed, the case that writes least.
        let shared: String??
        if let i = seededText.index(forKey: field) { shared = seededText[i].value } else { shared = .some(nil) }
        if let op = Self.edit(field, typed: text, shared: shared) { apply(op) }
    }

    private var invalidFields: [DateField] {
        [.year, .day, .sentWith].filter { editedFields.contains($0) && Self.dateOp($0, dateDrafts[$0] ?? "") == nil }
    }

    private func commitDateFields() { for f in [DateField.year, .day, .sentWith] { commit(f) } }

    private func seedDateFields(_ files: [ArchiveFile]) {
        let shown = DateFacets(files).texts
        for f in [DateField.year, .day, .sentWith] where !editedFields.contains(f) && focusedField != f {
            dateDrafts[f] = shown[f] ?? ""
        }
        seededText = shown
    }

    private func invalidHint(_ field: DateField) -> Text? {
        guard editedFields.contains(field), Self.dateOp(field, dateDrafts[field] ?? "") == nil else { return nil }
        let message: String
        switch field {
        case .year: message = "Use a year from 100 to 9999"
        case .day: message = "Use a day from 1 to 31"
        case .sentWith: message = "Use 1958, 1958-03, 1958-03-12 or 1950s"
        }
        return Text(message).font(.caption).foregroundStyle(.red)
    }

    /// The selection's date facets, each as the text its field shows: the common value, "" when none has it,
    /// `nil` when the files differ (the field is then empty with a "mixed" placeholder).
    struct DateFacets: Equatable {
        let texts: [DateField: String?]
        init(_ files: [ArchiveFile]) {
            func common(_ values: [String]) -> String? { Set(values).count == 1 ? values.first : (values.isEmpty ? "" : nil) }
            texts = [.year: common(files.map { $0.tags.year.map(String.init) ?? "" }),
                     .day: common(files.map { $0.tags.day.map(String.init) ?? "" }),
                     .sentWith: common(files.map { $0.tags.sentWith?.wireValue ?? "" })]
        }
    }

    /// W40.fix-reader-date-ambiguity: a file with two tags for one date facet says which one the date uses and
    /// which was set aside. Either may be the wrong one: a set-aside tag is a subject chip above, and the kept
    /// one is replaced by setting the date below.
    /// One accessibility element whose label is the whole message (a bare `Label` keeps its text on a child).
    @ViewBuilder private func dateAmbiguityNotice(_ files: [ArchiveFile]) -> some View {
        if let message = dateAmbiguityMessage(files) {
            Label(message, systemImage: "calendar.badge.exclamationmark")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(message)
                .accessibilityIdentifier("ar.tagEditor.dateAmbiguity")
        }
    }

    private func dateAmbiguityMessage(_ files: [ArchiveFile]) -> String? {
        let ambiguous = files.filter(\.dateIsAmbiguous)
        if ambiguous.count == 1, files.count == 1, let text = ambiguous[0].dateAmbiguityText {
            return "\(text) Remove the wrong tag: a set-aside one under Tags, or the kept one by setting the date below."
        }
        return ambiguous.isEmpty ? nil
            : "\(ambiguous.count) of the selected files have two tags for one date. Open one to see which."
    }

    private func sentWithPlaceholder(_ files: [ArchiveFile]) -> String {
        DateFacets(files).texts[.sentWith] == .some(nil) ? "mixed" : "1958-03-12"
    }

    // MARK: Quality

    @ViewBuilder private func qualitySection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Quality" + (s.commonQuality == nil ? "  (mixed)" : ""))
            HStack {
                facetButton("None", current: s.commonQuality == .some(nil)) { apply(.setQuality(nil)) }
                ForEach([1, 2, 3], id: \.self) { q in
                    facetButton("Q\(q)", current: s.commonQuality == .some(q)) { apply(.setQuality(q)) }
                }
            }
        }
    }

    // MARK: Item type

    /// W40.suite-item-types: Box and Folder are item types, written as their `Box`/`Folder` tag. A type read
    /// from the folder's older colours (Options ▸ Item types) is shown as such, and choosing it writes the tag.
    @ViewBuilder private func itemTypeSection(_ s: GroupTagSummary, _ files: [ArchiveFile]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Item type" + (s.commonItemType == nil ? "  (mixed)" : ""))
            HStack {
                facetButton("None", current: s.commonItemType == .some(nil)) { apply(.setItemType(nil)) }
                ForEach(ItemType.allCases, id: \.self) { type in
                    facetButton(type.displayName, current: s.commonItemType == .some(type)) { apply(.setItemType(type)) }
                }
            }
            if files.contains(where: { $0.tags.itemTypeToken == nil && $0.tags.itemTypeFromColour != nil }) {
                Text("Read from this folder’s older colours. Choosing a type writes its tag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Read state

    @ViewBuilder private func readStateSection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Read state" + (s.commonReadState == nil ? "  (mixed)" : ""))
            HStack {
                facetButton("Read", current: s.commonReadState == .some(.read)) { markReadState(.read) }
                facetButton("Unread", current: s.commonReadState == .some(.unread)) { markReadState(.unread) }
            }
        }
    }

    // MARK: Flag (app-side, never written to the file)

    @ViewBuilder private var flagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Flag")
            Text("Stored in the app — never written to the file.").font(.caption).foregroundStyle(.secondary)
            Button { toggleFlag() } label: { Label("Toggle flag", systemImage: "flag") }
        }
    }

    // MARK: Helpers

    /// The files this inspector edits: the document window's open file, else the list's selection.
    private var targetFiles: [ArchiveFile] {
        model.libraryFiles(atPaths: targetPaths)
    }

    private func apply(_ op: TagEditOp) { model.applyEdit(op, paths: targetPaths) }
    private func markReadState(_ state: ReadState) { model.mark(state, paths: targetPaths) }
    private func toggleFlag() {
        model.toggleFlag(paths: targetPaths)
    }

    private func title(_ t: String) -> some View { Text(t).font(.subheadline.bold()) }

    /// The current choice is a filled accent button. A tinted `.bordered` one was blue text on an almost
    /// invisible tint, so the choice looked weaker than the options around it (W40.fix-reader-tag-editor-chips).
    @ViewBuilder
    private func facetButton(_ label: String, current: Bool, action: @escaping () -> Void) -> some View {
        if current {
            Button(label, action: action)
                .buttonStyle(.borderedProminent)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(label, action: action)
                .buttonStyle(.bordered)
        }
    }

    private func yearPlaceholder(_ s: GroupTagSummary) -> String { s.commonYear == nil ? "mixed" : "1958" }

    private func dayPlaceholder(_ files: [ArchiveFile]) -> String {
        DateFacets(files).texts[.day] == .some(nil) ? "mixed" : "1–31"
    }

    /// The month the files share, "None", or "Mixed".
    private func monthLabel(_ files: [ArchiveFile]) -> String {
        let months = Set(files.map { $0.tags.month?.number })
        guard months.count == 1, let only = months.first else { return files.isEmpty ? "None" : "Mixed" }
        return only.map(TagEditing.monthToken) ?? "None"
    }
}
