import Foundation

// MARK: - The collection's review records (W46.kit-corrections-store)
//
// What a person settled in a run's review, kept with the collection so the training kit can read it: every gap of a
// reviewed run with the model's proposal and the final call, and (once `W46.kit-hands` builds its screen) every
// corrected handwriting line. The kit counts them per material toward its thresholds: 200 person-ruled gaps of one
// material before the segmentation continuation (`seg-2b-lora-k200`), 80 corrected lines of one hand before the
// handwriting fine-tune (14-owner-calls.md call 7; `execution-plans/processing-review/13-stage-rules/12-training-kit.md`
// §7.4, §7.5). One file per run and kind in `<output>/.archivesuite/corrections/`. Format: `SPEC/collection-settings.md`
// §"The review records"; reader: `ArchiveProcessor/scripts/segbench/institutional-compute/kit_corrections.py`.
//
// Written beside the output, so it is guarded as the settings document is (`CollectionSettingsFile`): only into an
// existing output folder, never through a link, atomically, never over anything but an earlier record of the same
// run (a resumed run's review supersedes its first), and a failure never stops the run.

/// A page as the kit finds it again: the source file's name, its SHA-256 (the identity the kit's institutional import
/// already matches on, which survives a rename or a merged output), and the output PDF's name when one was written.
struct ReviewedPage: Codable, Equatable, Sendable {
    var name: String
    var sha256: String?
    var output: String?
}

/// Which collection, project and material a record belongs to. The material is the collection unless the kit is
/// told to pool several collections as one (`kit_corrections.py --pool`).
struct ReviewRecordOwner: Codable, Equatable, Sendable {
    var collectionID: UUID?
    var collectionName: String
    var projectID: UUID?
    var projectName: String?
}

/// One gap between two consecutive pages of a reviewed run.
struct ReviewedGap: Codable, Equatable, Sendable {
    /// How the final call came to be. `checked`: the person answered it in the flagged pass. `changed`: the person
    /// changed it in the skim (after or without the flagged pass). `accepted`: left as the model proposed it through
    /// the skim. The kit's 200 counts `checked` and `changed`, the gaps a person ruled on; `accepted` gaps are kept so
    /// a training window of known gaps can be built around them.
    enum Ruling: String, Codable, Sendable { case checked, changed, accepted }

    /// The gap's index in the reviewed pages (between `pages[gap]` and `pages[gap + 1]`).
    var gap: Int
    var left: ReviewedPage
    var right: ReviewedPage
    var proposed: GapDecision
    var confidence: Double
    var flagged: Bool
    var final: GapDecision
    var ruling: Ruling

    var personRuled: Bool { ruling != .accepted }
}

/// A run's reviewed gaps.
struct GapReviewRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = Self.currentSchemaVersion
    var kind = "gaps"
    var runID: UUID
    var recordedAt: Date
    var owner: ReviewRecordOwner
    /// The segmentation approach that proposed (`SegmentationApproach` raw value) and its partner, if any.
    var approach: String
    var partner: String?
    var pages: Int
    var gaps: [ReviewedGap]

    var personRuled: Int { gaps.filter(\.personRuled).count }
}

/// One handwriting line a person corrected or confirmed. Written by the line-correction screen (`W46.kit-hands`);
/// the format is fixed here so the kit can read it from the start.
struct ReviewedLine: Codable, Equatable, Sendable {
    var page: ReviewedPage
    /// The line's index on the page, in the segmenter's reading order.
    var line: Int
    /// The line's boundary polygon and baseline in the page image's pixels, as the line segmenter gave them.
    var boundary: [[Double]]
    var baseline: [[Double]]?
    /// The recogniser's reading, its route id (`settings-routes.json`), and the person's text.
    var recognised: String
    var recognisedBy: String
    var corrected: String
    /// The hand, as the person names it; the kit's 80 is per hand.
    var hand: String?
}

/// A run's (or a correction session's) reviewed lines.
struct LineReviewRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = Self.currentSchemaVersion
    var kind = "lines"
    var runID: UUID
    var recordedAt: Date
    var owner: ReviewRecordOwner
    var lines: [ReviewedLine]
}

