import SwiftUI
import ArchiveCore

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

/// Document-date cell — click to edit year / month / day / uncertain in a popover, for this file.
struct DateCell: View {
    @ObservedObject var model: NavigationModel
    let file: ArchiveFile
    @State private var showing = false
    @State private var yearText = ""
    @State private var dayText = ""
    @State private var sentWithText = ""

    var body: some View {
        Button {
            yearText = file.tags.year.map(String.init) ?? file.tags.decadeToken ?? ""
            dayText  = file.tags.day.map(String.init) ?? ""
            sentWithText = file.tags.sentWith?.wireValue ?? ""
            showing = true
        } label: {
            Text(file.dateCellText)
                .italic(file.dateCellIsSpeculative)
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
            Divider()
            // W37: the covering letter's date, for an enclosure that has its own date above.
            HStack {
                Text("Sent with").frame(width: 64, alignment: .leading)
                TextField("1958-03-12", text: $sentWithText).frame(width: 90)
                    .help("The date of the letter this was enclosed with: 1958, 1958-03, 1958-03-12 or 1950s")
                Button("Set") { if let d = parsedSentWith { model.applyEdit(.setSentWith(d), to: file) } }
                    .disabled(parsedSentWith == nil)
                Button("Clear") { model.applyEdit(.setSentWith(nil), to: file); sentWithText = "" }
                    .disabled(file.tags.sentWith == nil)
            }
            if !sentWithText.isEmpty, parsedSentWith == nil {
                Text("Use 1958, 1958-03, 1958-03-12 or 1950s").font(.caption).foregroundStyle(.red)
            }
            Toggle("Sent-with date uncertain", isOn: sentWithUncertainBinding)
                .disabled(file.tags.sentWith == nil)
            HStack { Spacer(); Button("Done") { showing = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(14).frame(width: 320)
    }

    private var monthBinding: Binding<Int> {
        Binding(get: { file.tags.month?.number ?? 0 },
                set: { model.applyEdit(.setMonth($0 == 0 ? nil : $0), to: file) })
    }
    private var parsedSentWith: ArchiveDate? {
        ArchiveDate.parse(wireValue: sentWithText.trimmingCharacters(in: .whitespaces))
    }
    private var sentWithUncertainBinding: Binding<Bool> {
        Binding(get: { file.tags.sentWithUncertain },
                set: { model.applyEdit(.setSentWithUncertain($0), to: file) })
    }
    private var uncertainBinding: Binding<Bool> {
        Binding(get: { file.dateIsSpeculative },
                set: { model.applyEdit(.setDateUncertain($0), to: file) })
    }
}
