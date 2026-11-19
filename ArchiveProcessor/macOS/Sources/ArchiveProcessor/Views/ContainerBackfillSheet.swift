import SwiftUI
import AppKit
import ArchiveCore

/// W47.ct-backfill — Tools ▸ Read Box and Folder Labels: an existing folder's box and folder photos read and proposed
/// as runs, accepted folder by folder (`ContainerBackfillModel`; `SPEC/containers.md` §Backfill).
struct ContainerBackfillSheet: View {
    @StateObject private var model: ContainerBackfillModel
    @State private var confirmingCost = false
    @State private var showingLevels = false
    let onDone: () -> Void

    /// `makeModel` runs once, when the sheet first appears (`StateObject`), not on every render of the view above.
    init(makeModel: @escaping @MainActor () -> ContainerBackfillModel = { ContainerBackfillModel() },
         onDone: @escaping () -> Void) {
        _model = StateObject(wrappedValue: makeModel())
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read Box and Folder Labels").font(.title2).fontWeight(.semibold)
            Text("For material photographed before Archive Processor: the box and folder photos in a folder are read and "
                 + "proposed as boxes and folders for the documents after them. Nothing is written until you accept a "
                 + "folder; then one small file, “.archivesuite/containers.json”, is added to that folder. The photos "
                 + "and PDFs are not changed.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            folderRow
            if model.root != nil { coloursRow }
            if let scan = model.scan { scanSummary(scan) }
            if let message = model.message {
                Label(message, systemImage: "info.circle").font(.callout)
                    .accessibilityIdentifier("ap.backfill.message")
            }
            if case .reading(let done, let total) = model.phase {
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Reading \(done) of \(total) label photos…").font(.callout)
                }
                .accessibilityIdentifier("ap.backfill.progress")
            }
            if !model.rows.isEmpty { reviewList }
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 780, height: 640)
        .alert("Read with GPT 5.6 Luna for about \(dollars(model.estimatedDollars)) more?", isPresented: $confirmingCost) {
            Button("Read") { model.startReading() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.markersToRead) label photos at about \(dollars(ContainerLabelCapture.gatewayDollarsPerLabel)) each "
                 + "through the gateway: real money. With the \(dollars(model.spentDollars)) this window has spent, that is "
                 + "above \(dollars(ContainerBackfillModel.confirmAboveDollars)). "
                 + "Reading with Vision alone is free.")
        }
        .sheet(isPresented: $showingLevels) {
            if let draft = model.levelsDraft {
                ContainerLevelsSheet(
                    draft: draft, error: model.levelsError,
                    onSave: { edited in
                        model.saveLevels(edited)
                        if model.levelsError == nil { showingLevels = false }
                    },
                    onSkip: { showingLevels = false },
                    onCancel: { showingLevels = false },
                    intro: "Check what each level of folders in “\(draft.tree.lastPathComponent)” names, then save: "
                        + "Archive Reader shows it as each document's repository, collection, box and folder. Saving "
                        + "writes one small file, “.archivesuite/container-levels.json”, in that folder.",
                    cancelHelp: "Close without saving.",
                    skipTitle: "Not Now",
                    skipHelp: "Close without saving; Archive Reader asks when it opens the folder.",
                    saveTitle: "Save")
            }
        }
    }

    private var folderRow: some View {
        HStack {
            Text(model.root?.path ?? "No folder chosen").font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("ap.backfill.folder")
            Spacer()
            Button("Choose Folder…") { chooseFolder() }
                .disabled(model.isBusy)
                .accessibilityIdentifier("ap.backfill.choose")
        }
    }

    private var coloursRow: some View {
        HStack(spacing: 16) {
            Text("In older material, a box photo is").font(.callout)
            colourPicker(for: .box)
            Text("and a folder photo").font(.callout)
            colourPicker(for: .folder)
        }
        .disabled(model.isBusy)
        .help("A Box or Folder tag always counts. A colour counts only as you say here: Archive Processor marked boxes Red "
              + "and folders Purple before it wrote the tags.")
    }

    private func colourPicker(for type: ItemType) -> some View {
        Picker(type.displayName, selection: Binding(
            get: { model.colours.colour(for: type) },
            set: { model.colours.setColour($0, for: type); model.rescan() })) {
                Text("no colour").tag(FinderLabel?.none)
                ForEach(FinderLabel.allCases, id: \.self) { Text($0.tokenName).tag(FinderLabel?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 120)
            .accessibilityIdentifier("ap.backfill.colour.\(type.rawValue)")
    }

    private func scanSummary(_ scan: ContainerBackfill.Scan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(scan.fileCount) photos and PDFs in \(scan.directories.count) folders; \(scan.markerCount) box and "
                 + "folder photos in \(model.rows.count) of them.")
                .font(.callout)
                .accessibilityIdentifier("ap.backfill.summary")
            if scan.unreadableTags > 0 {
                Label("\(scan.unreadableTags) files' tags could not be read, so they were not counted as box or folder photos.",
                      systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if scan.markerCount > 0 {
                Toggle("Also read titles, numbers and accessions with a model", isOn: $model.useModel)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("ap.backfill.useModel")
                Text(costLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.backfill.cost")
            }
            if model.levelsDraft != nil {
                HStack {
                    Text("What the folder levels name is not saved for this folder yet.").font(.caption)
                    Button("Set Folder Levels…") { showingLevels = true }
                        .controlSize(.small)
                        .accessibilityIdentifier("ap.backfill.levels")
                }
            }
        }
    }

    private var costLine: String {
        let n = model.markersToRead
        let visionMinutes = max(1, Int((Double(n) * 0.17 / 60).rounded(.up)))
        if n == 0 { return "Every photo has been read this way already: reading again costs nothing and proposes the folders again." }
        guard model.useModel else {
            return "Box and folder numbers with Apple Vision on this Mac: free, about \(visionMinutes) min for \(n) photos "
                + "not read yet. Titles, collection numbers and accessions are left for you, or read them with a model."
        }
        switch model.modelRoute {
        case .luna:
            return "GPT 5.6 Luna on the gateway for titles, collection numbers and accessions: real money, about "
                + "\(dollars(model.estimatedDollars)) for \(n) photos not read yet (\(dollars(ContainerLabelCapture.gatewayDollarsPerLabel)) each)."
        case .gemma, .vision:
            let minutes = Int((Double(n) * ContainerLabelGemma.secondsPerLabel / 60).rounded(.up))
            return "Gemma 3 12B on this Mac, when a local model server lists it: free, about \(minutes) min for \(n) photos. "
                + "With no server, Vision's reading alone is proposed."
        }
    }

    private var reviewList: some View {
        List {
            ForEach(model.rows) { row in
                rowView(row)
            }
        }
        .listStyle(.bordered)
        .frame(minHeight: 220)
        .accessibilityIdentifier("ap.backfill.list")
    }

    private func rowView(_ row: ContainerBackfillModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.directory.relativePath.isEmpty ? "(the chosen folder)" : row.directory.relativePath)
                    .font(.callout.bold())
                Text("\(row.directory.markers.count) label photo\(row.directory.markers.count == 1 ? "" : "s") · "
                     + "\(row.directory.fileCount) files").font(.caption).foregroundStyle(.secondary)
                Spacer()
                statusView(row)
            }
            if let proposal = row.proposal, row.status == .proposed {
                ForEach(Array(proposal.changedRuns.enumerated()), id: \.offset) { _, run in
                    Text(runLine(run)).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if !proposal.warnings.isEmpty {
                    Text(warningLine(proposal.warnings)).font(.caption).foregroundStyle(.orange)
                }
            }
            if let note = row.note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.backfill.row.\(row.id)")
    }

    @ViewBuilder
    private func statusView(_ row: ContainerBackfillModel.Row) -> some View {
        switch row.status {
        case .waiting: Text("not read").font(.caption).foregroundStyle(.secondary)
        case .accepting: ProgressView().controlSize(.small)
        case .proposed:
            Button("Skip") { model.skip(row.id) }.controlSize(.small)
                .accessibilityIdentifier("ap.backfill.skip.\(row.id)")
            Button("Accept") { model.accept(row.id) }.controlSize(.small)
                .accessibilityIdentifier("ap.backfill.accept.\(row.id)")
        case .written: Label("Written", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                .accessibilityIdentifier("ap.backfill.written.\(row.id)")
        case .skipped: Text("Skipped").font(.caption).foregroundStyle(.secondary)
        case .unchanged: Text("Nothing new").font(.caption).foregroundStyle(.secondary)
        case .failed(let why): Label("Not written: \(why)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    /// "From 0001.pdf, box: Box 10 · Collection title: Irving Kristol Papers (label, vision+parser)".
    private func runLine(_ run: ContainerRun) -> String {
        let level = run.level == .collection ? "collection" : run.level == .box ? "box" : "folder"
        let values = ContainerField.allCases.compactMap { field -> String? in
            guard let v = run.fields.values[field], let shown = v.shown else { return nil }
            return "\(field.label): \(shown)"
        }
        return "From \(run.start), \(level): " + (values.isEmpty ? "no values (a new \(level) with nothing read)"
                                                             : values.joined(separator: " · "))
    }

    private func warningLine(_ warnings: [ContainerWarning]) -> String {
        ContainerLabelCapture.warningNote(warnings)?.replacingOccurrences(of: " — check them in Archive Reader.", with: ".")
            ?? "\(warnings.count) warning\(warnings.count == 1 ? "" : "s") to check in Archive Reader."
    }

    private var footer: some View {
        HStack {
            if model.gatewayCalls > 0 {
                Text("\(model.gatewayCalls) gateway calls, about \(dollars(Double(model.gatewayCalls) * ContainerLabelCapture.gatewayDollarsPerLabel)).")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ap.backfill.spent")
            }
            Spacer()
            if model.isBusy {
                Button("Stop") { model.cancel() }.accessibilityIdentifier("ap.backfill.stop")
            } else if model.phase == .scanned || model.phase == .reviewing {
                Button(model.phase == .reviewing ? "Read Again" : "Read Labels") {
                    if model.needsCostConfirmation { confirmingCost = true } else { model.startReading() }
                }
                .disabled(model.rows.isEmpty)
                .accessibilityIdentifier("ap.backfill.read")
            }
            Button("Done") { model.cancel(); onDone() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("ap.backfill.done")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of box and folder photos and the documents after them."
        if panel.runModal() == .OK, let url = panel.url { model.choose(url) }
    }

    private func dollars(_ d: Double) -> String {
        d < 0.01 ? String(format: "$%.4f", d) : String(format: "$%.2f", d)
    }
}
