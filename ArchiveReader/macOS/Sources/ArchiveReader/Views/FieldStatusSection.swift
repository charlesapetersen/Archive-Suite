import SwiftUI
import PDFKit
import ArchiveCore
import ArchiveCoreUI

/// W40.reader-field-status: which of the selection's bibliographic values the user has checked, and how far the
/// unchecked ones can be trusted. For one file it lists the dates (from the tags) and the page-2 item fields (read
/// off the file, off the main thread), each with its state (`FieldStatusPolicy`) and a button that checks it without
/// changing it. Editing a date above checks it too (`TagEditing.userDelta`). For a group it counts the checked dates
/// and checks them all at once. A check is a `Checked <Field>` tag, written through `TagWriter` like any tag edit.
///
/// W40.reader-item-field-edit: an item field's value can be corrected, set to none or added. The user's value is kept
/// in the folder's `.archivesuite/item-fields.json` (`UserItemFields`, `NavigationModel.editItemField`) and shown in
/// place of page 2's, as checked; page 2 itself is never rewritten.
///
/// W49.reader-sender-row-check: the sender, recipient and sending place the Processor's names feature writes to the
/// JSON sidecar (`ZoteroSidecar`) are listed after the item fields, names only (the quote or "inferred" is in the
/// tooltip), and checked and corrected the same way; the sidecar itself is never rewritten.
struct FieldStatusSection: View {
    let files: [ArchiveFile]
    let apply: (TagEditOp) -> Void
    /// `NavigationModel.itemFieldRevision`: a change reads the user's values again.
    var revision = 0
    /// Item fields can be edited: the file is under the archive's main folder.
    var editable = false
    var saving = false
    var error: String?
    var onEdit: (CheckableField, ItemFieldEdit) -> Void = { _, _ in }
    /// The last header read, with the file and version it was read from. Shown only while that is the selection, so
    /// a newly selected file never shows, or checks, the previous file's fields while its own are read.
    @State private var read: (key: ReadKey, revision: Int, header: HeaderFields?)?

    /// A file as read: its path and its content date, so a page 2 rewritten in place is read again.
    struct ReadKey: Hashable {
        let path: String
        let modified: Date?
    }

    /// What the inspector needs from a file's page-2 headers, and the user's own values for its item fields.
    struct HeaderFields: Equatable, Sendable {
        var itemFields = PDFItemFields()
        var dateEvidence: String?
        /// The user's values (`UserItemFields`); "" is "none".
        var user: [CheckableField: String] = [:]
        /// W47.ct-folder-date-reader: the folder date the Reader gave the file, with its evidence; it stands for
        /// page 2's evidence while the file still carries that date.
        var dateRecord: FolderDateRecord?
        /// The Processor's JSON sidecar beside the file, when there is one: its sender, recipient and sending place.
        var sidecar: ZoteroSidecar?
        /// Why the folder's item-field file cannot be read or written, when it cannot; editing is then off.
        var userProblem: String?

        /// The first text page carrying item fields gives them; the first with a date-evidence line gives that.
        init(headers: [PDFPageHeader?]) {
            let all = headers.compactMap { $0 }
            itemFields = all.first(where: { !$0.itemFields.isEmpty })?.itemFields ?? PDFItemFields()
            dateEvidence = all.lazy.compactMap(\.dateEvidence).first
        }

        /// Reads `url`'s headers, its JSON sidecar and the user's values in its folder. A file that is not a PDF gives
        /// none; a placeholder that is not on disk gives the user's values alone.
        static func read(_ url: URL, isDataless: Bool) -> HeaderFields? {
            guard url.pathExtension.lowercased() == "pdf" else { return nil }
            var fields = HeaderFields(headers: [])
            if !isDataless, let doc = PDFDocument(url: url), !doc.isLocked {
                fields = HeaderFields(headers: PDFHeaderParser.textPageHeaders(doc))
            }
            // A placeholder's sidecar is not read either, so selecting it never downloads anything.
            if !isDataless { fields.sidecar = ZoteroSidecar.read(pdf: url) }
            let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
            switch ContainerFileStore.loadItemFields(directory: folder) {
            case .missing: break
            case let .loaded(doc, stamp):
                fields.user = doc.values(for: url.lastPathComponent)
                fields.dateRecord = doc.dateRecord(for: url.lastPathComponent)
                if stamp.droppedOnReading { fields.userProblem = problem }
            case .newer, .unreadable: fields.userProblem = problem
            }
            return fields
        }

