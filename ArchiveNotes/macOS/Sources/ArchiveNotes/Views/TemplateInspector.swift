import SwiftUI

/// The inspector for the template selected in the templates manager (W40.fix-notes-template-fields, notes-2 row 18:
/// the owner could not see how to assign a template to a folder, and the inspector showed nothing for a template).
/// It holds the folders the template is assigned to, with a menu to assign it to another, and the fields a note made
/// from it starts with: date, quality and tags. Each field applies as a note's does (on Return or on leaving
/// it), through `NotesModel`'s template setters; a template's own file gets no Finder tags.
struct TemplateInspector: View {
    @ObservedObject var model: NotesModel
    let template: Template

    @State private var dateText = ""
    /// Which template the date text belongs to and what was last applied, as in `NoteMetadataInspector`,
    /// so leaving a field writes only a real edit, and only to the template it was typed for.
    @State private var dateApplied: (id: UUID?, text: String, stored: String?) = (nil, "", nil)
    @FocusState private var dateFocused: Bool
    @State private var tagDraft = ""

    static let fieldsExplanation = "A new note made from this template starts with these, and with its body. "
        + "Changing them later does not change notes already made."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            foldersSection
            Divider()
            Text("New notes start with").font(.subheadline.bold())
                .accessibilityIdentifier("an.template.fields.heading")
            Text(Self.fieldsExplanation)
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            dateSection
            Divider()
            qualitySection
            Divider()
            tagsSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { seed() }
        .onChange(of: template.id) { applyDate(); seed() }
        .onChange(of: dateFocused) { was, _ in if was { applyDate() } }
        // A value saved elsewhere (the other window's inspector) shows here, unless this field holds an edit.
        .onChange(of: template.date) {
            guard !dateFocused, dateText == dateApplied.text else { return }
            seedDate()
        }
        .onDisappear { applyDate() }
    }

    // MARK: Folders

    private var foldersSection: some View {
        let assigned = model.foldersAssigned(template.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Used in folders").font(.subheadline.bold())
                .accessibilityIdentifier("an.template.folders.heading")
            Text(assigned.isEmpty
                 ? "Not assigned to a folder. Assign it, and New \(kindWord) in that folder and its subfolders starts from it."
                 : "New \(kindWord) in these folders and their subfolders starts from it, unless a subfolder has its own.")
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(assigned) { folder in
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(folder.name).lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        Task { await model.assignTemplate(nil, to: folder.id) }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop using it in \(folder.name)")
                        .accessibilityLabel("Stop using it in \(folder.name)")
                        .accessibilityIdentifier("an.template.folders.remove.\(folder.id.uuidString)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("an.template.folders.row.\(folder.id.uuidString)")
            }
            TemplateFolderMenu(model: model, templateID: template.id, title: "Assign to Folder")
                .fixedSize()
                .accessibilityIdentifier("an.template.folders.assign")
        }
    }

    private var kindWord: String { template.kind == .extract ? "Extract" : "Note" }

    // MARK: Fields

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Date").font(.subheadline)
            TextField("e.g. 1968, 1960s, March 1968, 12 March 1968", text: $dateText)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                .focused($dateFocused)
                .onSubmit { applyDate() }
                .help("Applies when you leave the field; empty it for no date.")
                .accessibilityLabel("Template date")
                .accessibilityIdentifier("an.template.date.field")
            if case .unreadable(let why) = DateFieldEntry.parse(dateText) {
                Text(why).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("an.template.date.unreadable")
            }
            Toggle("Date uncertain (shown in italics)", isOn: Binding(
                get: { template.dateUncertain },
                set: { v in let id = template.id; Task { await model.setTemplateDateUncertain(v, for: id) } }))
                .disabled(template.date == nil)
                .accessibilityIdentifier("an.template.date.uncertain")
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality").font(.subheadline)
            QualityFacetRow(quality: template.quality) { q in
                let id = template.id
                Task { await model.setTemplateQuality(q, for: id) }
            }
            .accessibilityIdentifier("an.template.quality")
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.subheadline)
            // The field hands back the whole list; it is sent as the tags added and removed, so an edit made before
            // the last one has saved is not lost (the list shown is the saved one).
            NoteTagChipsField(tags: Binding(get: { template.tags }, set: { tags in
                                  let (id, old) = (template.id, template.tags)
                                  let added = tags.filter { !old.contains($0) }
                                  let removed = old.filter { !tags.contains($0) }
                                  Task {
                                      for tag in added { await model.addTemplateTag(tag, to: id) }
                                      for tag in removed { await model.removeTemplateTag(tag, from: id) }
                                  }
                              }),
                              draft: $tagDraft, placeholder: "Add tag…",
                              identifier: "an.template.tags.field", chipIdentifier: "an.template.tags.chip",
                              suggestions: { NoteTagChipsField.suggestions(in: model.allItems) })
        }
    }

    // MARK: State ⇄ store

    private func seed() { seedDate() }

    private func seedDate() {
        dateText = DateFieldEntry.seedText(storedDate: template.date, precision: template.datePrecision,
                                           active: nil).text
        dateApplied = (template.id, dateText, template.date)
    }

    private func applyDate() {
        guard let id = dateApplied.id, dateText != dateApplied.text else { return }
        let (value, precision) = DateFieldEntry.commit(typed: DateFieldEntry.parse(dateText), calendar: .standard,
                                                       storedDate: dateApplied.stored)
        guard case .write(let date) = value else { return }
        dateApplied.text = dateText
        dateApplied.stored = date
        Task { await model.setTemplateDate(date, precision: precision, for: id) }
    }

}

