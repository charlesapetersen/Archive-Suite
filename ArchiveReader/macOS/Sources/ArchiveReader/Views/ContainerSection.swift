import SwiftUI
import ArchiveCore
import ArchiveCoreUI

/// W47.ct-reader-view: where one file sits in its archive, each value with its state, as the Inspector's Checks show
/// item fields (`FieldStatusRow`, `FieldStatusPolicy.container`). Sources that disagree are listed with each value and
/// where it came from; nothing settles them on its own.
///
/// W47.ct-reader-edit: the one place a container is corrected. Each value can be changed, confirmed, set to "none
/// here" or given a standard name; an edit goes to the run that gives the value, so every file under it follows, and
/// the row says which files that is. The folder's warnings are listed below, each with the file it starts at.
struct ContainerSection: View {
    let detail: ContainerDetail?
    var editor: ContainerEditorInfo?
    var error: String?
    var saving = false
    var onEdit: (ContainerField, ContainerFieldEdit) -> Void = { _, _ in }
    var onName: (ContainerField, String, String) -> Void = { _, _, _ in }
    var onShowWarning: (ContainerWarningRow) -> Void = { _ in }

    /// The field being typed into, and whether it is its standard name rather than its value.
    @State private var editing: ContainerField?
    @State private var naming = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Container").font(.subheadline.bold())
                Spacer()
                if editor != nil { addMenu }
            }
            if let detail {
                ForEach(detail.rows, id: \.field) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        FieldStatusRow(name: row.field.label, value: row.text, status: row.status,
                                       identifier: "ar.container.\(row.field.rawValue)", onToggle: nil)
                        if editor != nil {
                            if editing == row.field { editorField(row.field) } else { rowMenu(row) }
                        }
                    }
                }
                ForEach(detail.disagreements, id: \.field) { d in
                    Label {
                        Text("The sources disagree. \(d.sentence)").font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ar.container.disagreement.\(d.field.rawValue)")
                }
            } else {
                Text("No box, folder or collection is recorded for this file.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let field = editing, !(detail?.rows.contains { $0.field == field } ?? false) {
                Text(field.label).font(.callout).foregroundStyle(.secondary)
                editorField(field)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ar.container.error")
            }
            if let warnings = editor?.warnings, !warnings.isEmpty { warningList(warnings) }
        }
    }

    private func rowMenu(_ row: ContainerDetailRow) -> some View {
        let f = row.field
        let written = editor?.written[f]
        return Menu("Edit") {
            Button("Change…") { begin(f, naming: false, text: written ?? row.text) }
            if editor?.unconfirmed.contains(f) == true, let written {
                Button("Confirm “\(row.text)”") { onEdit(f, .set(written)) }
            }
            Button("None Here") { onEdit(f, .noneHere) }
                .help("Say this file has no \(f.label.lowercased()), hiding what the labels and folders give.")
            if editor?.userHeld.contains(f) == true {
                Button("Remove Your Value") { onEdit(f, .remove) }
            }
            if let written {
                Divider()
                Button("Use a Standard Name…") { begin(f, naming: true, text: row.text) }
                if editor?.byStandardName.contains(f) == true {
                    Button("Stop Using the Standard Name “\(row.text)”") { onName(f, written, "") }
                        .help("Removes this standard name and every wording it gathered; each is shown as written again.")
                }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .disabled(saving)
        .help("Change or confirm the \(f.label.lowercased()) for \(editor?.scopes[f] ?? "this file").")
        .accessibilityIdentifier("ar.container.\(f.rawValue).edit")
    }

    private var addMenu: some View {
        let shown = Set(detail?.rows.map(\.field) ?? [])
        return Menu("Add") {
            ForEach(ContainerField.allCases.filter { !shown.contains($0) }, id: \.self) { f in
                Button(f.label) { begin(f, naming: false, text: "") }
            }
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .disabled(saving)
        .help("Add a repository, collection, box, folder or other value for this file and the files with it.")
        .accessibilityIdentifier("ar.container.add")
    }

    private func editorField(_ field: ContainerField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(naming ? "Standard name" : field.label, text: $draft)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .onSubmit { commit(field) }
                    .accessibilityIdentifier("ar.container.\(field.rawValue).field")
                Button("Save") { commit(field) }
                    .controlSize(.small).disabled(saving)
                    .accessibilityIdentifier("ar.container.\(field.rawValue).save")
                Button("Cancel") { editing = nil }
                    .controlSize(.small)
            }
            Text(naming
                 ? "Every file whose \(field.label.lowercased()) is written “\(editor?.written[field] ?? "")”, or a "
                   + "wording that matches it, shows this name. Leave it empty to stop using one."
                 : "Applies to \(editor?.scopes[field] ?? "this file").")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ar.container.\(field.rawValue).scope")
        }
    }

    private func warningList(_ warnings: [ContainerWarningRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Warnings in this folder").font(.callout.bold())
            ForEach(Array(warnings.prefix(Self.maxWarnings).enumerated()), id: \.offset) { i, w in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(w.text).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Button("Show") { onShowWarning(w) }
                        .controlSize(.small)
                        .help("Select “\(w.start)”.")
                        .accessibilityIdentifier("ar.container.warning.\(i).show")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("ar.container.warning.\(i)")
            }
            if warnings.count > Self.maxWarnings {
                Text("and \(warnings.count - Self.maxWarnings) more.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The most warnings listed for one folder.
    static let maxWarnings = 20

    private func begin(_ field: ContainerField, naming: Bool, text: String) {
        self.naming = naming
        draft = text
        editing = field
    }

    private func commit(_ field: ContainerField) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if naming {
            if let written = editor?.written[field] { onName(field, written, text) }
        } else if text.isEmpty {
            return
        } else {
            onEdit(field, .set(text))
        }
        editing = nil
    }
}

/// W47.ct-reader-edit, "set for selection": one field given one value for the selected files and no others. Runs
/// are split at the selection's ends, so the files before and after keep what they had.
struct ContainerSelectionSection: View {
    let count: Int
    var error: String?
    var saving = false
    let onSet: (ContainerField, String) -> Void

    @State private var field: ContainerField = .container
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Container").font(.subheadline.bold())
            HStack {
                Picker("Field", selection: $field) {
                    ForEach(ContainerEdits.selectionFields, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 160)
                .accessibilityIdentifier("ar.containerSelection.field")
                TextField(field.label, text: $draft)
                    .textFieldStyle(.roundedBorder).font(.callout)
                    .onSubmit(set)
                    .accessibilityIdentifier("ar.containerSelection.value")
            }
            HStack {
                Button("Set for \(count) Files", action: set)
                    .controlSize(.small)
                    .disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("ar.containerSelection.set")
                Spacer()
            }
            Text("The selected files get this \(field.label.lowercased()) and no other file does: a run starts at the "
                 + "first selected file in each folder and ends after the last, so the files around them keep theirs.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ar.container.error")
            }
        }
    }

    private func set() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSet(field, text)
        draft = ""
    }
}

