import SwiftUI
import ArchiveCore

/// Tag editor for the current selection (single file or group). Every control applies immediately
/// via `NavigationModel.applyEdit` → `TagWriter` (delta-based, verified, grouped-undoable). Group
/// edits show Finder-style tri-state: subjects on all vs. some; facets show "(mixed)" when they differ.
struct TagEditorView: View {
    @ObservedObject var model: NavigationModel
    /// From `SheetSizing.fitted` over the presenting window, so the sheet never overhangs it (W40.fix-reader-tag-editor-chips).
    var size: CGSize = TagEditorView.preferredSize
    static let preferredSize = CGSize(width: 480, height: 620)
    @Environment(\.dismiss) private var dismiss
    @State private var subjectDraft = ""
    @State private var yearDraft = ""
    @State private var dayDraft = ""
    @State private var sentWithDraft = ""
    @State private var noteDraft = ""

    var body: some View {
        let s = model.groupSummary
        VStack(spacing: 0) {
            HStack {
                Text(s.count == 1 ? "Edit Tags" : "Edit Tags — \(s.count) files").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ar.tagEditor.done")
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    subjectsSection(s)
                    Divider()
                    dateSection(s)
                    Divider()
                    qualitySection(s)
                    Divider()
                    colorSection(s)
                    Divider()
                    readStateSection(s)
                    Divider()
                    notesSection()
                }
                .padding()
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Subjects

    @ViewBuilder private func subjectsSection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Subjects")
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
                TextField("Add subject…", text: $subjectDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSubject)
                    .accessibilityIdentifier("ar.tagEditor.addSubject")
                Button("Add", action: addSubject)
                    .disabled(subjectDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("ar.tagEditor.addSubjectButton")
            }
            let dups = model.nearDuplicateSubjects(of: subjectDraft)
            if !dups.isEmpty {
                Label("Existing tag differs only by case: \(dups.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !s.subjectsOnSome.isEmpty {
                Text("Faded, dashed tags are on some, not all, selected files.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A removable subject. A partial one (on some of the selected files) is drawn faded with a dashed outline
    /// and no fill, so it reads as partial on its own: when every chip was partial, a uniform fade showed nothing.
    private func chip(_ subject: String, partial: Bool) -> some View {
        Button { model.applyEdit(.removeSubject(subject)) } label: {
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
        model.applyEdit(.addSubject(t))
        subjectDraft = ""
    }

    // MARK: Date

    @ViewBuilder private func dateSection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Date")
            HStack {
                Text("Year").frame(width: 52, alignment: .leading)
                TextField(yearPlaceholder(s), text: $yearDraft).textFieldStyle(.roundedBorder).frame(width: 90)
                Button("Set") { if let y = Int(yearDraft), (100...9999).contains(y) { model.applyEdit(.setYear(y)) } }
                    .disabled(Int(yearDraft).map { !(100...9999).contains($0) } ?? true)
                Button("Clear") { model.applyEdit(.setYear(nil)); yearDraft = "" }
            }
            HStack {
                Text("Month").frame(width: 52, alignment: .leading)
                Menu(monthLabel()) {
                    Button("None") { model.applyEdit(.setMonth(nil)) }
                    ForEach(1...12, id: \.self) { m in
                        Button(TagEditing.monthToken(m)) { model.applyEdit(.setMonth(m)) }
                    }
                }
                .frame(width: 150)
            }
            HStack {
                Text("Day").frame(width: 52, alignment: .leading)
                TextField("1–31", text: $dayDraft).textFieldStyle(.roundedBorder).frame(width: 90)
                Button("Set") { if let d = Int(dayDraft), (1...31).contains(d) { model.applyEdit(.setDay(d)) } }
                    .disabled(Int(dayDraft).map { !(1...31).contains($0) } ?? true)
                Button("Clear") { model.applyEdit(.setDay(nil)); dayDraft = "" }
            }
            HStack {
                Text("Uncertain").frame(width: 68, alignment: .leading)
                let allUncertain = !model.selectedFiles.isEmpty && model.selectedFiles.allSatisfy(\.tags.dateUncertain)
                facetButton("Mark Uncertain", current: allUncertain) { model.applyEdit(.setDateUncertain(true)) }
                Button("Clear Uncertain") { model.applyEdit(.setDateUncertain(false)) }
            }
            Divider()
            // W37: the covering letter's date, for an enclosure that has its own date above. The sheet is the one
            // date editor (owner, 2026-10-12), so Sent-With lives here too (W40.fix-reader-sent-with-date).
            HStack {
                Text("Sent with").frame(width: 68, alignment: .leading)
                TextField(sentWithPlaceholder(), text: $sentWithDraft).textFieldStyle(.roundedBorder).frame(width: 110)
                    .onSubmit(setSentWith)
                    .help("The date of the letter this was enclosed with: 1958, 1958-03, 1958-03-12 or 1950s")
                    .accessibilityIdentifier("ar.tagEditor.sentWith")
                Button("Set", action: setSentWith)
                    .disabled(parsedSentWith == nil)
                    .accessibilityIdentifier("ar.tagEditor.sentWithSet")
                // Also clears a stray uncertain flag left on a file with no Sent-With date.
                Button("Clear") { model.applyEdit(.setSentWith(nil)); sentWithDraft = "" }
                    .disabled(!model.selectedFiles.contains { $0.tags.sentWith != nil || $0.tags.sentWithUncertain })
                    .accessibilityIdentifier("ar.tagEditor.sentWithClear")
            }
            if !sentWithDraft.trimmingCharacters(in: .whitespaces).isEmpty, parsedSentWith == nil {
                Text("Use 1958, 1958-03, 1958-03-12 or 1950s").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("Uncertain").frame(width: 68, alignment: .leading)
                let dated = model.selectedFiles.filter { $0.tags.sentWith != nil }
                let allUncertain = !dated.isEmpty && dated.allSatisfy(\.tags.sentWithUncertain)
                facetButton("Mark Uncertain", current: allUncertain) { model.applyEdit(.setSentWithUncertain(true)) }
                    .disabled(dated.isEmpty)
                    .accessibilityIdentifier("ar.tagEditor.sentWithUncertain")
                Button("Clear Uncertain") { model.applyEdit(.setSentWithUncertain(false)) }
                    .disabled(!model.selectedFiles.contains(where: \.tags.sentWithUncertain))
            }
        }
    }

    private var parsedSentWith: ArchiveDate? {
        ArchiveDate.parse(wireValue: sentWithDraft.trimmingCharacters(in: .whitespaces))
    }

    private func setSentWith() {
        guard let d = parsedSentWith else { return }
        model.applyEdit(.setSentWith(d))
        sentWithDraft = ""
    }

    private func sentWithPlaceholder() -> String {
        let values = Set(model.selectedFiles.map { $0.tags.sentWith?.wireValue })
        guard values.count == 1, let only = values.first else { return values.isEmpty ? "1958-03-12" : "mixed" }
        return only ?? "1958-03-12"
    }

    // MARK: Quality

    @ViewBuilder private func qualitySection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Quality" + (s.commonQuality == nil ? "  (mixed)" : ""))
            HStack {
                facetButton("None", current: s.commonQuality == .some(nil)) { model.applyEdit(.setQuality(nil)) }
                ForEach([1, 2, 3], id: \.self) { q in
                    facetButton("Q\(q)", current: s.commonQuality == .some(q)) { model.applyEdit(.setQuality(q)) }
                }
            }
        }
    }

    // MARK: Color

    @ViewBuilder private func colorSection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Color / marker" + (s.commonColor == nil ? "  (mixed)" : ""))
            HStack {
                facetButton("None", current: s.commonColor == .some(nil)) { model.applyEdit(.setColor(nil)) }
                facetButton("Box (Red)", current: s.commonColor == .some(.box)) { model.applyEdit(.setColor(.box)) }
                facetButton("Folder (Purple)", current: s.commonColor == .some(.folder)) { model.applyEdit(.setColor(.folder)) }
            }
        }
    }

    // MARK: Read state

    @ViewBuilder private func readStateSection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Read state" + (s.commonReadState == nil ? "  (mixed)" : ""))
            HStack {
                facetButton("Read", current: s.commonReadState == .some(.read)) { model.mark(.read) }
                facetButton("Unread", current: s.commonReadState == .some(.unread)) { model.mark(.unread) }
            }
        }
    }

    // MARK: Notes & flag (app-side, never written to the file)

    @ViewBuilder private func notesSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Notes & flag")
            Text("Stored in the app — never written to the file.").font(.caption).foregroundStyle(.secondary)
            Button { model.toggleFlagSelection() } label: { Label("Toggle flag", systemImage: "flag") }
            if model.selectedFiles.count == 1, let f = model.selectedFiles.first {
                TextField("Note…", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .onAppear { noteDraft = model.notes.annotation(for: f.url.path).note }
                Button("Save note") { model.setNote(noteDraft, forPath: f.url.path) }
            } else {
                Text("Select a single file to edit its note.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

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
