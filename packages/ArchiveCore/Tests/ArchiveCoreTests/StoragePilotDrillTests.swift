import CryptoKit
import Foundation
import Testing
@testable import ArchiveCore

/// The rollback drill of W49.storage-pilot (execution-plans/storage-simplify.md §15), run by
/// `ops/verify/storage-pilot.sh` against a scratch archive it has just adopted or processed. Skipped unless
/// `ARCHIVE_PILOT_ROOT` names that archive and `ARCHIVE_PILOT_OUT` a folder outside it for the export and
/// the moved copy. With `ARCHIVE_PILOT_EDIT=1` it first makes post-cutover edits through `CatalogueWriter`
/// (a flag set, an explicit clear, a checked title), so the export has to carry the latest records.
/// It then exports every catalogued PDF, copies the archive to another path, reopens both read-only and
/// compares each record with the archive's: PDF and companion bytes, identity, revisions, the owner each
/// document resolves to and every preserved original. The summary goes to `ARCHIVE_PILOT_OUT/drill.json`.
/// Never point it at the real corpus: it writes edits into the root it is given.
@Suite struct StoragePilotDrillTests {
    static let environment = ProcessInfo.processInfo.environment
    static var root: URL? { environment["ARCHIVE_PILOT_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var out: URL? { environment["ARCHIVE_PILOT_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    struct Summary: Codable {
        var root = ""
        var files = 0
        var unreadable: [String] = []
        var edited: [String] = []
        var exportFiles = 0
        var preserved = 0
        var mismatches: [String] = []
    }

    @Test(.enabled(if: root != nil && out != nil))
    func exportAndMovedCopyMatchTheArchiveRecordByRecord() throws {
        let root = try #require(Self.root), out = try #require(Self.out)
        #expect(!root.path.contains("Google Drive/Archival Photos"), "the drill never runs on the real corpus")
        guard !root.path.contains("Google Drive/Archival Photos") else { return }
        var summary = Summary(root: root.lastPathComponent)

        let reader = try Self.reader(root)
        var snapshot = reader.discover()
        #expect(snapshot.inventory.isComplete)
        let paths = snapshot.inventory.relativePDFPaths.filter { (try? snapshot.facts(at: $0).file.get()) != nil }
        summary.files = paths.count
        summary.unreadable = snapshot.inventory.relativePDFPaths.filter { !paths.contains($0) }
        #expect(!paths.isEmpty)

        if Self.environment["ARCHIVE_PILOT_EDIT"] == "1" {
            summary.edited = try Self.editLatest(paths, in: snapshot, with: CatalogueWriter(reader: reader))
            snapshot = reader.discover()
        }

        // Export the latest records of the whole archive, then reopen the export as its own root.
        let export = out.appendingPathComponent("export", isDirectory: true)
        let manifest = try CatalogueExport.export(paths, from: reader, to: export)
        summary.exportFiles = manifest.files.count
        #expect(manifest.snapshot && manifest.contents == .wholeRecords)
        #expect(Set(manifest.files.map(\.path)) == Set(paths))
        summary.preserved = manifest.files.reduce(0) { $0 + $1.preservation.count }
        let exported = try Self.reader(export).discover()
        summary.mismatches += Self.compare(paths, root: root, snapshot: snapshot, to: export, exported, label: "export")
        for file in manifest.files {
            for preserved in file.preservation where try Self.sha(root, preserved) != Self.sha(export, preserved) {
                summary.mismatches.append("export \(preserved): preserved original differs")
            }
            let facts = try? snapshot.facts(at: file.path).file.get()
            if facts?.revision.facts != file.revision { summary.mismatches.append("export \(file.path): manifest revision is not the latest") }
        }

        // Portable transfer: the same archive copied to another path reads the same records.
        let moved = out.appendingPathComponent("moved \(root.lastPathComponent)", isDirectory: true)
        try FileManager.default.copyItem(at: root, to: moved)
        let movedSnapshot = try Self.reader(moved).discover()
        summary.mismatches += Self.compare(paths, root: root, snapshot: snapshot, to: moved, movedSnapshot, label: "moved")

        let data = try JSONEncoder().encode(summary)
        try data.write(to: out.appendingPathComponent("drill.json"))
        #expect(summary.mismatches.isEmpty, "\(summary.mismatches.prefix(10))")
    }

    static func reader(_ root: URL) throws -> CatalogueReader {
        try CatalogueReader(grantedRoot: root, rootInstanceID: UUID(), mode: .adopted,
                            identifyPDF: CataloguePDFIdentity.identify)
    }

    /// Edits three files the way a user would after cutover, and checks each edit reads back.
    static func editLatest(_ paths: [String], in snapshot: CatalogueReader.Snapshot,
                           with writer: CatalogueWriter) throws -> [String] {
        var edited: [String] = []
        for (index, path) in paths.prefix(3).enumerated() {
            let facts = try snapshot.facts(at: path).file.get()
            var receipt: CatalogueWriter.Receipt
            switch index {
            case 0: receipt = try writer.save([CatalogueEdit(.file(.flagged), .set(.flag(true)))], basedOn: facts)
            case 1: receipt = try writer.save([CatalogueEdit(.file(.readState), .clear)], basedOn: facts)
            default:
                guard let document = facts.pair.record.documents.first(where: { $0.ownerFileID == facts.pair.record.fileID })
                else { continue }
                // A value and its check are two saves, as in the Inspector.
                receipt = try writer.save([CatalogueEdit(.document(document.id, .title), .set(.text("Pilot title")))],
                                          basedOn: facts)
                receipt = try writer.save([CatalogueEdit(.document(document.id, .title), .check(true))],
                                          basedOn: receipt.after)
            }
            #expect(receipt.after.revision.facts != facts.revision.facts, "\(path) was not edited")
            edited.append(path)
        }
        return edited
    }

    static func compare(_ paths: [String], root: URL, snapshot: CatalogueReader.Snapshot,
                        to other: URL, _ copy: CatalogueReader.Snapshot, label: String) -> [String] {
        var problems: [String] = []
        for path in paths {
            let a = snapshot.facts(at: path), b = copy.facts(at: path)
            guard let fa = try? a.file.get() else { continue }
            guard let fb = try? b.file.get() else { problems.append("\(label) \(path): does not read (\(b.file))"); continue }
            if fa.revision.fileID != fb.revision.fileID { problems.append("\(label) \(path): file ID differs") }
            if fa.revision.content != fb.revision.content { problems.append("\(label) \(path): content revision differs") }
            if fa.revision.facts != fb.revision.facts { problems.append("\(label) \(path): facts revision differs") }
            if fa.revision.companionSHA256 != fb.revision.companionSHA256 { problems.append("\(label) \(path): companion differs") }
            if (try? sha(root, path)) != (try? sha(other, path)) { problems.append("\(label) \(path): PDF bytes differ") }
            let da = try? a.document.get(), db = try? b.document.get()
            if da?.owner.pair.occurrence.relativePath != db?.owner.pair.occurrence.relativePath
                || da?.owner.revision.companionSHA256 != db?.owner.revision.companionSHA256 {
                problems.append("\(label) \(path): document owner differs")
            }
        }
        return problems
    }

    static func sha(_ root: URL, _ path: String) throws -> String {
        let data = try Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
