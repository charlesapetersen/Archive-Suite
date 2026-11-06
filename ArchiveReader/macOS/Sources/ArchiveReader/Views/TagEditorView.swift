import SwiftUI
import ArchiveCore
import ArchiveCoreUI

/// Tag editor for the current selection (single file or group), or for the document window's open file. Every control applies immediately
/// via `NavigationModel.applyEdit` → `TagWriter` (delta-based, verified, grouped-undoable). Group
/// edits show Finder-style tri-state: subjects on all vs. some; facets show "(mixed)" when they differ.
struct TagEditorView: View {
    @ObservedObject var model: NavigationModel
    /// From `SheetSizing.fitted` over the presenting window, so the sheet never overhangs it (W40.fix-reader-tag-editor-chips).
    var size: CGSize = TagEditorView.preferredSize
    static let preferredSize = CGSize(width: 480, height: 620)
    /// Set by the document window: edit these files rather than the list's selection
    /// (W40.fix-reader-menus-follow-window). Every write still goes through `NavigationModel` → `TagWriter`.
    var targetPaths: [String]? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var subjectDraft = ""
    @State private var yearDraft = ""
    @State private var dayDraft = ""
    @State private var sentWithDraft = ""

    var body: some View {
        let files = targetFiles
        let s = targetPaths == nil ? model.groupSummary : GroupTagSummary(files.map(\.tags))
        VStack(spacing: 0) {
            HStack {
                Text(s.count == 1 ? "Edit Info" : "Edit Info — \(s.count) files").font(.headline)
                Spacer()
                // Typed text sticks, as in the list's tag field: Done adds a subject still in the field. While
                // one is being typed, Return belongs to the field, which adds it and keeps the keyboard.
                Button("Done") { addSubject(); dismiss() }
                    .keyboardShortcut(subjectDraft.isEmpty ? .defaultAction : nil)
                    .accessibilityIdentifier("ar.tagEditor.done")
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    subjectsSection(s)
                    Divider()
                    dateSection(s, files)
                    Divider()
                    qualitySection(s)
                    Divider()
                    colorSection(s)
                    Divider()
                    readStateSection(s)
                    Divider()
                    flagSection
                }
                .padding()
            }
        }
        .frame(width: size.width, height: size.height)
    }

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
            HStack {
                SubjectEntryField(draft: $subjectDraft, placeholder: "Add tag…", identifier: "ar.tagEditor.addSubject",
                                  suggestions: { let onAll = Set(s.subjectsOnAll.map(tagKey)); return model.allSubjects.filter { !onAll.contains(tagKey($0)) } },
                                  onAdd: { apply(.addSubject($0)) })
                Button("Add", action: addSubject)
                    .disabled(subjectDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("ar.tagEditor.addSubjectButton")
            }
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
            .frame(maxWidth: 420)   // a very long subject truncates rather than overrunning the sheet
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

    @ViewBuilder private func dateSection(_ s: GroupTagSummary, _ files: [ArchiveFile]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Date")
            dateAmbiguityNotice(files)
            HStack {
                Text("Year").frame(width: 52, alignment: .leading)
                TextField(yearPlaceholder(s), text: $yearDraft).textFieldStyle(.roundedBorder).frame(width: 90)
                Button("Set") { if let y = Int(yearDraft), (100...9999).contains(y) { apply(.setYear(y)) } }
                    .disabled(Int(yearDraft).map { !(100...9999).contains($0) } ?? true)
                Button("Clear") { apply(.setYear(nil)); yearDraft = "" }
            }
            HStack {
                Text("Month").frame(width: 52, alignment: .leading)
                Menu(monthLabel()) {
                    Button("None") { apply(.setMonth(nil)) }
                    ForEach(1...12, id: \.self) { m in
                        Button(TagEditing.monthToken(m)) { apply(.setMonth(m)) }
                    }
                }
                .frame(width: 150)
            }
            HStack {
                Text("Day").frame(width: 52, alignment: .leading)
                TextField("1–31", text: $dayDraft).textFieldStyle(.roundedBorder).frame(width: 90)
                Button("Set") { if let d = Int(dayDraft), (1...31).contains(d) { apply(.setDay(d)) } }
                    .disabled(Int(dayDraft).map { !(1...31).contains($0) } ?? true)
                Button("Clear") { apply(.setDay(nil)); dayDraft = "" }
            }
            HStack {
                Text("Uncertain").frame(width: 68, alignment: .leading)
                let allUncertain = !files.isEmpty && files.allSatisfy(\.tags.dateUncertain)
                facetButton("Mark Uncertain", current: allUncertain) { apply(.setDateUncertain(true)) }
                Button("Clear Uncertain") { apply(.setDateUncertain(false)) }
            }
            Divider()
            // W37: the covering letter's date, for an enclosure that has its own date above. The sheet is the one
            // date editor (owner, 2026-10-12), so Sent-With lives here too (W40.fix-reader-sent-with-date).
            HStack {
                Text("Sent with").frame(width: 68, alignment: .leading)
                TextField(sentWithPlaceholder(files), text: $sentWithDraft).textFieldStyle(.roundedBorder).frame(width: 110)
                    .onSubmit(setSentWith)
                    .help("The date of the letter this was enclosed with: 1958, 1958-03, 1958-03-12 or 1950s")
                    .accessibilityIdentifier("ar.tagEditor.sentWith")
                Button("Set", action: setSentWith)
                    .disabled(parsedSentWith == nil)
                    .accessibilityIdentifier("ar.tagEditor.sentWithSet")
                // Also clears a stray uncertain flag left on a file with no Sent-With date.
                Button("Clear") { apply(.setSentWith(nil)); sentWithDraft = "" }
                    .disabled(!files.contains { $0.tags.sentWith != nil || $0.tags.sentWithUncertain })
                    .accessibilityIdentifier("ar.tagEditor.sentWithClear")
            }
            if !sentWithDraft.trimmingCharacters(in: .whitespaces).isEmpty, parsedSentWith == nil {
                Text("Use 1958, 1958-03, 1958-03-12 or 1950s").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("Uncertain").frame(width: 68, alignment: .leading)
                let dated = files.filter { $0.tags.sentWith != nil }
                let allUncertain = !dated.isEmpty && dated.allSatisfy(\.tags.sentWithUncertain)
                facetButton("Mark Uncertain", current: allUncertain) { apply(.setSentWithUncertain(true)) }
                    .disabled(dated.isEmpty)
                    .accessibilityIdentifier("ar.tagEditor.sentWithUncertain")
                Button("Clear Uncertain") { apply(.setSentWithUncertain(false)) }
                    .disabled(!files.contains(where: \.tags.sentWithUncertain))
            }
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

    private var parsedSentWith: ArchiveDate? {
        ArchiveDate.parse(wireValue: sentWithDraft.trimmingCharacters(in: .whitespaces))
    }

    private func setSentWith() {
        guard let d = parsedSentWith else { return }
        apply(.setSentWith(d))
        sentWithDraft = ""
    }

    private func sentWithPlaceholder(_ files: [ArchiveFile]) -> String {
        let values = Set(files.map { $0.tags.sentWith?.wireValue })
        guard values.count == 1, let only = values.first else { return values.isEmpty ? "1958-03-12" : "mixed" }
        return only ?? "1958-03-12"
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

    // MARK: Color

    @ViewBuilder private func colorSection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Color / marker" + (s.commonColor == nil ? "  (mixed)" : ""))
            HStack {
                facetButton("None", current: s.commonColor == .some(nil)) { apply(.setColor(nil)) }
                facetButton("Box (Red)", current: s.commonColor == .some(.box)) { apply(.setColor(.box)) }
                facetButton("Folder (Purple)", current: s.commonColor == .some(.folder)) { apply(.setColor(.folder)) }
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

    /// The files this sheet edits: the document window's open file, else the list's selection.
    private var targetFiles: [ArchiveFile] {
        guard let targetPaths else { return model.selectedFiles }
        return model.libraryFiles(atPaths: targetPaths)
    }

    private func apply(_ op: TagEditOp) { model.applyEdit(op, paths: targetPaths) }
    private func markReadState(_ state: ReadState) { model.mark(state, paths: targetPaths) }
    private func toggleFlag() {
        if let targetPaths { model.toggleFlag(paths: targetPaths) } else { model.toggleFlagSelection() }
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

    private func yearPlaceholder(_ s: GroupTagSummary) -> String {
        switch s.commonYear {
        case .some(.some(let y)): return String(y)
        case .some(.none): return "none"
        case .none: return "mixed"
        }
    }

    private func monthLabel() -> String {
        // commonYear-style is not tracked for month; show a neutral prompt.
        "Set month…"
    }
}
