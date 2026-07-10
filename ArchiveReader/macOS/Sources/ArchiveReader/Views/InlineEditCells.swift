import SwiftUI

// Inline, single-file tag editors that live in the navigation-list cells. Editing MULTIPLE selected
// files at once uses the ⌘I group editor; these cells act on exactly one file. Every change routes
// through the audited `TagWriter` (via NavigationModel) — no raw file mutation here.

/// Read-state cell — a borderless menu to set Read / Unread / clear on this one file.
struct ReadStateCell: View {
    @ObservedObject var model: NavigationModel
    let file: ArchiveFile
    var body: some View {
        Button { model.toggleReadState(for: file) } label: {   // C8: single click toggles Read↔Unread
            Text(file.readState?.rawValue ?? "—")
                .foregroundStyle(file.readState == .unread ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Read")   { model.setReadStateInline(.read, for: file) }
            Button("Unread") { model.setReadStateInline(.unread, for: file) }
            if file.readState != nil {
                Divider()
                Button("Clear read-state") { model.clearReadState(for: file) }
            }
        }
        .help("Click to toggle Read/Unread · right-click for options · ⌘I edits several at once")
    }
}

/// Priority cell — a borderless menu (None / P7–P10) for this one file.
struct PriorityCell: View {
    @ObservedObject var model: NavigationModel
    let file: ArchiveFile
    var body: some View {
        Menu {
            Button("None") { model.applyEdit(.setPriority(nil), to: file) }
            ForEach([10, 9, 8, 7], id: \.self) { p in
                Button("P\(p)") { model.applyEdit(.setPriority(p), to: file) }
            }
        } label: {
            Text(file.priority.map { "P\($0)" } ?? "—").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Set this file's priority")
    }
}

/// Document-date cell — click to edit year / month / day / uncertain in a popover, for this file.
struct DateCell: View {
    @ObservedObject var model: NavigationModel
    let file: ArchiveFile
    @State private var showing = false
    @State private var yearText = ""
    @State private var dayText = ""

    var body: some View {
        Button {
            yearText = file.tags.year.map(String.init) ?? file.tags.decadeToken ?? ""
            dayText  = file.tags.day.map(String.init) ?? ""
            showing = true
        } label: {
            Text(file.tags.displayDate ?? "—")
                .italic(file.dateIsSpeculative)
                .foregroundStyle(file.sortDate == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Click to edit the document date")
        .popover(isPresented: $showing) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit date").font(.headline)
            Text(file.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack {
                Text("Year").frame(width: 44, alignment: .leading)
                TextField("e.g. 1980", text: $yearText).frame(width: 90)
                Button("Set") { if let y = Int(yearText), (100...9999).contains(y) { model.applyEdit(.setYear(y), to: file) } }
                    .disabled(Int(yearText).map { !(100...9999).contains($0) } ?? true)
                Button("Clear") { model.applyEdit(.setYear(nil), to: file); yearText = "" }
            }
            HStack {
                Text("Month").frame(width: 44, alignment: .leading)
                Picker("", selection: monthBinding) {
                    Text("—").tag(0)
                    ForEach(1...12, id: \.self) { m in Text(DocumentTags.monthNames[m - 1]).tag(m) }
                }.labelsHidden().frame(width: 140)
            }
            HStack {
                Text("Day").frame(width: 44, alignment: .leading)
                TextField("1–31", text: $dayText).frame(width: 60)
                Button("Set") { if let d = Int(dayText), (1...31).contains(d) { model.applyEdit(.setDay(d), to: file) } }
                    .disabled(Int(dayText).map { !(1...31).contains($0) } ?? true)
                Button("Clear") { model.applyEdit(.setDay(nil), to: file); dayText = "" }
            }
            Toggle("Date uncertain (show year in italics)", isOn: uncertainBinding)
            HStack { Spacer(); Button("Done") { showing = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(14).frame(width: 320)
    }

    private var monthBinding: Binding<Int> {
        Binding(get: { file.tags.month?.number ?? 0 },
                set: { model.applyEdit(.setMonth($0 == 0 ? nil : $0), to: file) })
    }
    private var uncertainBinding: Binding<Bool> {
        Binding(get: { file.dateIsSpeculative },
                set: { model.applyEdit(.setDateUncertain($0), to: file) })
    }
}

/// File-tags cell — INLINE editor (no popover): the file's subject tags render as removable token
/// chips right in the row; type to add (with autocomplete from existing corpus tags), ⌫/× to remove.
/// Shows and edits `file.subjects` (priority/color/date facets have their own cells). Commits diff-and-
/// route through `TagWriter` via `model.commitSubjectEdit`. Multi-file edits still use the ⌘I editor.
struct TagsCell: View {
    @ObservedObject var model: NavigationModel
    let file: ArchiveFile
    @AppStorage("ar.listFontSize") private var listFontSize = 13.0

    var body: some View {
        SubjectTokenField(
            subjects: file.subjects,
            suggestions: model.allSubjects,
            fontSize: listFontSize,
            commit: { base, edited in model.commitSubjectEdit(from: base, to: edited, for: file) }
        )
        .help("Edit tags inline: type to add (autocompletes existing tags), ⌫ or × to remove · ⌘I edits several at once")
    }
}

/// Read-only per-row badge that flags a *non-standard PDF* — one that couldn't be opened, or opened
/// with no selectable text. A separate `@ObservedObject` view (not just a cell closure) so it re-renders
/// when the async content index folds in detection flags, sidestepping `Table`'s row-diff skip. Empty
/// (no badge) for standard files or files the index hasn't scanned yet. Never triggers a write.
struct WarningBadgeCell: View {
    @ObservedObject var model: NavigationModel
    let file: ArchiveFile
    var body: some View {
        if let status = model.formatStatus(for: file.url.path), status.needsAttention {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(status.label)
                .accessibilityLabel("Needs attention: \(status.label)")
        }
    }
}
