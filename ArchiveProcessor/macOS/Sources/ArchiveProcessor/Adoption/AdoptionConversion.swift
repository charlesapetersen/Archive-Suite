import ArchiveCore
import CryptoKit
import Darwin
import Foundation

/// Step 2 of adoption: files each accepted manifest entry into a separate derived archive as a catalogue pair, with
/// its matched original in the Preservation folder (W49.corpus-adoption-tool). The source is only ever read. Each
/// entry's filing is frozen in the ledger before it starts, so an interrupted run resumes the same operation; an
/// entry counts as converted only once its whole pair (and preserved original) verified.
struct AdoptionLedger: Codable, Sendable {
    static let currentFormat = 1
    static let fileName = "adoption-ledger.json"

    struct Item: Codable, Sendable {
        let operationID: UUID
        let sourceByteCount: Int64
        let sourceSHA256: Data
        let filing: ProcessorCatalogueFiling
        let preservation: ProcessorPreservationFiling?
        let record: Data
        var completed: Bool
    }

    var format = Self.currentFormat
    let sourceRoot: String
    let destinationRoot: String
    let rootInstanceID: UUID
    var items: [String: Item] = [:]

    static func load(from state: URL) throws -> Self? {
        let url = state.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let ledger = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard ledger.format == currentFormat else { throw AdoptionError.unsupportedManifest(ledger.format) }
        return ledger
    }

    /// Atomic and flushed: the ledger is what makes the next attempt the same operation.
    func save(to state: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = state.appendingPathComponent(Self.fileName)
        try encoder.encode(self).write(to: url, options: .atomic)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
    }
}

enum AdoptionConversion {
    #if DEBUG
    /// The self-test's stand-in for a run killed between freezing an entry's filing and publishing it.
    @MainActor static var _testInterruptAfterPreparing: String?
    #endif

    struct Outcome: Equatable, Sendable {
        enum State: Equatable, Sendable { case converted, alreadyConverted, skipped(String), failed(String) }
        let path: String
        let state: State
        let keptOriginal: Bool
    }

    /// Converts the accepted entries. `state` holds the ledger and the prepared copies; it lies outside both trees.
    @MainActor
    static func run(_ manifest: AdoptionManifest, destination: URL, state: URL,
                    protected: [URL] = AdoptionInventory.protectedRoots) async throws -> [Outcome] {
        guard SearchableArchival.isAvailable else { throw AdoptionError.noQPDF }
        guard let source = AdoptionInventory.canonicalDirectory(URL(fileURLWithPath: manifest.sourceRoot)) else {
            throw AdoptionError.sourceMissing(manifest.sourceRoot)
        }
        try AdoptionInventory.refuseProtected(source, protected: protected)
        let originals = manifest.originalsRoot.map { AdoptionInventory.canonicalPath(URL(fileURLWithPath: $0)) }
        if let originals { try AdoptionInventory.refuseProtected(originals, protected: protected) }
        // Every refusal comes before anything is created.
        let planned = AdoptionInventory.canonicalPath(destination), plannedState = AdoptionInventory.canonicalPath(state)
        try AdoptionInventory.refuseProtected(planned, protected: protected)
        try AdoptionInventory.refuseProtected(plannedState, protected: protected)
        try refuseNesting(planned, source: source, originals: originals, state: plannedState)
        let fm = FileManager.default
        try fm.createDirectory(at: planned, withIntermediateDirectories: true)
        try fm.createDirectory(at: plannedState, withIntermediateDirectories: true)
        guard let canonicalRoot = AdoptionInventory.canonicalDirectory(planned),
              let stateRoot = AdoptionInventory.canonicalDirectory(plannedState) else {
            throw AdoptionError.sourceMissing(destination.path)
        }
        try refuseNesting(canonicalRoot, source: source, originals: originals, state: stateRoot)
        // Filing compares standardized paths, and Foundation drops `/private` only from paths that exist; a root
        // already in that form keeps it the same for the files not yet filed under it.
        let root = canonicalRoot.standardizedFileURL

        var ledger: AdoptionLedger
        if let existing = try AdoptionLedger.load(from: stateRoot) {
            guard existing.sourceRoot == source.path, existing.destinationRoot == root.path else {
                throw AdoptionError.ledgerMismatch("it was made for \(existing.sourceRoot) → \(existing.destinationRoot)")
            }
            ledger = existing
        } else {
            guard try fm.contentsOfDirectory(atPath: root.path).isEmpty else {
                throw AdoptionError.destinationNotEmpty(root.path)
            }
            ledger = AdoptionLedger(sourceRoot: source.path, destinationRoot: root.path, rootInstanceID: UUID())
            try ledger.save(to: stateRoot)
        }
        let work = stateRoot.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        var outcomes: [Outcome] = []
        for entry in manifest.entries where entry.decision == .accept {
            try Task.checkCancellation()
            if ledger.items[entry.path]?.completed == true {
                outcomes.append(.init(path: entry.path, state: .alreadyConverted,
                                      keptOriginal: ledger.items[entry.path]?.preservation != nil))
                continue
            }
            if let blocker = entry.review.first(where: { !$0.convertible }) {
                outcomes.append(.init(path: entry.path, state: .skipped(blocker.rawValue), keptOriginal: false))
                continue
            }
            do {
                let item = try await prepare(entry, manifest: manifest, source: source, root: root, work: work,
                                             ledger: &ledger, state: stateRoot)
                #if DEBUG
                if entry.path == _testInterruptAfterPreparing { _testInterruptAfterPreparing = nil; throw CancellationError() }
                #endif
                let prepared = work.appendingPathComponent(item.operationID.uuidString + ".pdf")
                _ = try item.filing.file(preparedPDF: prepared, record: item.record, preservation: item.preservation)
                ledger.items[entry.path]?.completed = true
                try ledger.save(to: stateRoot)
                try? fm.removeItem(at: prepared)
                outcomes.append(.init(path: entry.path, state: .converted, keptOriginal: item.preservation != nil))
            } catch {
                outcomes.append(.init(path: entry.path, state: .failed(String(describing: error)), keptOriginal: false))
            }
        }
        return outcomes
    }