enum ReviewCorrections {
    static let folderName = "corrections"

    static func folder(in outputDirectory: URL) -> URL {
        CollectionSettingsDocument.folder(in: outputDirectory).appendingPathComponent(folderName, isDirectory: true)
    }

    static func gapsURL(runID: UUID, in outputDirectory: URL) -> URL {
        folder(in: outputDirectory).appendingPathComponent("gaps-\(runID.uuidString).json")
    }

    static func linesURL(runID: UUID, in outputDirectory: URL) -> URL {
        folder(in: outputDirectory).appendingPathComponent("lines-\(runID.uuidString).json")
    }

    // MARK: Building the gaps record (pure)

    /// Every gap between consecutive reviewed pages, with its proposal and its final call. `afterFlagged` is each
    /// page's classification once the flagged answers were applied, `final` after the skim (nil where the page was
    /// removed in the skim). A gap beside a box or folder photo is a boundary by construction and is left out, and so
    /// is a gap beside a removed page, which is no longer a gap of the run.
    static func gaps(proposals: [GapProposal], pages: [ReviewedPage], flagged: [FlaggedGapItem],
                     afterFlagged: [DocumentClassification], final: [DocumentClassification?]) -> [ReviewedGap] {
        let answered = Set(flagged.filter { $0.answer != nil }.map(\.id))
        func decision(_ c: DocumentClassification?) -> GapDecision? {
            switch c {
            case .documentStart: return .new
            case .documentContinuation: return .continue
            case .boxLabel, .folderLabel, nil: return nil
            }
        }
        return proposals.sorted { $0.gap < $1.gap }.compactMap { p in
            let k = p.gap
            guard !p.fixed, k >= 0, k + 1 < pages.count, k + 1 < afterFlagged.count, k + 1 < final.count,
                  let left = final[k], left != .boxLabel, left != .folderLabel,
                  let before = decision(afterFlagged[k + 1]), let after = decision(final[k + 1]) else { return nil }
            let ruling: ReviewedGap.Ruling = after != before ? .changed : answered.contains(k) ? .checked : .accepted
            return ReviewedGap(gap: k, left: pages[k], right: pages[k + 1], proposed: p.decision,
                               confidence: p.confidence, flagged: p.flagged, final: after, ruling: ruling)
        }
    }

    /// Everything a run's gaps record is made from, taken on the main actor when the skim closes, so the hashing and
    /// writing can go off it.
    struct GapRequest: Sendable {
        var runID: UUID
        var recordedAt: Date
        var settings: ResolvedSettingsSnapshot?
        var outputDirectory: URL
        var approach: String
        var partner: String?
        var urls: [URL]
        var outputs: [URL?]
        var proposals: [GapProposal]
        var flagged: [FlaggedGapItem]
        var afterFlagged: [DocumentClassification]
        var final: [DocumentClassification?]
    }

    /// Hash the pages, build the record and write it. Returns the problem, already logged, or nil once written (or
    /// when the run had no gap to record).
    @discardableResult
    static func recordGaps(_ r: GapRequest) -> String? {
        let pages = r.urls.enumerated().map { i, url in
            ReviewedPage(name: url.lastPathComponent, sha256: InstitutionalComputeImport.sha256(of: url),
                         output: i < r.outputs.count ? r.outputs[i]?.lastPathComponent : nil)
        }
        let gaps = gaps(proposals: r.proposals, pages: pages, flagged: r.flagged, afterFlagged: r.afterFlagged,
                        final: r.final)
        guard !gaps.isEmpty else { return nil }
        let record = GapReviewRecord(runID: r.runID, recordedAt: r.recordedAt,
                                     owner: owner(settings: r.settings, in: r.outputDirectory),
                                     approach: r.approach, partner: r.partner, pages: pages.count, gaps: gaps)
        do { try write(record, in: r.outputDirectory) } catch {
            NSLog("ArchiveProcessor: the run's reviewed gaps were not recorded: %@", "\(error)")
            return "\(error)"
        }
        return nil
    }

