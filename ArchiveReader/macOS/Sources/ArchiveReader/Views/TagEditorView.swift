import SwiftUI
import ArchiveCore

/// Tag editor for the current selection (single file or group). Every control applies immediately
/// via `NavigationModel.applyEdit` → `TagWriter` (delta-based, verified, grouped-undoable). Group
/// edits show Finder-style tri-state: subjects on all vs. some; facets show "(mixed)" when they differ.
struct TagEditorView: View {
    @ObservedObject var model: NavigationModel
    @Environment(\.dismiss) private var dismiss
    @State private var subjectDraft = ""
    @State private var yearDraft = ""
    @State private var dayDraft = ""
    @State private var noteDraft = ""

    var body: some View {
        let s = model.groupSummary
        VStack(spacing: 0) {
            HStack {
                Text(s.count == 1 ? "Edit Tags" : "Edit Tags — \(s.count) files").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    subjectsSection(s)
                    Divider()
                    dateSection(s)
                    Divider()
                    prioritySection(s)
                    Divider()
                    colorSection(s)
                    Divider()
                    readStateSection(s)
                    Divider()
                    notesSection(s)
                }
                .padding()
            }
        }
        .frame(width: 480, height: 620)
    }

    // MARK: Subjects

    @ViewBuilder private func subjectsSection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Subjects")
            if s.subjectsOnAll.isEmpty && s.subjectsOnSome.isEmpty {
                Text("None").foregroundStyle(.secondary).font(.callout)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(s.subjectsOnAll, id: \.self) { chip($0, partial: false) }
                    ForEach(s.subjectsOnSome, id: \.self) { chip($0, partial: true) }
                }
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
                Text("Faded tags are on some, not all, selected files.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ subject: String, partial: Bool) -> some View {
        Button { model.applyEdit(.removeSubject(subject)) } label: {
            HStack(spacing: 3) { Text(subject); Image(systemName: "xmark.circle.fill") }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .opacity(partial ? 0.55 : 1)
        .help("Remove “\(subject)”")
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
                Menu(monthLabel(s)) {
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
                Button("Mark Uncertain") { model.applyEdit(.setDateUncertain(true)) }
                    .tint(allUncertain ? .accentColor : nil)
                Button("Clear Uncertain") { model.applyEdit(.setDateUncertain(false)) }
            }
        }
    }

    // MARK: Priority

    @ViewBuilder private func prioritySection(_ s: GroupTagSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Priority" + (s.commonPriority == nil ? "  (mixed)" : ""))
            HStack {
                facetButton("None", current: s.commonPriority == .some(nil)) { model.applyEdit(.setPriority(nil)) }
                ForEach([7, 8, 9, 10], id: \.self) { p in
                    facetButton("P\(p)", current: s.commonPriority == .some(p)) { model.applyEdit(.setPriority(p)) }
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

    @ViewBuilder private func notesSection(_ s: GroupTagSummary) -> some View {
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

    private func facetButton(_ label: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .tint(current ? .accentColor : nil)
    }

    private func yearPlaceholder(_ s: GroupTagSummary) -> String {
        switch s.commonYear {
        case .some(.some(let y)): return String(y)
        case .some(.none): return "none"
        case .none: return "mixed"
        }
    }

    private func monthLabel(_ s: GroupTagSummary) -> String {
        // commonYear-style is not tracked for month; show a neutral prompt.
        "Set month…"
    }
}