    /// The frozen filing for one entry: reused as written when a previous attempt got this far.
    private static func prepare(_ entry: AdoptionManifest.Entry, manifest: AdoptionManifest, source: URL, root: URL,
                                work: URL, ledger: inout AdoptionLedger, state: URL) async throws -> AdoptionLedger.Item {
        // A frozen filing is finished as it was frozen: its prepared copy came from the verified source, and the
        // filer's journal may already hold the pair. A later change to the source shows up in verification.
        if let item = ledger.items[entry.path] { return item }
        let url = source.appendingPathComponent(entry.path)
        try requireUnchanged(entry, at: url)
        guard let pageCount = entry.pageCount, pageCount > 0 else { throw PDFError.sourceUnreadable(url) }

        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        let operationID = UUID()
        let sourcePages = (0..<pageCount).map { _ in ProcessorCatalogueRecord.SourcePage(roles: ["page"]) }
        let destination = root.appendingPathComponent(entry.path)
        var preservation: ProcessorPreservationFiling?
        if entry.keepOriginal, entry.original.state == .matched, pageCount == 1,
           let originals = manifest.originalsRoot, let path = entry.original.path {
            let intake = try ProcessorPreservationFiling.Intake(url: URL(fileURLWithPath: originals).appendingPathComponent(path))
            preservation = try ProcessorPreservationFiling(fileID: identity.fileID, pages: sourcePages,
                                                           inputs: [.init(source: intake, originalPageIndex: 0)])
                .named(for: destination)
        }
        let document = ProcessorCatalogueRecord.Document(id: UUID(), ownerFileID: identity.fileID,
                                                          fields: documentFields(entry.proposal))
        let record = try ProcessorCatalogueRecord(identity: identity, sourcePages: sourcePages, document: document,
                                                  fileFields: fileFields(entry.proposal),
                                                  preservationManifestSHA256: preservation?.manifest.digest()).encoded()
            .checking(date: entry.proposal.documentDate?.checked == true, sentWith: entry.proposal.sentWith?.checked == true)

        let sourceDigest = try digest(of: url)
        let bytes = try await PDFGenerator.runWorker { try SearchableArchival.catalogueCopy(of: url, identity: identity) }
        guard try digest(of: url) == sourceDigest else {
            throw AdoptionError.ledgerMismatch("\(entry.path) changed while it was copied")
        }
        let prepared = work.appendingPathComponent(operationID.uuidString + ".pdf")
        try bytes.write(to: prepared, options: .withoutOverwriting)
        try ProcessorCatalogueRun.flushFileAndParent(prepared)

        // Adoption leaves the old Finder tags behind on the original (W49.storage-finder-drop-mirror).
        let filing = try ProcessorCatalogueFiling(operationID: operationID, root: root,
                                                  rootInstanceID: ledger.rootInstanceID, destination: destination)
        let item = AdoptionLedger.Item(operationID: operationID, sourceByteCount: entry.byteCount,
                                       sourceSHA256: sourceDigest, filing: filing, preservation: preservation,
                                       record: record, completed: false)
        ledger.items[entry.path] = item
        try ledger.save(to: state)
        return item
    }

