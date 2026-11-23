import CryptoKit
import Darwin
import Foundation

extension CatalogueWriter {
    public struct Recovery: Sendable {
        public enum State: Sendable, Equatable {
            /// Publication never completed. The pending candidate is still beside the prior live record.
            case staged
            /// Live and retained records match the exchange. Later successful edits may have advanced live.
            case published
            /// The two names cannot be reconciled against this operation's digests and local history.
            case diverged
            /// The artifact is unreadable, partial, or no longer associated with the selected PDF.
            case incomplete
        }

        public let artifact: String
        public let state: State
        public let retainedRevision: UUID?
    }

    public struct RecoveryReport: Sendable {
        public let live: Result<ItemFacts.FileFacts, ItemFacts.Unavailable>
        public let artifacts: [Recovery]
    }

    /// Inspect pending and completed exchanges, including when the live companion is missing.
    /// The PDF must still provide independent identity. Inspection never promotes a candidate.
    public func recoveries(at occurrence: CatalogueAssociation.Occurrence) throws -> RecoveryReport {
        try reader.withOccurrence(occurrence) { root, parent, filename in
            try withLock(on: parent) {
                try reader.validateScope(root: root, parent: parent)
                return try reader.withProvenPDF(filename, in: parent, at: occurrence) { pdf, proof in
                    let live: Result<ItemFacts.FileFacts, ItemFacts.Unavailable>
                    do {
                        let name = CatalogueRecord.companionFilename(forPDFFilename: filename)
                        let companion = try readRecord(name, in: parent)
                        live = .success(try reader.fileFacts(companion.record, at: occurrence, proof: proof, pdf: pdf,
                                                            companionVersion: companion.version))
                    } catch {
                        live = .failure(CatalogueReader.companionStatus(error))
                    }
                    let prefix = CatalogueEditArtifact.prefix(for: filename, pdf: .init(pdf.info))
                    let artifacts = try editArtifacts(prefix: prefix, in: parent)
                    let record = try? live.get().pair.record
                    let history = Set(record.map { ancestry(of: $0, through: artifacts, in: parent).map(\.after) } ?? [])
                    let liveDigest = record.map(CatalogueEditArtifact.digest)
                    let recoveries = artifacts.map { artifact in
                        guard let retained = try? readRecord(artifact.name, in: parent).record,
                              (try? CatalogueAssociation.pair(retained, at: occurrence, verifiedBy: proof)) != nil else {
                            return Recovery(artifact: artifact.name, state: .incomplete, retainedRevision: nil)
                        }
                        let digest = CatalogueEditArtifact.digest(retained)
                        let state: Recovery.State
                        if digest == artifact.before, history.contains(artifact.after) {
                            state = .published
                        } else if digest == artifact.after, liveDigest == artifact.before,
                                  retained.parents.first == record?.revision, retained.parents.count == 1 {
                            state = .staged
                        } else {
                            state = .diverged
                        }
                        return Recovery(artifact: artifact.name, state: state, retainedRevision: retained.revision)
                    }
                    return RecoveryReport(live: live, artifacts: recoveries)
                }
            }
        }
    }

    /// Open one retained record, including when the live companion is unavailable. Callers can
    /// present the candidate for reconciliation without loading every historical record at once.
    public func retainedRecord(named name: String, at occurrence: CatalogueAssociation.Occurrence) throws -> CatalogueRecord {
        try reader.withOccurrence(occurrence) { root, parent, filename in
            try withLock(on: parent) {
                try reader.validateScope(root: root, parent: parent)
                return try reader.withProvenPDF(filename, in: parent, at: occurrence) { pdf, proof in
                    let prefix = CatalogueEditArtifact.prefix(for: filename, pdf: .init(pdf.info))
                    guard let artifact = CatalogueEditArtifact(name: name, prefix: prefix) else {
                        throw ItemFacts.Unavailable.invalid(.companion)
                    }
                    let record = try readRecord(artifact.name, in: parent).record
                    return try CatalogueAssociation.pair(record, at: occurrence, verifiedBy: proof).record
                }
            }
        }
    }

    func descends(_ current: CatalogueRecord, from base: CatalogueRecord, in scope: Scope) throws -> Bool {
        // A revision UUID reused for different JSON is a conflicting version, even if the particular
        // field being edited is byte-identical.
        guard current.revision != base.revision else { return false }
        let prefix = CatalogueEditArtifact.prefix(for: scope.filename, pdf: scope.base.pdfVersion.identity)
        let artifacts = try editArtifacts(prefix: prefix, in: scope.parent)
        let baseDigest = CatalogueEditArtifact.digest(base)
        return ancestry(of: current, through: artifacts, in: scope.parent, stoppingAt: baseDigest).last?.before == baseDigest
    }