        static let problem = "This folder's “.archivesuite/\(UserItemFields.fileName)” was written by a newer version "
            + "or cannot be read, so item fields cannot be corrected here. It is left as it is."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checks").font(.subheadline.bold())
            if let file = single {
                let header = read?.key == key(file) ? read?.header : nil
                // Edits wait for the read after the last save, so a menu never offers a state the file has left.
                let current = read?.revision == revision
                FieldStatusList(tags: file.tags, header: header, apply: apply,
                                editable: editable && current && header != nil && header?.userProblem == nil,
                                saving: saving, onEdit: onEdit)
                    .id(file.path)   // a field being typed into belongs to its file, never the next one selected
                if let problem = header?.userProblem, editable {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ar.fieldStatus.error")
                }
            } else {
                groupSummary
                if editable, files.count > 1 {
                    ItemFieldSelectionEditor(count: files.count, saving: saving, onEdit: onEdit)
                        .id(SelectionKey(first: files.first?.path, count: files.count))   // a draft is its selection's
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ar.fieldStatus.error")
                }
            }
        }
        .task(id: single.map { TaskKey(file: key($0), revision: revision) }) {
            guard let file = single else { return }
            let k = key(file), url = file.url, dataless = file.isDataless, rev = revision
            let header = await Task.detached(priority: .utility) { HeaderFields.read(url, isDataless: dataless) }.value
            if !Task.isCancelled { read = (k, rev, header) }
        }
    }

    /// What starts a read: a new file or version, or a saved edit. Only the file decides what is shown.
    private struct TaskKey: Hashable {
        let file: ReadKey
        let revision: Int
    }

    private struct SelectionKey: Hashable {
        let first: String?
        let count: Int
    }

    private var single: ArchiveFile? { files.count == 1 ? files.first : nil }

    private func key(_ file: ArchiveFile) -> ReadKey { ReadKey(path: file.url.path, modified: file.contentModified) }

    /// Over several files: how many dates are checked, and one button that checks the rest.
    @ViewBuilder private var groupSummary: some View {
        ForEach([CheckableField.date, .sentWith], id: \.self) { field in
            let dated = files.filter { field == .date ? $0.tags.year != nil || $0.tags.decade != nil
                                                      : $0.tags.sentWith != nil }
            let checked = dated.filter { $0.tags.checkedFields.contains(field) }.count
            if !dated.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    let level: FieldCheckLevel = checked == dated.count ? .checked : .lowerConfidence
                    Image(systemName: level.symbol).foregroundStyle(FieldStatusBadge.color(level))
                    Text("\(field.label): checked on \(checked) of \(dated.count) dated files")
                        .font(.callout)
                        .accessibilityIdentifier("ar.fieldStatus.group.\(field)")
                    Spacer(minLength: 8)
                    if checked < dated.count {
                        Button("Mark all checked") { apply(.setChecked(field, true)) }
                            .controlSize(.small)
                            .help("Mark the \(field.label.lowercased()) checked on every selected file that has one.")
                            .accessibilityIdentifier("ar.fieldStatus.group.\(field).check")
                    }
                }
            }
        }
        Text(editable && files.count > 1 ? "Item fields are listed for one file at a time; below, one value can be given to every "
                 + "selected file." : "Item fields are listed for one file at a time.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// W49.reader-item-fields-follow: one item field set for every selected file, as the container editor's "set for
/// selection": the value, None, or the user's values taken away. Each file's value goes beside it, as for one file.
struct ItemFieldSelectionEditor: View {
    let count: Int
    var saving = false
    let onEdit: (CheckableField, ItemFieldEdit) -> Void

    @State private var field: CheckableField = .title
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Item field", selection: $field) {
                    ForEach(IndexedItemFields.columnOrder + CheckableField.nameFields, id: \.self) {
                        Text($0.label).tag($0)
                    }
                }
                .labelsHidden().frame(width: 160)
                .accessibilityIdentifier("ar.itemFieldSelection.field")
                TextField(field.label, text: $draft)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .onSubmit(set)
                    .accessibilityIdentifier("ar.itemFieldSelection.value")
            }
            HStack {
                Button("Set for \(count) Files", action: set)
                    .controlSize(.small)
                    .disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ar.itemFieldSelection.set")
                Menu("More") {
                    Button("None for \(count) Files") { onEdit(field, .none) }
                        .help("Say these files have no \(field.label.lowercased()), whatever "
                              + "\(FieldStatusList.source(field)) reads.")
                    Button("Remove Your \(field.label) from \(count) Files") { onEdit(field, .remove) }
                        .help("Take your value away, so \(FieldStatusList.source(field))'s shows again.")
                }
                .controlSize(.small).fixedSize()
                .disabled(saving)
                .accessibilityIdentifier("ar.itemFieldSelection.more")
                Spacer()
            }
        }
    }

    private func set() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onEdit(field, .set(text))
        draft = ""
    }
}