/// The level map (Route B), offered once when a root is first added and from File ▸ Container Levels…: what each
/// depth of folders below the archive's main folder names, pre-filled from the folder names. Nothing is written until
/// Save; Not Now writes nothing.
struct ContainerLevelsSheet: View {
    @State var draft: ContainerLevelsDraft
    let error: String?
    let saving: Bool
    let onSave: (ContainerLevelsDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What do this archive's folder levels name?").font(.headline)
            Text("The Reader read these from the folder names. Check each level, then save: the Container column and "
                 + "its filters show what the folders name. Saving writes one small file, "
                 + "“.archivesuite/container-levels.json”, in the archive folder; no document is changed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(draft.map.levels.indices, id: \.self) { depth in
                        levelRow(depth)
                    }
                    if !draft.workflowFolders.isEmpty { skippedRows }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 360)
            if let sample = draft.sampleDirectory {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A file in “\(sample.joined(separator: "/"))” would show:").font(.caption)
                    Text(draft.preview(sample)).font(.caption.bold()).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ar.containerLevels.preview")
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .accessibilityIdentifier("ar.containerLevels.error")
            }
            HStack {
                Spacer()
                Button("Not Now", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .help("Close without saving. File ▸ Container Levels… opens this again.")
                    .accessibilityIdentifier("ar.containerLevels.cancel")
                Button("Save Levels") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
                    .accessibilityIdentifier("ar.containerLevels.save")
            }
        }
        .padding(20)
        .frame(width: 560)
        // No identifier on the whole sheet: on a stack it would replace its children's (KNOWN_ISSUES).
    }

    private func levelRow(_ depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Level \(depth + 1)").font(.callout.bold())
                let examples = depth < draft.examples.count ? draft.examples[depth] : []
                let count = depth < draft.folderCounts.count ? draft.folderCounts[depth] : 0
                Text(examples.isEmpty ? "No folders at this level"
                     : "\(count) folder\(count == 1 ? "" : "s"), e.g. " + examples.map { "“\($0)”" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Picker("Level \(depth + 1)", selection: $draft.map.levels[depth]) {
                ForEach(ContainerLevelsDraft.roles, id: \.self) { role in
                    Text(ContainerLevelsDraft.roleName(role)).tag(role)
                }
            }
            .labelsHidden()
            .frame(width: 200)
            .accessibilityIdentifier("ar.containerLevels.level\(depth + 1)")
        }
    }

    private var skippedRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Workflow folders, skipped").font(.callout.bold())
            Text("Folders such as “05 Final Tagging” name a stage of work, not a level; the folders inside them take "
                 + "their place.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(draft.workflowFolders, id: \.self) { path in
                HStack {
                    Toggle(path, isOn: Binding(get: { draft.map.overrides[path] != nil },
                                               set: { draft.setSkipped(path, $0) }))
                        .font(.caption)
                    Spacer(minLength: 8)
                    if draft.map.overrides[path] != nil {
                        Picker("Folders inside", selection: Binding(
                            get: { draft.map.overrides[path]?.children },
                            set: { draft.setChildren(path, $0) })) {
                            Text("Take its level").tag(ContainerLevelRole?.none)
                            ForEach(draft.childRoles, id: \.self) { role in
                                Text("Are: \(ContainerLevelsDraft.roleName(role))").tag(ContainerLevelRole?.some(role))
                            }
                        }
                        .frame(width: 200)
                        .help("What the folders inside this workflow folder are")
                    }
                }
            }
        }
    }
}
