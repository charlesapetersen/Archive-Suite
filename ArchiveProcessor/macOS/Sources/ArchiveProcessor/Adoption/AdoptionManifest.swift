import ArchiveCore
import Foundation

/// The reviewable plan for adopting a pre-app archive (W49.corpus-adoption-tool, owner call 31). The inventory writes
/// it without touching the source; a reviewer edits each entry's `decision`; conversion files only accepted entries
/// into a separate derived archive. Every proposed fact names the rule and the evidence behind it, and the source's
/// own tags are kept verbatim so nothing the old archive carried is lost. Format: `SPEC/adoption.md`.
struct AdoptionManifest: Codable, Equatable, Sendable {
    static let currentFormat = 1
    static let fileName = "adoption-manifest.json"

    /// How a Finder colour is read as an item type: the owner's pre-app convention, or none for any other archive.
    enum ColourPreset: String, Codable, Sendable {
        case redBoxPurpleFolder = "red-box-purple-folder"
        case none

        var colours: ItemTypeColors { self == .redBoxPurpleFolder ? .redBoxPurpleFolder : .none }
    }

    enum Decision: String, Codable, Sendable {
        /// Convert this file.
        case accept
        /// Leave it out of the derived archive.
        case skip
        /// Waiting for a reviewer; conversion leaves it alone.
        case review
    }

    /// Why an entry waits for review. A code, so a reviewer can decide a whole group at once.
    enum Reason: String, Codable, Sendable, CaseIterable {
        case pdfUnreadable = "pdf-unreadable"
        case pdfOffline = "pdf-offline"
        /// Signed, certified or otherwise unable to take a catalogue identity without changing what it protects.
        case pdfIneligible = "pdf-ineligible"
        case tagsUnreadable = "tags-unreadable"
        case alreadyCatalogued = "already-catalogued"
        case typeConflict = "type-conflict"
        case dateAmbiguous = "date-ambiguous"
        /// A date token that gave no date or only part of one (a day with no month, a month with no year).
        case dateIncomplete = "date-incomplete"
        case qualityConflict = "quality-conflict"
        case originalMissing = "original-missing"
        case originalAmbiguous = "original-ambiguous"
        case originalUnknown = "original-unknown"
        case originalShared = "original-shared"
        case originalMultipage = "original-multipage"
        /// The matched original is a cloud placeholder; copying it would download it.
        case originalOffline = "original-offline"
        /// The optional label classifier proposed the item type (`AdoptionClassify`); a reviewer confirms it.
        case typeClassified = "type-classified"

        /// Whether conversion can still go ahead once a reviewer accepts the entry.
        var convertible: Bool {
            switch self {
            case .pdfUnreadable, .pdfOffline, .pdfIneligible, .tagsUnreadable, .alreadyCatalogued: false
            default: true
            }
        }
    }

    /// One proposed value with the rule that produced it and the source evidence, quoted as found.
    struct Fact<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
        var value: Value
        var rule: String
        var evidence: String
    }

    struct DateFact: Codable, Equatable, Sendable {
        /// `ArchiveDate` wire value (`1950s`, `1957`, `1958-03`, `1958-03-12`).
        var value: String
        var uncertain: Bool
        /// The old archive's `Checked …` tag for this date: carried as a current check.
        var checked: Bool
        var rule: String
        var evidence: String
    }

    struct Proposal: Codable, Equatable, Sendable {
        var itemType: Fact<String>?
        var documentDate: DateFact?
        var sentWith: DateFact?
        var subjects: [String] = []
        var readState: Fact<String>?
        var quality: Fact<Int>?
        var ocrPoor: Bool = false
        /// The Finder colour, kept as display metadata whether or not it also decided the item type.
        var colour: Fact<String>?
    }

    struct Original: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case matched, ambiguous, missing, unknown
            /// No original tree was given: an archive without separate originals.
            case notConfigured = "not-configured"
        }
        var state: State
        /// Root-relative path under the originals tree.
        var path: String?
        /// `mirrored` (the same relative path) or `stem` (the only original with the file's name).
        var rule: String?
        var candidates: [String] = []
    }

    struct Entry: Codable, Equatable, Sendable {
        /// Root-relative path of the PDF in the source tree; the derived archive keeps it.
        var path: String
        var byteCount: Int64
        var pageCount: Int?
        var tags: [String]
        var labelNumber: Int?
        var proposal: Proposal
        var original: Original
        var review: [Reason]
        var decision: Decision
        /// Preserve the matched original in the derived archive's Preservation folder.
        var keepOriginal: Bool
        /// The optional label classifier's verdict (`box`, `folder`, `document` or `unread`), so a later pass does
        /// not read the file again. Absent when the pass has not read it.
        var classified: Fact<String>? = nil
    }

    var format = Self.currentFormat
    var createdAt: Date
    var sourceRoot: String
    var originalsRoot: String?
    var colours: ColourPreset
    /// False when a folder or file could not be read during the walk: the inventory is then not the whole tree.
    var complete: Bool
    var unreadable: [String]
    var entries: [Entry]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Self.self, from: data)
        guard manifest.format == currentFormat else { throw AdoptionError.unsupportedManifest(manifest.format) }
        return manifest
    }

    /// Set `decision` on every entry still waiting whose reasons all belong to `reasons` (the reviewer's bulk call).
    /// Entries with a reason that cannot convert stay as they are when the decision is `accept`.
    mutating func decide(_ decision: Decision, reasons: Set<Reason>, keepOriginal: Bool? = nil) -> Int {
        var changed = 0
        for index in entries.indices where entries[index].decision == .review {
            let entry = entries[index]
            guard !entry.review.isEmpty, Set(entry.review).isSubset(of: reasons) else { continue }
            if decision == .accept, entry.review.contains(where: { !$0.convertible }) { continue }
            entries[index].decision = decision
            if let keepOriginal {
                entries[index].keepOriginal = keepOriginal && entry.original.state == .matched
                    && !entry.review.contains(.originalOffline)
            }
            changed += 1
        }
        return changed
    }
}

enum AdoptionError: LocalizedError, Equatable {
    case unsupportedManifest(Int)
    case sourceMissing(String)
    case destinationInsideSource
    case sourceInsideDestination
    case statePlacement(String)
    case busy
    case protectedCorpus(String)
    case destinationNotEmpty(String)
    case ledgerMismatch(String)
    case noQPDF

    var errorDescription: String? {
        switch self {
        case .unsupportedManifest(let format): "adoption manifest format \(format) is not supported"
        case .sourceMissing(let path): "source folder not found: \(path)"
        case .destinationInsideSource: "the derived archive cannot be inside the source tree"
        case .sourceInsideDestination: "the source tree cannot be inside the derived archive"
        case .statePlacement(let why): "the adoption state folder \(why)"
        case .busy: "another adoption step is using this state folder"
        case .protectedCorpus(let path):
            "\(path) is the real archive; adoption runs on a scratch copy until the owner approves a real run"
        case .destinationNotEmpty(let path): "the derived archive folder already holds files this run did not make: \(path)"
        case .ledgerMismatch(let why): "the adoption ledger does not match this manifest: \(why)"
        case .noQPDF: "qpdf is needed to copy a PDF with its catalogue identity and was not found"
        }
    }
}