/// One file's checkable values, in a fixed order: the dates, then the item fields in header order. An item field the
/// user has set shows their value, checked, and page 2's in its tooltip.
struct FieldStatusList: View {
    let tags: DocumentTags
    let header: FieldStatusSection.HeaderFields?
    let apply: (TagEditOp) -> Void
    var editable = false
    var saving = false
    var onEdit: (CheckableField, ItemFieldEdit) -> Void = { _, _ in }

    @State private var editing: CheckableField?
    @State private var draft = ""

    struct Row: Equatable {
        let field: CheckableField
        let value: String
        let status: FieldStatus
        /// The value is the user's (`UserItemFields`), not page 2's.
        var userSet = false
        /// What page 2 reads, for an item field; what the JSON sidecar reads, for a name.
        var pageValue: String?
    }

    static func rows(tags: DocumentTags, header: FieldStatusSection.HeaderFields?) -> [Row] {
        var rows: [Row] = []
        if let date = tags.displayDate {
            rows.append(Row(field: .date, value: date + (tags.dateUncertain ? " (uncertain)" : ""),
                            status: FieldStatusPolicy.date(checked: tags.checkedFields.contains(.date),
                                                           evidence: FolderDateRecord.evidence(
                                                               header?.dateRecord, page: header?.dateEvidence,
                                                               tags: tags))))
        }
        if let sent = tags.displaySentWith {
            rows.append(Row(field: .sentWith, value: sent + (tags.sentWithUncertain ? " (uncertain)" : ""),
                            status: FieldStatusPolicy.sentWith(checked: tags.checkedFields.contains(.sentWith))))
        }
        for field in CheckableField.itemFields {
            let page = header.flatMap { field.value(in: $0.itemFields) }
            if let user = header?.user[field] {
                rows.append(Row(field: field, value: user.isEmpty ? Self.noneText : user,
                                status: FieldStatusPolicy.userItemField(pageValue: page), userSet: true,
                                pageValue: page))
            } else if let page {
                rows.append(Row(field: field, value: page,
                                status: FieldStatusPolicy.itemField(field, checked: tags.checkedFields.contains(field)),
                                pageValue: page))
            }
        }
        for field in CheckableField.nameFields {
            let side = header?.sidecar.flatMap { field.value(in: $0) }
            if let user = header?.user[field] {
                rows.append(Row(field: field, value: user.isEmpty ? Self.noneText : user,
                                status: FieldStatusPolicy.userNameField(sidecarValue: side), userSet: true,
                                pageValue: side))
            } else if let side {
                rows.append(Row(field: field, value: side,
                                status: FieldStatusPolicy.nameField(field, checked: tags.checkedFields.contains(field),
                                                                    evidence: header?.sidecar?.evidence[field] ?? [],
                                                                    fromEntityCall: header?.sidecar?.namesFromEntityCall
                                                                        ?? true),
                                pageValue: side))
            }
        }
        return rows
    }

