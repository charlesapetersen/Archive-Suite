import SwiftUI
import ArchiveCore
import ArchiveCoreUI

/// W47.ct-reader-view: where one file sits in its archive, each value with its state, as the Inspector's Checks show
/// item fields (`FieldStatusRow`, `FieldStatusPolicy.container`). Read only: a value is corrected or confirmed in the
/// container editor (W47.ct-reader-edit), so the rows have no check button. Sources that disagree are listed with
/// each value and where it came from; nothing settles them here.
struct ContainerSection: View {
    let detail: ContainerDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Container").font(.subheadline.bold())
            if let detail {
                ForEach(detail.rows, id: \.field) { row in
                    FieldStatusRow(name: row.field.label, value: row.text, status: row.status,
                                   identifier: "ar.container.\(row.field.rawValue)", onToggle: nil)
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ar.container")
    }
}

/// The level map (Route B), offered once when a root is first added and from File ▸ Container Levels…: what each
/// depth of folders below the archive's main folder names, pre-filled from the folder names. Nothing is written until
/// Save; Not Now writes nothing.
struct ContainerLevelsSheet: View {
    @State var draft: ContainerLevelsDraft
    let error: String?
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
                    .accessibilityIdentifier("ar.containerLevels.save")
            }
        }
        .padding(20)
        .frame(width: 560)
        .accessibilityIdentifier("ar.containerLevels")
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
