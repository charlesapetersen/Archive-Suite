import ArchiveCore
import CoreGraphics
import Foundation

/// Step 3 of adoption: reads the derived archive back the way the Reader does and compares every converted entry
/// with its manifest proposal and its untouched source (W49.corpus-adoption-tool). Read-only on both trees.
enum AdoptionVerification {
    struct Finding: Equatable, Sendable {
        let path: String
        let problem: String
    }

    struct Result: Equatable, Sendable {
        var verified: [String] = []
        var findings: [Finding] = []
        var passed: Bool { findings.isEmpty }
    }

    static func run(_ manifest: AdoptionManifest, state: URL) throws -> Result {
        guard let stateRoot = AdoptionInventory.canonicalDirectory(state),
              let ledger = try AdoptionLedger.load(from: stateRoot) else {
            throw AdoptionError.ledgerMismatch("no adoption ledger in \(state.path)")
        }
        let root = URL(fileURLWithPath: ledger.destinationRoot, isDirectory: true)
        let source = URL(fileURLWithPath: manifest.sourceRoot, isDirectory: true)
        guard ledger.sourceRoot == source.path else {
            throw AdoptionError.ledgerMismatch("the ledger was made for \(ledger.sourceRoot)")
        }
        let reader = try CatalogueReader(grantedRoot: root, rootInstanceID: ledger.rootInstanceID, mode: .adopted,
                                         identifyPDF: CataloguePDFIdentity.identify)
        let done = ledger.items.filter(\.value.completed)
        let snapshot = reader.snapshot(.init(relativePDFPaths: done.keys.sorted(), isComplete: false))
        let entries = Dictionary(manifest.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })

        var result = Result()
        // An accepted entry that never landed is a finding, so an empty or partial conversion never reads as verified.
        for entry in manifest.entries where entry.decision == .accept && done[entry.path] == nil {
            let blocker = entry.review.first { !$0.convertible }
            result.findings.append(.init(path: entry.path, problem: blocker.map { "accepted but cannot convert: \($0.rawValue)" }
                                         ?? "accepted but not converted"))
        }
        for (path, item) in done.sorted(by: { $0.key < $1.key }) {
            var problems: [String] = []
            guard let entry = entries[path] else {
                result.findings.append(.init(path: path, problem: "converted but no longer in the manifest"))
                continue
            }
            let sourceURL = source.appendingPathComponent(path)
            if (try? AdoptionConversion.digest(of: sourceURL)) != item.sourceSHA256 {
                problems.append("the source PDF's bytes changed")
            }
            if case .success(let names, let label) = TagReading.read(sourceURL), names == entry.tags,
               label == entry.labelNumber {} else { problems.append("the source PDF's tags changed") }

            switch snapshot.facts(at: path).file {
            case .failure(let why):
                problems.append("the derived pair does not read: \(why)")
            case .success(let file):
                let record = file.pair.record
                if record.originalJSON != item.record { problems.append("the companion is not the record that was filed") }
                let pages = CGPDFDocument(root.appendingPathComponent(path) as CFURL)?.numberOfPages
                if pages != entry.pageCount || record.pages.count != entry.pageCount {
                    problems.append("page count \(pages ?? 0) differs from the source's \(entry.pageCount ?? 0)")
                }
                problems += compare(entry.proposal, with: record)
                if let preservation = item.preservation {
                    problems += checkOriginal(preservation, reader: reader, occurrence: file.pair.occurrence,
                                              identity: .init(fileID: record.fileID, contentRevision: record.contentRevision))
                } else if record.preservationManifestSHA256 != nil {
                    problems.append("the companion names a preserved original that was not filed")
                }
            }
            if problems.isEmpty { result.verified.append(path) }
            result.findings += problems.map { Finding(path: path, problem: $0) }
        }
        return result
    }

    private static func current<T>(_ field: CatalogueRecord.Field<T>?) -> T? {
        guard let field, case .value(let value) = field.current else { return nil }
        return value
    }

    /// The effective facts a reader sees, against what the reviewer approved.
    static func compare(_ proposal: AdoptionManifest.Proposal, with record: CatalogueRecord) -> [String] {
        var problems: [String] = []
        let document = record.documents.first?.fields
        func expect(_ name: String, _ actual: String?, _ wanted: String?) {
            if actual != wanted { problems.append("\(name) reads \(actual ?? "nothing"), expected \(wanted ?? "nothing")") }
        }
        expect("item type", current(document?.itemType), proposal.itemType?.value)
        expect("date", current(document?.documentDate).map(dateText), proposal.documentDate.map(dateText))
        expect("sent with", current(document?.sentWith).map(dateText), proposal.sentWith.map(dateText))
        expect("subjects", current(document?.subjects)?.joined(separator: "|"),
               proposal.subjects.isEmpty ? nil : proposal.subjects.joined(separator: "|"))
        expect("read state", current(record.fileFields.readState), proposal.readState?.value)
        expect("colour", current(record.fileFields.colour), proposal.colour?.value)
        expect("quality", current(record.fileFields.quality).map(String.init), proposal.quality.map { String($0.value) })
        expect("OCR poor", current(record.fileFields.ocrPoor).map { "\($0)" }, proposal.ocrPoor ? "true" : nil)
        return problems
    }

    private static func dateText(_ value: CatalogueRecord.DateValue) -> String {
        value.date.wireValue + (value.uncertain ? "?" : "")
    }

    private static func dateText(_ fact: AdoptionManifest.DateFact) -> String {
        (ArchiveDate.parse(wireValue: fact.value)?.wireValue ?? fact.value) + (fact.uncertain ? "?" : "")
    }

    private static func checkOriginal(_ preservation: ProcessorPreservationFiling, reader: CatalogueReader,
                                      occurrence: CatalogueAssociation.Occurrence,
                                      identity: CataloguePDFIdentity) -> [String] {
        do {
            let original = try PreservationCopy.open(in: reader, at: occurrence, physicalPageIndex: 0, expected: identity)
            let wanted = preservation.manifest.sources.first?.fingerprint
            return PreservationCopy.Fingerprint(bytes: original.bytes) == wanted
                ? [] : ["the preserved original differs from the source image"]
        } catch {
            return ["the preserved original does not verify: \(error)"]
        }
    }
}
