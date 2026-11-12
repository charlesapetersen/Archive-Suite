import ArchiveCore
import SwiftUI

/// "What produced this collection": the Processor's settings document beside a file's collection, read-only
/// (W46.settings-reader-notes; `SPEC/collection-settings.md`). The Reader's inspector and Notes' Sources section
/// show it. It finds and reads the record off the main thread and shows nothing when the file's collection has none.
public struct CollectionRecordView: View {
    let fileURL: URL?
    let root: URL?
    let identifierPrefix: String
    @State private var record: CollectionSettingsRecord?

    /// - Parameters:
    ///   - fileURL: a file in the collection, or nil for nothing to show.
    ///   - root: the archive root, which bounds the walk up from the file's folder; nil looks in the file's own
    ///     folder only.
    ///   - identifierPrefix: the app's accessibility prefix (`ar` / `an`).
    public init(fileURL: URL?, root: URL?, identifierPrefix: String) {
        self.fileURL = fileURL
        self.root = root
        self.identifierPrefix = identifierPrefix
    }

    public var body: some View {
        // A VStack, not a Group: a Group's modifiers go to its children, and with no record yet there are none, so
        // the task would never run.
        VStack(alignment: .leading, spacing: 0) {
            if let record {
                CollectionRecordContent(record: record, id: identifierPrefix + ".collectionRecord")
            }
        }
        .task(id: [fileURL?.path ?? "", root?.path ?? ""]) {
            let file = fileURL, root = root
            let found = await Task.detached(priority: .utility) { () -> CollectionSettingsRecord? in
                guard let file, let folder = CollectionSettingsRecord.locate(from: file, within: root) else {
                    return nil
                }
                return CollectionSettingsRecord.load(collectionFolder: folder)
            }.value
            if !Task.isCancelled, found != record { record = found }
        }
    }
}

/// One collection's record, already read; the caller found it (Notes reads its sources under their granted roots).
public struct CollectionRecordContent: View {
    let record: CollectionSettingsRecord
    let id: String

    public init(record: CollectionSettingsRecord, id: String) {
        self.record = record
        self.id = id
    }

    private static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What produced this collection").font(.subheadline.weight(.semibold))
                .accessibilityIdentifier(id)
            Text(heading).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier(id + ".name")
            if record.documentIsNewer {
                note("Written by a newer Archive Processor; update this app to read it.")
            } else if record.documentUnreadable {
                note("The collection's settings document could not be read.")
            }
            if let run = record.latestRun {
                runSummary(run, latest: true)
                if !run.settings.isEmpty {
                    DisclosureGroup("Settings for this run") { settingsList(run.settings) }
                        .font(.caption).accessibilityIdentifier(id + ".runSettings")
                }
                if !run.processing.isEmpty {
                    DisclosureGroup("The Processor's own settings") { settingsList(run.processing, plain: true) }
                        .font(.caption).accessibilityIdentifier(id + ".processing")
                }
            } else if record.runFileCount > 0 {
                note("None of its run records could be read.")
            } else if !record.documentIsNewer {
                note("No run has been recorded for it yet.")
            }
            if !record.ownSettings.isEmpty {
                DisclosureGroup("Answered for this collection (\(record.ownSettings.count))") {
                    settingsList(record.ownSettings)
                }
                .font(.caption).accessibilityIdentifier(id + ".own")
            }
            // Runs past the newest `maxRunsRead` are counted, not read.
            let notRead = record.runFileCount - record.runs.count - record.unreadableRunCount
            if record.runs.count > 1 || (!record.runs.isEmpty && notRead > 0) {
                DisclosureGroup("Earlier runs (\(record.runs.count - 1 + notRead))") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(record.runs.dropFirst()) { runSummary($0, latest: false) }
                        if notRead > 0 { note("\(notRead) older not shown.") }
                    }
                }
                .font(.caption).accessibilityIdentifier(id + ".earlier")
            }
            if record.unreadableRunCount > 0, !record.runs.isEmpty {
                note("\(record.unreadableRunCount) run record\(record.unreadableRunCount == 1 ? "" : "s") could not be read.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var heading: String {
        let name = record.collectionName ?? record.collectionFolder.lastPathComponent
        return record.projectName.map { "“\(name)”, in the project “\($0)”" } ?? "“\(name)”"
    }

    @ViewBuilder private func runSummary(_ run: CollectionSettingsRecord.Run, latest: Bool) -> some View {
        let date = run.startedAt.map { Self.when.string(from: $0) } ?? "an unknown date"
        let files = run.fileCount.map { ", \($0) file\($0 == 1 ? "" : "s")" } ?? ""
        VStack(alignment: .leading, spacing: 2) {
            Text((latest ? "Last run: " : "") + "\(run.kindLabel), \(date)\(files)").font(.caption)
            if run.isNewer {
                note("Recorded by a newer Archive Processor.")
            } else if let reader = run.reader {
                Text("Read by \(reader)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id + (latest ? ".latest" : ".run"))
    }

    @ViewBuilder private func settingsList(_ items: [CollectionSettingsRecord.Setting], plain: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { s in
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(s.label): \(s.value.isEmpty ? "–" : s.value)").font(.caption)
                    if !plain, !s.source.isEmpty {
                        Text(s.source).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