    /// Where a field's value comes from, as a menu names it.
    static func source(_ field: CheckableField) -> String {
        CheckableField.nameFields.contains(field) ? "the JSON sidecar" : "page 2"
    }

    /// How a user's "none" is shown.
    static let noneText = "None"

    /// The kinds a document can be given (SPEC tag-format §Item fields), in a fixed order for the menu.
    static let kinds = ZoteroExport.kinds.sorted()

    var body: some View {
        let rows = Self.rows(tags: tags, header: header)
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text("No date or item fields to check.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.field) { row in
                VStack(alignment: .leading, spacing: 4) {
                    FieldStatusRow(name: row.field.label, value: row.value, status: row.status,
                                   identifier: "ar.fieldStatus.\(row.field)",
                                   onToggle: row.userSet ? nil
                                       : { apply(.setChecked(row.field, row.status.level != .checked)) })
                    if editable, CheckableField.correctable.contains(row.field) {
                        if editing == row.field { editor(row.field) } else { rowMenu(row) }
                    }
                }
            }
            if editable {
                let shown = Set(rows.map(\.field))
                let missing = CheckableField.correctable.filter { !shown.contains($0) }
                if let field = editing, missing.contains(field) {
                    Text(field.label).font(.callout).foregroundStyle(.secondary)
                    editor(field)
                }
                if !missing.isEmpty { addMenu(missing) }
            }
        }
    }

    private func rowMenu(_ row: Row) -> some View {
        let f = row.field
        return Menu("Edit") {
            Button("Change…") { begin(f, text: header?.user[f] == "" ? "" : row.value) }
            if header?.user[f] != "" {
                Button("None") { onEdit(f, .none) }
                    .help("Say this file has no \(f.label.lowercased()), whatever \(Self.source(f)) reads.")
            }
            if row.userSet {
                Button(row.pageValue.map { "Remove Your Value (\(Self.source(f)) reads “\($0)”)" } ?? "Remove Your Value") {
                    onEdit(f, .remove)
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .disabled(saving)
        .help(CheckableField.nameFields.contains(f)
              ? "Correct the \(f.label.lowercased()) for this file; separate several names with “;”. The JSON sidecar "
                + "is not rewritten; your value is kept beside it."
              : "Correct the \(f.label.lowercased()) for this file. Page 2 is not rewritten; your value is kept beside it.")
        .accessibilityIdentifier("ar.fieldStatus.\(f).edit")
    }

    private func addMenu(_ missing: [CheckableField]) -> some View {
        Menu("Add Item Field") {
            ForEach(missing, id: \.self) { f in
                Button(f.label) { begin(f, text: "") }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .disabled(saving)
        .help("Give this file a kind, title, byline, publication, publication date, recipient place, sender, recipient "
              + "or sending place it lacks.")
        .accessibilityIdentifier("ar.fieldStatus.add")
    }

    @ViewBuilder private func editor(_ field: CheckableField) -> some View {
        HStack {
            if field == .documentKind {
                Picker(field.label, selection: $draft) {
                    if !Self.kinds.contains(draft) { Text(draft.isEmpty ? "Choose…" : draft).tag(draft) }
                    ForEach(Self.kinds, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().font(.callout)
                .accessibilityIdentifier("ar.fieldStatus.\(field).field")
            } else {
                TextField(field.label, text: $draft)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .onSubmit { commit(field) }
                    .accessibilityIdentifier("ar.fieldStatus.\(field).field")
            }
            Button("Save") { commit(field) }
                .controlSize(.small).disabled(saving)
                .accessibilityIdentifier("ar.fieldStatus.\(field).save")
            Button("Cancel") { editing = nil }
                .controlSize(.small)
        }
    }

    private func begin(_ field: CheckableField, text: String) {
        draft = text
        editing = field
    }

    private func commit(_ field: CheckableField) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onEdit(field, .set(text))
        editing = nil
    }
}
