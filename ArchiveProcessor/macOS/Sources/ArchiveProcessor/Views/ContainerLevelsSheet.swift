import SwiftUI
import ArchiveCore

/// W47.ct-processor-intake — Route B in Process Files: what each level of a dropped tree's folders names, asked once
/// per output folder at Start (`SPEC/containers.md` §Route B in Process Files). Pre-filled from the folder names
/// (`ContainerLevelsDraft`, the Reader's own draft); Save writes only `<output>/.archivesuite/container-levels.json`.
/// The outputs are filed in the tree's folders either way; the map is what lets Archive Reader read them as
/// repository, collection, box and folder.
struct ContainerLevelsSheet: View {
    @State var draft: ContainerLevelsDraft
    let error: String?
    let onSave: (ContainerLevelsDraft) -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void
    /// The texts, so Tools ▸ Read Box and Folder Labels (W47.ct-backfill) can offer the map for a folder it reads.
    var intro = "The PDFs will be filed in the same folders inside the output folder. Check what each level of folders "
        + "is, then save: Archive Reader shows it as each document's repository, collection, box and folder. "
        + "Saving writes one small file, “.archivesuite/container-levels.json”, in the output folder."
    var cancelHelp = "Do not start the run."
    var skipTitle = "Start Without Saving"
    var skipHelp = "File the PDFs in the folders without saving what the levels name; Archive Reader asks later."
    var saveTitle = "Save and Start"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What do these folder levels name?").font(.headline)
            Text(intro)
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
                    Text("A PDF in “\(sample.joined(separator: "/"))” would show:").font(.caption)
                    Text(draft.preview(sample)).font(.caption.bold()).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ap.containerLevels.preview")
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .accessibilityIdentifier("ap.containerLevels.error")
            }
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .help(cancelHelp)
                    .accessibilityIdentifier("ap.containerLevels.cancel")
                Spacer()
                Button(skipTitle, action: onSkip)
                    .help(skipHelp)
                    .accessibilityIdentifier("ap.containerLevels.skip")
                Button(saveTitle) { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ap.containerLevels.save")
            }
        }
        .padding(20)
        .frame(width: 560)
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
            .accessibilityIdentifier("ap.containerLevels.level\(depth + 1)")
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