    /// Return the exact known successor of a retained operation in the live ancestry.
    func undoRecords(for inverse: Inverse, current: CatalogueRecord, in scope: Scope)
        throws -> (before: CatalogueRecord, after: CatalogueRecord) {
        let prefix = CatalogueEditArtifact.prefix(for: scope.filename, pdf: scope.base.pdfVersion.identity)
        let artifacts = try editArtifacts(prefix: prefix, in: scope.parent)
        let history = ancestry(of: current, through: artifacts, in: scope.parent, stoppingAt: inverse.beforeDigest)
        guard let last = history.last, last.name == inverse.artifact,
              last.before == inverse.beforeDigest, last.after == inverse.afterDigest else {
            throw UndoRefusal.unverifiedHistory
        }
        let after = try history.dropLast().last.map { try readRecord($0.name, in: scope.parent).record } ?? current
        let before = try readRecord(last.name, in: scope.parent).record
        guard CatalogueEditArtifact.digest(after) == inverse.afterDigest,
              CatalogueEditArtifact.digest(before) == inverse.beforeDigest,
              after.revision == inverse.afterRevision, before.revision == inverse.beforeRevision else {
            throw UndoRefusal.unverifiedHistory
        }
        return (before, after)
    }

    private func ancestry(of live: CatalogueRecord, through artifacts: [CatalogueEditArtifact],
                          in parent: CatalogueReadDirectory.Entry, stoppingAt stop: String? = nil) -> [CatalogueEditArtifact] {
        let byAfter = Dictionary(grouping: artifacts, by: \.after)
        var history: [CatalogueEditArtifact] = []
        var current = live
        var digest = CatalogueEditArtifact.digest(live)
        var seen: Set<String> = [digest]
        while let matches = byAfter[digest], matches.count == 1, let artifact = matches.first {
            guard let prior = try? readRecord(artifact.name, in: parent).record,
                  prior.fileID == live.fileID, prior.contentRevision == live.contentRevision,
                  prior.pages.count == live.pages.count, CatalogueEditArtifact.digest(prior) == artifact.before,
                  current.parents == [prior.revision], seen.insert(artifact.before).inserted else { break }
            history.append(artifact)
            if artifact.before == stop { break }
            current = prior
            digest = artifact.before
        }
        return history
    }

    private func editArtifacts(prefix: String, in parent: CatalogueReadDirectory.Entry) throws -> [CatalogueEditArtifact] {
        // Reopen the same descriptor-relative directory so the iterator has its own file offset.
        let fd = openat(parent.descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io(operation: "open edit history", code: errno) }
        guard let iterator = fdopendir(fd) else {
            let code = errno
            close(fd)
            throw Failure.io(operation: "iterate edit history", code: code)
        }
        defer { closedir(iterator) }
        var artifacts: [CatalogueEditArtifact] = []
        while true {
            errno = 0
            guard let entry = readdir(iterator) else {
                guard errno == 0 else { throw Failure.io(operation: "read edit history", code: errno) }
                return artifacts.sorted { $0.name < $1.name }
            }
            let count = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(bytes: $0.prefix(count), encoding: .utf8) }
            if let name, let artifact = CatalogueEditArtifact(name: name, prefix: prefix) { artifacts.append(artifact) }
        }
    }
}

struct CatalogueEditArtifact {
    let name: String
    let before: String
    let after: String

    init(filename: String, pdf: CatalogueReadDirectory.Identity, before: CatalogueRecord, after: CatalogueRecord) {
        self.before = Self.digest(before)
        self.after = Self.digest(after)
        name = Self.prefix(for: filename, pdf: pdf) + self.before + "-" + self.after + ".json"
    }

    init?(name: String, prefix: String) {
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
        let parts = name.dropFirst(prefix.count).dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            part.utf8.count == 64 && part.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }), parts[0] != parts[1] else { return nil }
        self.name = name
        before = String(parts[0])
        after = String(parts[1])
    }

    static func prefix(for filename: String, pdf: CatalogueReadDirectory.Identity) -> String {
        // A volume's device number can change after remount. Its inode and birth time identify
        // the same file in this directory across relaunches and whole-root moves.
        let occurrence = "\(pdf.inode):\(pdf.birthSeconds):\(pdf.birthNanoseconds):\(filename)"
        return ".archivesuite-edit-" + digest(Data(occurrence.utf8)) + "-"
    }

    static func digest(_ record: CatalogueRecord) -> String { digest(record.originalJSON) }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