    /// The collection's id and name from its settings document (written when the run started), else the run's frozen
    /// snapshot and the folder's name.
    static func owner(settings: ResolvedSettingsSnapshot?, in outputDirectory: URL) -> ReviewRecordOwner {
        var owner = ReviewRecordOwner(collectionID: settings?.collectionID, collectionName: outputDirectory.lastPathComponent,
                                      projectID: settings?.projectID, projectName: settings?.projectName)
        if case .document(let d) = CollectionSettingsFile.read(in: outputDirectory) {
            owner.collectionID = d.collection.id
            owner.collectionName = d.collection.name
            owner.projectID = d.projectID ?? owner.projectID
            owner.projectName = d.projectName ?? owner.projectName
        }
        return owner
    }

    // MARK: Writing and reading

    /// Write a run's gaps record. An earlier record of the same run (a resume that reviewed again) is replaced
    /// atomically; a later one, a newer build's, or anything at that name that is not an ordinary file is left alone.
    static func write(_ record: GapReviewRecord, in outputDirectory: URL) throws {
        try write(record, recordedAt: record.recordedAt, to: gapsURL(runID: record.runID, in: outputDirectory),
                  in: outputDirectory)
    }

    static func write(_ record: LineReviewRecord, in outputDirectory: URL) throws {
        try write(record, recordedAt: record.recordedAt, to: linesURL(runID: record.runID, in: outputDirectory),
                  in: outputDirectory)
    }

    /// What the replace rule reads of a record already at the name.
    private struct Existing: Decodable {
        let schemaVersion: Int
        let recordedAt: Date?
    }

    private static func write<T: Encodable>(_ record: T, recordedAt: Date, to url: URL, in outputDirectory: URL) throws {
        try CollectionSettingsFile.ensureFolders(in: outputDirectory, subfolder: folderName)
        let data: Data
        do { data = try CollectionSettingsFile.encoder().encode(record) }
        catch { throw CollectionSettingsError.writeFailed(error.localizedDescription) }
        guard data.count <= maxBytes else { throw CollectionSettingsError.tooLarge(data.count) }
        switch CollectionSettingsFile.probe(url) {
        case .missing: break
        case .file(let size):
            // A newer build's record of the run is left alone, and so is a later review of it (two writes of one run
            // racing off the main actor). One that cannot be read as a record at all is replaced.
            if size <= maxBytes, let old = try? Data(contentsOf: url),
               let existing = try? CollectionSettingsFile.decoder().decode(Existing.self, from: old) {
                if existing.schemaVersion > GapReviewRecord.currentSchemaVersion {
                    throw CollectionSettingsError.newerSchema(existing.schemaVersion)
                }
                if let then = existing.recordedAt, then > recordedAt { return }
            }
        case .unknown: throw CollectionSettingsError.cannotRead(url.path)
        case .directory, .other: throw CollectionSettingsError.notARegularFile(url.path)
        }
        // `.atomic` writes a temporary file and renames it over the name, which replaces the entry itself and
        // never writes through it.
        do { try data.write(to: url, options: .atomic) }
        catch { throw CollectionSettingsError.writeFailed(error.localizedDescription) }
    }

    /// A record is at most 8 MB: about 20,000 gaps, far past any run's review.
    static let maxBytes = 8 * 1024 * 1024

    /// The collection's gaps records, by file name; a file that is not one, a link or an oversized file is skipped.
    static func gapRecords(in outputDirectory: URL) -> [GapReviewRecord] {
        records(prefix: "gaps-", in: outputDirectory)
    }

    static func lineRecords(in outputDirectory: URL) -> [LineReviewRecord] {
        records(prefix: "lines-", in: outputDirectory)
    }

    private static func records<T: Decodable>(prefix: String, in outputDirectory: URL) -> [T] {
        let dir = folder(in: outputDirectory)
        guard CollectionSettingsFile.probe(CollectionSettingsDocument.folder(in: outputDirectory)) == .directory,
              CollectionSettingsFile.probe(dir) == .directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.sorted().compactMap { name in
            let url = dir.appendingPathComponent(name)
            guard case .file(let size) = CollectionSettingsFile.probe(url), size <= maxBytes,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? CollectionSettingsFile.decoder().decode(T.self, from: data)
        }
    }
}