    /// The tags and size the manifest was reviewed against are still the file's: a changed file needs a new inventory.
    private static func requireUnchanged(_ entry: AdoptionManifest.Entry, at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == entry.byteCount,
              case .success(let names, let label) = TagReading.read(url), names == entry.tags,
              label == entry.labelNumber else {
            throw AdoptionError.ledgerMismatch("\(entry.path) changed since the inventory; inventory it again")
        }
    }

    static func digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return Data(hash.finalize())
    }

    /// The derived archive, the source, the originals and the state folder never contain one another.
    static func refuseNesting(_ root: URL, source: URL, originals: URL?, state: URL) throws {
        func overlap(_ a: URL, _ b: URL) -> Bool {
            let x = a.pathComponents.map { $0.lowercased() }, y = b.pathComponents.map { $0.lowercased() }
            return x.starts(with: y) || y.starts(with: x)
        }
        let trees = [source] + (originals.map { [$0] } ?? [])
        if trees.contains(where: { root.pathComponents.map { $0.lowercased() }.starts(with: $0.pathComponents.map { $0.lowercased() }) }) {
            throw AdoptionError.destinationInsideSource
        }
        if trees.contains(where: { overlap(root, $0) }) { throw AdoptionError.sourceInsideDestination }
        if (trees + [root]).contains(where: { overlap(state, $0) }) {
            throw AdoptionError.statePlacement("must be outside the source, the originals and the derived archive")
        }
    }

    // MARK: Facts

    typealias Record = ProcessorCatalogueRecord

    /// A fact the old archive carried is `imported`; one the optional label classifier proposed is a `model` reading.
    private static func field<Value>(_ value: Value, rule: String, evidence: String) -> Record.Field<Value> {
        Record.Field(value, origin: rule.hasPrefix(AdoptionClassify.rulePrefix) ? "model" : "imported",
                     evidence: [.init(source: "adoption", route: rule, quote: evidence)])
    }

    private static func date(_ fact: AdoptionManifest.DateFact?) -> Record.Field<CatalogueRecord.DateValue>? {
        guard let fact, let date = ArchiveDate.parse(wireValue: fact.value) else { return nil }
        return field(CatalogueRecord.DateValue(date: date, uncertain: fact.uncertain), rule: fact.rule, evidence: fact.evidence)
    }

    static func documentFields(_ proposal: AdoptionManifest.Proposal) -> Record.DocumentFields {
        var fields = Record.DocumentFields()
        fields.documentDate = date(proposal.documentDate)
        fields.sentWith = date(proposal.sentWith)
        fields.itemType = proposal.itemType.map { field($0.value, rule: $0.rule, evidence: $0.evidence) }
        if !proposal.subjects.isEmpty {
            fields.subjects = field(proposal.subjects, rule: "tags", evidence: proposal.subjects.joined(separator: ", "))
        }
        return fields
    }

    static func fileFields(_ proposal: AdoptionManifest.Proposal) -> Record.FileFields {
        Record.FileFields(
            readState: proposal.readState.map { field($0.value, rule: $0.rule, evidence: $0.evidence) },
            colour: proposal.colour.map { field($0.value, rule: $0.rule, evidence: $0.evidence) },
            quality: proposal.quality.map { field($0.value, rule: $0.rule, evidence: $0.evidence) },
            ocrPoor: proposal.ocrPoor ? field(true, rule: "tag", evidence: DocumentTags.poorOCRTag) : nil,
            ocrFailed: nil
        )
    }
}

private extension Data {
    /// The record with the old archive's `Checked …` dates carried as current checks (`checkedRevision` equal to
    /// `fieldRevision`), revalidated.
    func checking(date: Bool, sentWith: Bool) throws -> Data {
        guard date || sentWith else { return self }
        guard var record = try JSONSerialization.jsonObject(with: self) as? [String: Any],
              var documents = record["documents"] as? [[String: Any]], var document = documents.first,
              var fields = document["fields"] as? [String: Any] else { throw CatalogueRecord.Invalid.inconsistentRecord }
        for (key, wanted) in [("documentDate", date), ("sentWith", sentWith)] where wanted {
            guard var field = fields[key] as? [String: Any], let revision = field["fieldRevision"] else { continue }
            field["checkedRevision"] = revision
            fields[key] = field
        }
        document["fields"] = fields
        documents[0] = document
        record["documents"] = documents
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        return try CatalogueRecord(json: data).originalJSON
    }
}
