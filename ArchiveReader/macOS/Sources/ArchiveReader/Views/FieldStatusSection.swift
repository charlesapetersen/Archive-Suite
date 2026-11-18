import SwiftUI
import PDFKit
import ArchiveCore
import ArchiveCoreUI

/// W40.reader-field-status: which of the selection's bibliographic values the user has checked, and how far the
/// unchecked ones can be trusted. For one file it lists the dates (from the tags) and the page-2 item fields (read
/// off the file, off the main thread), each with its state (`FieldStatusPolicy`) and a button that checks it without
/// changing it. Editing a date above checks it too (`TagEditing.userDelta`). For a group it counts the checked dates
/// and checks them all at once. A check is a `Checked <Field>` tag, written through `TagWriter` like any tag edit.
struct FieldStatusSection: View {
    let files: [ArchiveFile]
    let apply: (TagEditOp) -> Void
    /// The last header read, with the file and version it was read from. Shown only while that is the selection, so
    /// a newly selected file never shows, or checks, the previous file's fields while its own are read.
    @State private var read: (key: ReadKey, header: HeaderFields?)?

    /// A file as read: its path and its content date, so a page 2 rewritten in place is read again.
    struct ReadKey: Hashable {
        let path: String
        let modified: Date?
    }

    /// What the inspector needs from a file's page-2 headers.
    struct HeaderFields: Equatable, Sendable {
        var itemFields = PDFItemFields()
        var dateEvidence: String?

        /// The first text page carrying item fields gives them; the first with a date-evidence line gives that.
        init(headers: [PDFPageHeader?]) {
            let all = headers.compactMap { $0 }
            itemFields = all.first(where: { !$0.itemFields.isEmpty })?.itemFields ?? PDFItemFields()
            dateEvidence = all.lazy.compactMap(\.dateEvidence).first
        }

        /// Reads `url`'s headers. A placeholder that is not on disk, or a file that is not a PDF, gives none.
        static func read(_ url: URL, isDataless: Bool) -> HeaderFields? {
            guard !isDataless, url.pathExtension.lowercased() == "pdf",
                  let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
            return HeaderFields(headers: PDFHeaderParser.textPageHeaders(doc))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checks").font(.subheadline.bold())
            if let file = single {
                FieldStatusList(tags: file.tags, header: read?.key == key(file) ? read?.header : nil, apply: apply)
            } else {
                groupSummary
            }
        }
        .task(id: single.map(key)) {
            guard let file = single else { return }
            let k = key(file), url = file.url, dataless = file.isDataless
            let header = await Task.detached(priority: .utility) { HeaderFields.read(url, isDataless: dataless) }.value
            if !Task.isCancelled { read = (k, header) }
        }
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
        Text("Item fields are listed for one file at a time.").font(.caption).foregroundStyle(.secondary)
    }
}

/// One file's checkable values, in a fixed order: the dates, then the item fields in header order.
struct FieldStatusList: View {
    let tags: DocumentTags
    let header: FieldStatusSection.HeaderFields?
    let apply: (TagEditOp) -> Void

    struct Row: Equatable {
        let field: CheckableField
        let value: String
        let status: FieldStatus
    }

    static func rows(tags: DocumentTags, header: FieldStatusSection.HeaderFields?) -> [Row] {
        var rows: [Row] = []
        if let date = tags.displayDate {
            rows.append(Row(field: .date, value: date + (tags.dateUncertain ? " (uncertain)" : ""),
                            status: FieldStatusPolicy.date(checked: tags.checkedFields.contains(.date),
                                                           evidence: header?.dateEvidence)))
        }
        if let sent = tags.displaySentWith {
            rows.append(Row(field: .sentWith, value: sent + (tags.sentWithUncertain ? " (uncertain)" : ""),
                            status: FieldStatusPolicy.sentWith(checked: tags.checkedFields.contains(.sentWith))))
        }
        for field in CheckableField.itemFields {
            guard let fields = header?.itemFields, let value = field.value(in: fields) else { continue }
            rows.append(Row(field: field, value: value,
                            status: FieldStatusPolicy.itemField(field, checked: tags.checkedFields.contains(field))))
        }
        return rows
    }

    var body: some View {
        let rows = Self.rows(tags: tags, header: header)
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                Text("No date or item fields to check.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.field) { row in
                FieldStatusRow(name: row.field.label, value: row.value, status: row.status,
                               identifier: "ar.fieldStatus.\(row.field)",
                               onToggle: { apply(.setChecked(row.field, row.status.level != .checked)) })
            }
        }
    }
}