/// A menu of every folder, indented as in the sidebar, that assigns `templateID` to the folder chosen; a ✓ marks the
/// folders it is already assigned to directly. Shared by the template inspector and the templates manager's row menu,
/// so assigning is offered from the template as well as from the folder (W40.fix-notes-template-fields).
struct TemplateFolderMenu: View {
    @ObservedObject var model: NotesModel
    let templateID: UUID
    let title: String

    var body: some View {
        Menu(title) {
            let folders = model.assignableFolders
            if folders.isEmpty { Text("No folders yet") }
            ForEach(folders, id: \.node.id) { entry in
                let assigned = model.assignedTemplateID(entry.node.id) == templateID
                Button {
                    Task { await model.assignTemplate(assigned ? nil : templateID, to: entry.node.id) }
                } label: {
                    Label {
                        Text(String(repeating: "    ", count: entry.depth) + entry.node.name)
                    } icon: { if assigned { Image(systemName: "checkmark") } }
                }
            }
        }
    }
}

/// The inspector for the selected folder when no note is selected: which template New uses there, chosen in place
/// (W40.fix-notes-template-fields). The same choice as the folder's right-click Template ▸ menu.
struct FolderTemplateInspector: View {
    @ObservedObject var model: NotesModel
    let folder: NotesFolderNode
    let showTemplates: () -> Void

    var body: some View {
        let own = model.assignedTemplateID(folder.id)
        let effective = model.effectiveTemplate(for: folder.id)
        VStack(alignment: .leading, spacing: 8) {
            Label(folder.name, systemImage: "folder").font(.headline).lineLimit(1)
                .accessibilityIdentifier("an.folder.inspector.name")
            Divider()
            Text("Template").font(.subheadline.bold())
            Picker("Template", selection: Binding<UUID?>(
                get: { own },
                set: { id in let folderID = folder.id; Task { await model.assignTemplate(id, to: folderID) } })) {
                Text(own == nil && effective != nil ? "Inherited" : "None").tag(UUID?.none)
                ForEach(model.templates) { t in
                    Text(t.name.isEmpty ? "Untitled" : t.name).tag(UUID?.some(t.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityIdentifier("an.folder.inspector.template")
            Text(Self.templateNote(own: own, effective: effective, hasTemplates: !model.templates.isEmpty))
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("an.folder.inspector.template.note")
            Button(model.templates.isEmpty ? "New Template…" : "Edit Templates…") { showTemplates() }
                .accessibilityIdentifier("an.folder.inspector.manageTemplates")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What New does in the folder, said under the picker.
    static func templateNote(own: UUID?, effective: Template?, hasTemplates: Bool) -> String {
        if own != nil, let effective {
            return "New in this folder and its subfolders starts from “\(effective.name)”, unless a subfolder has its own."
        }
        if let effective { return "Inherited from a parent folder: New here starts from “\(effective.name)”." }
        if !hasTemplates { return "No templates yet. Make one, then choose it here." }
        return "New in this folder starts blank. Choose a template to start each new note from it."
    }
}
