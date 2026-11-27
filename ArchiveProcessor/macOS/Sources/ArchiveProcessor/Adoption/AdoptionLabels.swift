import ArchiveCore
import Foundation

/// Step 4 of adoption: the old label backfill, moved here (owner call 31). Each converted Box or Folder file's label
/// is read from its matched original image and proposed as the derived directory's container runs, through the
/// shared backfill engine and its stale-write guards. Nothing is written unless `apply` is set, and then only the
/// derived archive's `.archivesuite/containers.json`. A label photo without an original is read from the PDF's
/// first page only when `rasterFallback` is chosen explicitly; otherwise it starts its run unread.
enum AdoptionLabels {
    /// Reads one label photo; Vision on this Mac by default, $0 and no network.
    typealias Reader = @Sendable (ItemType, URL) async -> (fields: ContainerFieldSet, text: String)

    static let visionReader: Reader = { type, photo in
        let read = await ContainerLabelCapture.readLabel(type: type, text: "", photo: photo, rotation: 0,
                                                         gateway: nil, useModel: false)
        return (read.fields, read.visionText)
    }

    struct DirectoryResult: Equatable, Sendable {
        enum Outcome: Equatable, Sendable { case proposed, wrote, unchanged, changedSinceRead, refused(String) }
        let path: String
        let markers: [String]
        /// Markers whose label was not read: no original, and no raster fallback chosen.
        let unread: [String]
        let warnings: Int
        let outcome: Outcome
    }

    static func run(_ manifest: AdoptionManifest, state: URL, apply: Bool, rasterFallback: Bool = false,
                    reader: Reader = visionReader) async throws -> [DirectoryResult] {
        guard let stateRoot = AdoptionInventory.canonicalDirectory(state),
              let ledger = try AdoptionLedger.load(from: stateRoot) else {
            throw AdoptionError.ledgerMismatch("no adoption ledger in \(state.path)")
        }
        let root = URL(fileURLWithPath: ledger.destinationRoot, isDirectory: true)
        let source = URL(fileURLWithPath: manifest.sourceRoot, isDirectory: true)
        let converted = manifest.entries.filter { ledger.items[$0.path]?.completed == true }
        let byDirectory = Dictionary(grouping: converted.filter { $0.proposal.itemType != nil }) {
            ($0.path as NSString).deletingLastPathComponent
        }

        var results: [DirectoryResult] = []
        for (directory, entries) in byDirectory.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            var markers: [ContainerMarker] = []
            var unread: [String] = []
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                guard let value = entry.proposal.itemType?.value,
                      let type = ItemType.allCases.first(where: { $0.rawValue.lowercased() == value }) else { continue }
                let name = (entry.path as NSString).lastPathComponent
                var photo: URL?
                var rendered = false
                if entry.original.state == .matched, let originals = manifest.originalsRoot, let path = entry.original.path {
                    photo = URL(fileURLWithPath: originals).appendingPathComponent(path)
                } else if rasterFallback {
                    let pdf = source.appendingPathComponent(entry.path)
                    let image = await PDFGenerator.runWorker { PDFToImageConverter.imageURL(for: pdf) }
                    if image != pdf { photo = image; rendered = true }
                }
                guard let photo else {
                    unread.append(entry.path)
                    markers.append(ContainerMarker(fileName: name, type: type))
                    continue
                }
                let read = await reader(type, photo)
                if rendered { try? FileManager.default.removeItem(at: photo) }
                markers.append(ContainerMarker(fileName: name, type: type, read: read.fields,
                                               text: read.text.isEmpty ? nil : read.text))
            }
            // A run starts at its label and covers the files after it, so a folder still missing files the reviewer
            // has not skipped would give them to the wrong run.
            let missing = manifest.entries.filter {
                ($0.path as NSString).deletingLastPathComponent == directory && $0.decision != .skip
                    && ledger.items[$0.path]?.completed != true
            }
            let folder = directory.isEmpty ? root : root.appendingPathComponent(directory, isDirectory: true)
            let read = markers
            let proposal = await PDFGenerator.runWorker { ContainerBackfill.propose(read, in: folder) }
            var outcome = DirectoryResult.Outcome.proposed
            switch proposal.state {
            case _ where !missing.isEmpty:
                outcome = .refused("\(missing.count) files here are not converted or skipped yet")
            case .unchanged: outcome = .unchanged
            case .blocked(let why): outcome = .refused(why)
            case .ready where apply:
                let accepted = try await PDFGenerator.runWorker { try ContainerBackfill.accept(proposal, root: root) }
                switch accepted {
                case .wrote: outcome = .wrote
                case .unchanged: outcome = .unchanged
                case .changedSinceRead: outcome = .changedSinceRead
                case .refused(let why): outcome = .refused(why)
                }
            case .ready: break
            }
            results.append(.init(path: directory, markers: markers.map(\.fileName), unread: unread,
                                 warnings: proposal.warnings.count, outcome: outcome))
        }
        return results
    }
}
