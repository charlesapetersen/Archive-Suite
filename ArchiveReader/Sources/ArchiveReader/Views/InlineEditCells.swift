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
            yearText = file.tags.year.map(String.init) ?? ""
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
                Button("Set") { model.applyEdit(.setYear(Int(yearText)), to: file) }
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
                Button("Set") { model.applyEdit(.setDay(Int(dayText)), to: file) }
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

/// File-tags cell — click to add/remove this file's subject tags in a popover.
struct TagsCell: View {
    @ObservedObject var model: NavigationModel
    let file: ArchiveFile
    @State private var showing = false
    @State private var draft = ""

    var body: some View {
        Button { showing = true } label: {
            Text(file.tags.topicalTags.joined(separator: ", "))
                .lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Click to edit this file's tags")
        .popover(isPresented: $showing) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit tags").font(.headline)
            Text(file.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if file.subjects.isEmpty {
                Text("No tags yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(file.subjects, id: \.self) { s in
                        Button { model.applyEdit(.removeSubject(s), to: file) } label: {
                            Label(s, systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon)
                        }
                        .controlSize(.small)
                        .help("Remove “\(s)”")
                    }
                }
            }
            HStack {
                TextField("Add tag…", text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack { Spacer(); Button("Done") { showing = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(14).frame(width: 340)
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.applyEdit(.addSubject(t), to: file)
        draft = ""
    }
}
