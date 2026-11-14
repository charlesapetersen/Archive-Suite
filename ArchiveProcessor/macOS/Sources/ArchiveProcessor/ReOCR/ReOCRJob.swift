import ArchiveCore
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Improve OCR: one file's run, behind the dialog (W44.reocr-processor)

/// One file through Improve OCR (`SPEC/improve-ocr.md` §5–6), without any UI:
///
/// 1. `start` validates the pairs, then `ReOCRFileWriter.prepare` keeps a verified copy of the file and journals it
///    before anything is read. Everything after works from that copy's bytes, so the candidate is built on exactly
///    the snapshot `accept` later checks the live file against.
/// 2. Each selected pair's image page goes to the reader as a private JPEG in `scratch` (0700, files 0600, each removed
///    after its reading): the page's own JPEG bytes when that is exactly what the page shows (`embeddedJPEG`), else a
///    300 dpi rendering. The old text pages are never read. A failure after `prepare` records the operation rejected.
/// 3. When every selected pair has a reading, the replacement pages go through `ReOCRIncrementalWriter`, which proves
///    the candidate kept the rest. One failed pair means no candidate: a partial batch cannot be accepted.
/// 4. `accept` publishes through `ReOCRFileWriter`, then writes the content receipt for the Reader and clears only
///    the `OCR Poor` flag generation the review saw (plan §5 step 5, §6): tag clearing and replacement are not one
///    atomic step, so a flag that cannot be cleared leaves the good text in place and is reported, and `clearFlag`
///    retries that step alone. `reject` records the verdict and leaves the file as it is.
/// It needs the connected shared support folder (receipts and flag generations) and the file's archive root; without
/// them it refuses before keeping or reading anything, never falling back to an unshared record.
///
/// The reader is injected: the dialog passes the chosen route, the self-test a fake. Nothing here spends money.
struct ReOCRJob {
    let writer: ReOCRFileWriter
    /// Private scratch for the image inputs; the caller removes it.
    let scratch: URL
    /// The connected shared support folder.
    let support: URL

    var flags: ImproveOCRFlagStore { ImproveOCRFlagStore(support: support) }
    static let app = "Processor"

    /// The archive the file belongs to: its root marker's GUID and the folder the Processor was granted.
    struct Root: Sendable {
        let guid: UUID
        let url: URL
    }

    typealias Reader = @Sendable (_ image: URL, _ pair: ReOCRPairs.Pair, _ kind: OCRPageKind?) async -> OCRResult

    struct PairResult: Sendable {
        let pair: ReOCRPairs.Pair
        let oldText: String
        let kind: OCRPageKind?
        /// The new text, or why there is none.
        let outcome: Result<String, ReOCRPairs.Refusal>
    }

    struct Review: Sendable {
        let operation: ReOCRFileWriter.Operation
        let key: ImproveOCRFlagStore.FileKey
        /// The flag generation and the tag when the review began: acceptance clears only this generation.
        let reviewedGeneration: UUID?
        let flaggedAtReview: Bool
        let results: [PairResult]
        /// Present only when every selected pair was read and the candidate passed the preservation check.
        let candidate: Data?
        let candidateProblem: String?
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notEligible(ReOCRPairs.Refusal)
        case noSuchPair(page: Int)
        case nothingSelected
        case imageNotExtracted(page: Int)
        case noCandidate
        case tagsUnreadable
        case notRestorable(String)

        var description: String {
            switch self {
            case .notEligible(let r): "this file cannot be improved in place: \(r)"
            case .noSuchPair(let p): "page \(p + 1) is not a text page of this file"
            case .nothingSelected: "no page was selected"
            case .imageNotExtracted(let p): "page \(p + 1) could not be prepared for reading"
            case .noCandidate: "not every selected page was read, so there is nothing to accept"
            case .tagsUnreadable: "the file's tags cannot be read"
            case .notRestorable(let why): "the old text cannot be put back: \(why)"
            }
        }
    }

    /// `textPages` selects pairs by their text page's 0-based index (nil: every pair); `kinds` overrides a pair's
    /// Kind by the same index (absent: the header's own).
    /// `pageModels` names, by text page, the model a page's reader is (for its header) when it is not `model`.
    func start(file: URL, root: Root, textPages: Set<Int>? = nil, kinds: [Int: OCRPageKind] = [:], model: LLMModel,
               pageModels: [Int: LLMModel] = [:],
               gatewayDisplayName: String? = nil, localAgentDisplayName: String? = nil, localAgentModelName: String? = nil,
               read: Reader) async throws -> Review {
        try flags.checkSuitable()
        let key = try ImproveOCRFlagStore.FileKey(rootGUID: root.guid, root: root.url, file: file)
        let reviewed = try flags.withLock(key, app: Self.app) { try $0.state() }
        guard let flaggedAtReview = Self.isFlagged(file) else { throw Failure.tagsUnreadable }
        let live = try Data(contentsOf: file)
        let pairs: [ReOCRPairs.Pair]
        switch ReOCRPairs.validate(live) {
        case .success(let p): pairs = p
        case .failure(let r): throw Failure.notEligible(r)
        }
        if let textPages, let bad = textPages.first(where: { t in !pairs.contains { $0.textIndex == t } }) {
            throw Failure.noSuchPair(page: bad)
        }
        let selected = pairs.filter { textPages?.contains($0.textIndex) ?? true }
        guard !selected.isEmpty else { throw Failure.nothingSelected }

        let op = try writer.prepare(target: file)
        let record = Record(operationID: op.journal.operationID, key: key, reviewedGeneration: reviewed.generation,
                            flaggedAtReview: flaggedAtReview, textPages: selected.map(\.textIndex))
        var results: [PairResult] = []
        var replacements: [Int: Data] = [:]
        let original: Data
        do {
            try writer.writeRecord(record, named: Record.file, for: op.journal.operationID)
            // From here, the verified copy: the bytes the journal's snapshot names, checked again by digest.
            original = try Data(contentsOf: writer.backupURL(op.journal.operationID))
            guard ReOCRFileWriter.hex(SHA256.hash(data: original)) == op.journal.original.sha256,
                  case .success(let checked) = ReOCRPairs.validate(original), checked == pairs else {
                throw Failure.notEligible(.unreadable)
            }
            try Self.makePrivateDirectory(scratch)
            let oldDoc = PDFDocument(data: original)
            for pair in selected {
                let kind = kinds[pair.textIndex] ?? pair.header.kind
                let oldText = oldDoc?.page(at: pair.textIndex).map { PDFHeaderParser.parse($0).body } ?? ""
                let image = scratch.appendingPathComponent("\(op.journal.operationID.uuidString)-p\(pair.imageIndex + 1).jpg")
                guard Self.writeImageInput(original, pageIndex: pair.imageIndex, to: image) else {
                    throw Failure.imageNotExtracted(page: pair.imageIndex)
                }
                let reading = await read(image, pair, kind)
                try? FileManager.default.removeItem(at: image)   // a page of the archive; not kept past its reading
                do {
                    let page = try ReOCRPairs.replacementPage(for: pair, result: reading, model: pageModels[pair.textIndex] ?? model, kind: kind,
                                                              gatewayDisplayName: gatewayDisplayName,
                                                              localAgentDisplayName: localAgentDisplayName,
                                                              localAgentModelName: localAgentModelName)
                    replacements[pair.textIndex] = page
                    // W42.int-s5: the image page's searchable layer follows the new reading, or the old one would stay.
                    if let image = await Self.remadeImagePage(original, pair: pair, reading: reading, kind: kind,
                                                              model: pageModels[pair.textIndex] ?? model) {
                        replacements[pair.imageIndex] = image
                    }
                    // The Kind actually written, which falls back to the reader's own when none was chosen.
                    let written = PDFDocument(data: page)?.page(at: 0).flatMap { PDFHeaderParser.parse($0).header?.kind }
                    results.append(PairResult(pair: pair, oldText: oldText, kind: written, outcome: .success(reading.text ?? "")))
                } catch let r as ReOCRPairs.Refusal {
                    results.append(PairResult(pair: pair, oldText: oldText, kind: kind, outcome: .failure(r)))
                }
            }
        } catch {
            // No review comes back, so nobody could reject it: record the verdict here rather than strand the copy.
            try? writer.reject(op)
            throw error
        }
        func review(_ candidate: Data?, _ problem: String?) -> Review {
            Review(operation: op, key: key, reviewedGeneration: reviewed.generation, flaggedAtReview: flaggedAtReview,
                   results: results, candidate: candidate, candidateProblem: problem)
        }
        // Every selected text page replaced (an image page beside one is extra, W42.int-s5).
        guard Set(selected.map(\.textIndex)).isSubset(of: replacements.keys) else { return review(nil, nil) }
        do {
            return review(try ReOCRIncrementalWriter.candidate(original: original, replacements: replacements), nil)
        } catch {
            return review(nil, "\(error)")
        }
    }

    /// What the job keeps beside the operation's journal (`job.json`): enough to finish the receipt and the flag after
    /// a relaunch, and for restore. Written after `prepare`, updated after each step.
    struct Record: Codable, Equatable, Sendable {
        let operationID: UUID
        let key: ImproveOCRFlagStore.FileKey
        let reviewedGeneration: UUID?
        let flaggedAtReview: Bool
        let textPages: [Int]
        var receiptWritten = false
        /// Nil until a clear was tried; `failed` is retried by `recover`, the others are settled.
        var flag: FlagOutcome?
        /// Set on a restore's own record: the accepted operation it undid.
        var restores: UUID?
        /// Set on an accepted operation's record once a restore undid it.
        var restoredBy: UUID?
        /// A restore's re-flag outcome.
        var reflag: ReflagOutcome?

        static let file = "job.json"
    }

    enum FlagOutcome: Codable, Equatable, Sendable {
        case cleared
        /// The file was not flagged when reviewed and is not now: nothing to clear.
        case notFlagged
        /// Someone flagged or unflagged it since the review, or their action is unfinished: left for the person.
        case changedSinceReview(String)
        case failed(String)

        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    struct Accepted: Sendable {
        let journal: ReOCRFileWriter.Journal
        /// Nil when written; else why not (the text is in place regardless; `recover` retries).
        let receiptProblem: String?
        let flag: FlagOutcome
        /// Nil when the job's record was updated; else a later `recover` may repeat a settled step's check.
        let recordProblem: String?
    }

    /// Publishes, then records the receipt, then clears the reviewed flag. The publication throws: before the swap the
    /// file is as it was; `publishedButUnverified` or `publishedRecordPending` mean the new text is in place but its
    /// record is not finished, which launch recovery completes (receipt and flag included). The two steps after a
    /// clean publication report their outcome instead, so the person sees "text accepted; flag still needs clearing".
    func accept(_ review: Review) throws -> Accepted {
        guard let candidate = review.candidate else { throw Failure.noCandidate }
        try flags.checkSuitable()
        let journal = try writer.accept(review.operation, candidate: candidate)
        let fallback = Record(operationID: journal.operationID, key: review.key, reviewedGeneration: review.reviewedGeneration,
                              flaggedAtReview: review.flaggedAtReview, textPages: review.results.map(\.pair.textIndex))
        let done = finish(journal, fallback: fallback)
        return Accepted(journal: journal, receiptProblem: done.receiptProblem, flag: done.flag, recordProblem: done.recordProblem)
    }

    /// The steps after a publication, from the job's record: the receipt if not yet written, then the flag unless it
    /// is settled. Records each outcome. Used by `accept` and by `recover` after a relaunch.
    private func finish(_ journal: ReOCRFileWriter.Journal, fallback: Record? = nil)
        -> (receiptProblem: String?, flag: FlagOutcome, recordProblem: String?) {
        let id = journal.operationID
        guard var record = (try? writer.readRecord(Record.self, named: Record.file, for: id)) ?? fallback else {
            return ("the job's record cannot be read", .failed("the job's record cannot be read"), "the job's record cannot be read")
        }
        var receiptProblem: String?
        if !record.receiptWritten {
            do {
                try writeReceipt(record, journal)
                record.receiptWritten = true
            } catch { receiptProblem = "\(error)" }
        }
        let flag: FlagOutcome
        if record.restores != nil {
            // A restore clears nothing; its re-flag is decided once, by `restore`. A crash inside that re-flag left this
            // operation's intent as a barrier: settle it with the tag as it is.
            _ = try? flags.withLock(record.key, app: Self.app) { l -> Void in
                if let pending = try l.state().pending, pending.operationID == id {
                    _ = try l.reconcile(observedFlagged: Self.isFlagged(URL(fileURLWithPath: journal.targetPath)) ?? false)
                }
            }
            flag = .notFlagged
        } else if let settled = record.flag, !settled.isFailure {
            flag = settled
        } else {
            flag = clearFlag(record, journal)
        }
        record.flag = flag
        var recordProblem: String?
        do { try writer.writeRecord(record, named: Record.file, for: id) } catch { recordProblem = "\(error)" }
        return (receiptProblem, flag, recordProblem)
    }

    /// The receipt for a published operation: `published` for an acceptance, `restored` for a restore. Before and after
    /// are the operation's own journal digests (for a restore: the accepted revision, then the original).
    func writeReceipt(_ record: Record, _ journal: ReOCRFileWriter.Journal) throws {
        guard journal.phase == .published, let after = journal.candidateSHA256 else { throw Failure.noCandidate }
        try ImproveOCRReceipt(operationID: journal.operationID, key: record.key, textPages: record.textPages,
                              beforeSHA256: journal.original.sha256, afterSHA256: after,
                              outcome: record.restores == nil ? .published : .restored).write(to: support)
    }

    struct Recovered: Equatable, Sendable {
        let operationID: UUID
        let writer: ReOCRFileWriter.Recovery
        /// For a published operation: whether its receipt is now written, and its flag's outcome.
        let receiptProblem: String?
        let flag: FlagOutcome?
    }

    /// At launch, before any new work: settles every operation's journal (`ReOCRFileWriter.recover`) and, for each
    /// one published, finishes its receipt and its flag from the job's record.
    func recover() -> [Recovered] {
        writer.recover().map { r -> Recovered in
            let id: UUID
            switch r {
            case .published(let i), .alreadyPublished(let i): id = i
            case .notPublished(let i), .conflict(let i, _), .rejected(let i):
                return Recovered(operationID: i, writer: r, receiptProblem: nil, flag: nil)
            }
            guard let journal = try? writer.read(id), journal.phase == .published else {
                return Recovered(operationID: id, writer: r, receiptProblem: "the journal cannot be read", flag: nil)
            }
            let done = finish(journal)
            return Recovered(operationID: id, writer: r, receiptProblem: done.receiptProblem, flag: done.flag)
        }
    }

    /// Clears `OCR Poor` from the published file, but only the generation the review saw: under the file's flag lock,
    /// `begin(ifGenerationIs:)`, the tag removed through ArchiveCore's coordinated tag writer (all spellings of the
    /// flag; nothing else), then the value read back is committed. Safe to call again.
    ///
    /// A retry after this operation's own failed or interrupted clear is recognised by the operation ID its intent and
    /// event carry, so it is not mistaken for someone else's change.
    func clearFlag(_ review: Review, _ journal: ReOCRFileWriter.Journal) -> FlagOutcome {
        clearFlag(Record(operationID: journal.operationID, key: review.key, reviewedGeneration: review.reviewedGeneration,
                         flaggedAtReview: review.flaggedAtReview, textPages: review.results.map(\.pair.textIndex)), journal)
    }

    func clearFlag(_ review: Record, _ journal: ReOCRFileWriter.Journal) -> FlagOutcome {
        let file = URL(fileURLWithPath: journal.targetPath)
        let op = journal.operationID
        do {
            return try flags.withLock(review.key, app: Self.app) { l -> FlagOutcome in
                var now = try l.state()
                if let pending = now.pending, pending.operationID == op {
                    // This operation's own clear, cut off before it finished: record what the tag is, then go on.
                    try l.reconcile(observedFlagged: Self.isFlagged(file) ?? true)
                    now = try l.state()
                }
                if now.isPending {
                    // Every suite action holds this lock from `begin` to `commit`, so an intent found under it is one
                    // that died (in either app). Record the tag as it is, which lifts the barrier for the next action;
                    // the new generation means this review is out of date.
                    try l.reconcile(observedFlagged: Self.isFlagged(file) ?? true)
                    return .changedSinceReview("an earlier action on this file did not finish")
                }
                // This operation's own earlier attempt that did not finish the clear (reconciled after a failure, or
                // read back still flagged). A finished clear of ours followed by a flag now means someone put it back.
                let ownEarlierAttempt = now.lastOperationID == op && (now.lastOrigin == .reconciled || now.flagged == true)
                if now.lastOperationID == op, now.lastOrigin == .acceptedClear, now.flagged == false {
                    return Self.isFlagged(file) == false ? .cleared : .changedSinceReview("the flag was set again after it was cleared")
                }
                guard now.generation == review.reviewedGeneration || ownEarlierAttempt else {
                    return .changedSinceReview("the file was flagged or unflagged again while it was being read")
                }
                guard let flagged = Self.isFlagged(file) else { return .failed("its tags cannot be read") }
                guard flagged else {
                    if ownEarlierAttempt { return .cleared }
                    return review.flaggedAtReview ? .changedSinceReview("the flag was removed outside the suite") : .notFlagged
                }
                // Flagged now but not when reviewed: someone set it during the read (perhaps outside the suite).
                guard review.flaggedAtReview else { return .changedSinceReview("the file was flagged while it was being read") }
                // Still the file this operation published, not one put in its place since.
                var st = stat()
                guard lstat(file.path, &st) == 0, st.st_ino == journal.stagedInode else {
                    return .changedSinceReview("the file was replaced after the new text was put in place")
                }
                let intent = try l.begin(flagged: false, origin: .acceptedClear, ifGenerationIs: now.generation, operationID: op)
                do {
                    _ = try CoordinatedTagWriter.write(file) { tags, label in
                        let kept = tags.filter { !shouldRemoveTag($0, matching: DocumentTags.poorOCRTag) }
                        return kept.count == tags.count ? nil : (kept, label)
                    }
                } catch {
                    // The barrier must not outlive this call: record what the tag is now.
                    _ = try? l.reconcile(observedFlagged: Self.isFlagged(file) ?? true)
                    return .failed("\(error)")
                }
                let observed = Self.isFlagged(file) ?? true
                try l.commit(intent, observedFlagged: observed)
                return observed ? .failed("the flag is still on the file") : .cleared
            }
        } catch ImproveOCRFlagStore.StoreError.generationChanged {
            return .changedSinceReview("the file was flagged or unflagged again while it was being read")
        } catch {
            return .failed("\(error)")
        }
    }

    // MARK: The reader

    /// The reader for a ranked row (plan §4): exactly the route the person chose. No cascade and no refusal fallback, so
    /// no model the person did not choose reads a page or is paid for it; rotation off, since a suite file's image
    /// pages were turned upright when it was made. Nil when the row cannot run now or names no model this app has.
    /// The caller passes the row's key (empty for a route on this Mac) and the prompt its settings use.
    static func reader(for row: ReOCRRanking.Row, apiKey: String, customPrompt: String? = nil, standardImageMB: Double = 4,
                       visionSettings: VisionOCRSettings = .default, models: [LLMModel]? = nil) -> Reader? {
        guard row.readiness == .ready,
              let model = (models ?? row.provider.models).first(where: { $0.id == row.modelID && $0.provider == row.provider })
        else { return nil }
        if row.provider != .appleVision && apiKey.isEmpty { return nil }
        let provider = row.provider
        return { image, _, _ in
            await OCRProcessor.performOCRCall(
                imageURL: image, provider: provider, model: model, thinkingLevel: model.supportsThinking ? .low : nil,
                apiKey: apiKey, previousText: nil, previousImageURL: nil, customPrompt: customPrompt, imageScale: 1,
                gatewayConfig: nil, localAgent: nil, rotationMode: .off, standardImageMB: standardImageMB,
                visionSettings: visionSettings, cascade: .off, refusalFallback: false)
        }
    }

    // MARK: Restore

    enum ReflagOutcome: Codable, Equatable, Sendable {
        case reflagged
        /// The original was not flagged, or acceptance never cleared its flag: nothing to put back.
        case notNeeded
        /// Someone flagged or unflagged the file after the clear, or the flag is already there: left as it is.
        case changedSinceClear(String)
        case failed(String)
    }

    struct Restored: Sendable {
        let journal: ReOCRFileWriter.Journal
        let receiptProblem: String?
        let flag: ReflagOutcome
    }

    /// Puts back the text an accepted operation replaced (plan §5): its own guarded transaction through
    /// `ReOCRFileWriter`, so the accepted revision is kept too and the file's current tags and dates are carried over.
    /// Refused unless the live file is exactly the accepted revision; the person decides in the review UI otherwise.
    /// The flag goes back only when acceptance cleared it and no flag action came after that clear.
    func restore(_ accepted: UUID) throws -> Restored {
        let journal = try writer.read(accepted)
        guard journal.phase == .published, let acceptedSHA = journal.candidateSHA256 else { throw Failure.notRestorable("it was not published") }
        var record = try writer.readRecord(Record.self, named: Record.file, for: accepted)
        guard record.restoredBy == nil else { throw Failure.notRestorable("it was already restored") }
        guard record.restores == nil else { throw Failure.notRestorable("it is itself a restore; read the file again instead") }
        try flags.checkSuitable()
        let target = URL(fileURLWithPath: journal.targetPath)
        guard let live = try? ReOCRFileWriter.snapshot(target.path), live.sha256 == acceptedSHA else {
            throw Failure.notRestorable("the file has changed since the new text was accepted")
        }
        let original = try Data(contentsOf: writer.backupURL(accepted))
        guard ReOCRFileWriter.hex(SHA256.hash(data: original)) == journal.original.sha256 else {
            throw Failure.notRestorable("the kept original is damaged")
        }
        let op = try writer.prepare(target: target)
        var own = Record(operationID: op.journal.operationID, key: record.key, reviewedGeneration: nil,
                         flaggedAtReview: false, textPages: record.textPages)
        own.restores = accepted
        do {
            // What `prepare` kept is what is overwritten: it must still be the accepted revision, the published file.
            guard op.journal.original.sha256 == acceptedSHA, op.journal.original.inode == journal.stagedInode else {
                throw Failure.notRestorable("the file has changed since the new text was accepted")
            }
            try writer.writeRecord(own, named: Record.file, for: op.journal.operationID)
        } catch {
            try? writer.reject(op)
            throw error
        }
        let restored: ReOCRFileWriter.Journal
        do {
            restored = try writer.accept(op, candidate: original)
        } catch let failure as ReOCRFileWriter.Failure {
            // Before the swap nothing changed: this restore is over. After it, launch recovery finishes it.
            switch failure {
            case .publishedButUnverified, .publishedRecordPending: break
            default: try? writer.reject(op)
            }
            throw failure
        }
        var receiptProblem: String?
        do {
            try writeReceipt(own, restored)
            own.receiptWritten = true
        } catch { receiptProblem = "\(error)" }
        let flag = reflag(record, accepted: journal, restore: restored)
        own.flag = .notFlagged
        own.reflag = flag
        record.restoredBy = restored.operationID
        try? writer.writeRecord(record, named: Record.file, for: accepted)
        try? writer.writeRecord(own, named: Record.file, for: restored.operationID)
        return Restored(journal: restored, receiptProblem: receiptProblem, flag: flag)
    }

    private func reflag(_ record: Record, accepted: ReOCRFileWriter.Journal, restore: ReOCRFileWriter.Journal) -> ReflagOutcome {
        guard record.flaggedAtReview, record.flag == .cleared else { return .notNeeded }
        let file = URL(fileURLWithPath: restore.targetPath)
        do {
            return try flags.withLock(record.key, app: Self.app) { l -> ReflagOutcome in
                let now = try l.state()
                if now.isPending {
                    // A dead action's barrier (see `clearFlag`): record the tag as it is, then leave the flag alone.
                    try l.reconcile(observedFlagged: Self.isFlagged(file) ?? true)
                    return .changedSinceClear("an earlier action on this file did not finish")
                }
                guard now.lastOperationID == accepted.operationID, now.lastOrigin == .acceptedClear else {
                    return .changedSinceClear("the file was flagged or unflagged after the new text was accepted")
                }
                guard let flagged = Self.isFlagged(file) else { return .failed("its tags cannot be read") }
                if flagged { return .changedSinceClear("the file is flagged already") }
                var st = stat()
                guard lstat(file.path, &st) == 0, st.st_ino == restore.stagedInode else {
                    return .changedSinceClear("the file was replaced after the old text was put back")
                }
                let intent = try l.begin(flagged: true, origin: .restored, ifGenerationIs: now.generation,
                                         operationID: restore.operationID)
                do {
                    _ = try CoordinatedTagWriter.write(file) { tags, label in
                        tags.contains { isSameTag($0, DocumentTags.poorOCRTag) } ? nil : (tags + [DocumentTags.poorOCRTag], label)
                    }
                } catch {
                    _ = try? l.reconcile(observedFlagged: Self.isFlagged(file) ?? false)
                    return .failed("\(error)")
                }
                let observed = Self.isFlagged(file) ?? false
                try l.commit(intent, observedFlagged: observed)
                return observed ? .reflagged : .failed("the flag did not stay on the file")
            }
        } catch ImproveOCRFlagStore.StoreError.generationChanged {
            return .changedSinceClear("the file was flagged or unflagged after the new text was accepted")
        } catch {
            return .failed("\(error)")
        }
    }

    /// Whether the file carries `OCR Poor` in any spelling; nil when its tags cannot be read.
    static func isFlagged(_ file: URL) -> Bool? {
        TagReading.read(file).tagNames.map { $0.contains { isSameTag($0, DocumentTags.poorOCRTag) } }
    }

    func reject(_ review: Review) throws {
        try writer.reject(review.operation)
    }

    // MARK: The image page's layer (W42.int-s5)

    /// The pair's image page remade with a searchable layer of `reading` (`PDFGenerator.remadeImagePageData`), to
    /// replace it beside the new text page; nil to leave the page as it is. The preservation check does not compare a
    /// replaced page with the original, so this is the guard that the person sees the same page: the remade page must
    /// embed exactly the original's JPEG bytes and render, pixel for pixel, as the original does (the layer paints
    /// nothing). Left: a page with no text that would get none, a page whose own JPEG is not what it shows
    /// (`embeddedJPEG`), a page not the Processor's letter size, one with a crop box of its own or annotations (the
    /// remade page would drop them), and any remade page that fails either check. A page left keeps its old layer
    /// (`KNOWN_ISSUES.md`). Off the main actor: the layer reads the page with Vision.
    static func remadeImagePage(_ pdf: Data, pair: ReOCRPairs.Pair, reading: OCRResult, kind: OCRPageKind?,
                                model: LLMModel? = nil) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let jpeg = embeddedJPEG(pdf, pageIndex: pair.imageIndex),
                  let doc = ReOCRPreservationCheck.document(pdf), let page = doc.page(at: pair.imageIndex + 1),
                  page.getBoxRect(.mediaBox).size == CGSize(width: 612, height: 792),
                  page.getBoxRect(.cropBox) == page.getBoxRect(.mediaBox), let dict = page.dictionary else { return nil }
            var annots: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Annots", &annots) { return nil }
            let hadText = !(PDFDocument(data: pdf)?.page(at: pair.imageIndex)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard let made = PDFGenerator().remadeImagePageData(jpeg: jpeg, result: reading, pageKind: kind, options: .standard,
                                                                runReader: TextLayerRule.runReader(model: model)) else { return nil }
            if made.layer.route == .textPage && !hadText { return nil }
            guard embeddedJPEG(made.pdf, pageIndex: 0) == jpeg,
                  let madeDoc = ReOCRPreservationCheck.document(made.pdf), let madePage = madeDoc.page(at: 1),
                  let before = ReOCRPreservationCheck.render(page), let after = ReOCRPreservationCheck.render(madePage),
                  before == after else { return nil }
            return made.pdf
        }.value
    }

    // MARK: Image input

    private static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), chmod(url.path, 0o700) == 0
        else { throw CocoaError(.fileWriteNoPermission) }
    }

    /// The image page as a JPEG file at `url`: its embedded JPEG stream byte for byte when the page is unrotated and
    /// draws exactly one image, which is a JPEG; otherwise a 300 dpi rendering of the page.
    static func writeImageInput(_ pdf: Data, pageIndex: Int, to url: URL) -> Bool {
        if let jpeg = embeddedJPEG(pdf, pageIndex: pageIndex) {
            return FileManager.default.createFile(atPath: url.path, contents: jpeg, attributes: [.posixPermissions: 0o600])
        }
        guard let doc = ReOCRPreservationCheck.document(pdf), let page = doc.page(at: pageIndex + 1) else { return false }
        return withExtendedLifetime(doc) { render(page, to: url) }
    }

    /// The page's JPEG, byte for byte, only when that is exactly what the page shows: an unrotated page whose content
    /// is `q`/`Q`, rectangular clips that hold the whole image, one `cm` that scales without turning, flipping or
    /// skewing and keeps the whole image inside the crop box, and one `Do` of its only XObject; the XObject a JPEG image with no mask or decode array and an upright
    /// orientation. Text that paints nothing (render mode 3: the searchable layer, W42.int-s5) is allowed; anything else
    /// (visible text, paths, clipping, shading, inline images, a second image) is rendered instead.
    static func embeddedJPEG(_ pdf: Data, pageIndex: Int) -> Data? {
        guard let doc = ReOCRPreservationCheck.document(pdf) else { return nil }
        return withExtendedLifetime(doc) { () -> Data? in
            guard let page = doc.page(at: pageIndex + 1), page.rotationAngle % 360 == 0, let dict = page.dictionary else {
                return nil
            }
            var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects,
                  CGPDFDictionaryGetCount(xobjects) == 1 else { return nil }
            final class Found { var name: String?; var stream: CGPDFStreamRef? }
            let found = Found()
            CGPDFDictionaryApplyBlock(xobjects, { key, object, info in
                let found = Unmanaged<Found>.fromOpaque(info!).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream) { found.name = String(cString: key); found.stream = stream }
                return true
            }, Unmanaged.passUnretained(found).toOpaque())
            guard let name = found.name, let stream = found.stream, let image = CGPDFStreamGetDictionary(stream) else { return nil }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(image, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" else {
                return nil
            }
            var any: CGPDFObjectRef?
            for key in ["SMask", "Mask", "Decode", "ImageMask"] where CGPDFDictionaryGetObject(image, key, &any) { return nil }
            // A Type 3 font's glyphs are content procedures that may paint even in render mode 3; the layer never uses one.
            var fonts: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts {
                final class Seen { var type3 = false }
                let seen = Seen()
                CGPDFDictionaryApplyBlock(fonts, { _, object, info in
                    let seen = Unmanaged<Seen>.fromOpaque(info!).takeUnretainedValue()
                    var font: CGPDFDictionaryRef?, subtype: UnsafePointer<CChar>?
                    if !CGPDFObjectGetValue(object, .dictionary, &font) { seen.type3 = true; return false }
                    if let font, CGPDFDictionaryGetName(font, "Subtype", &subtype), let subtype,
                       String(cString: subtype) == "Type3" { seen.type3 = true; return false }
                    return true
                }, Unmanaged.passUnretained(seen).toOpaque())
                if seen.type3 { return nil }
            }
            guard let drawn = drawsOnlyImage(page, name: name) else { return nil }
            let crop = page.getBoxRect(.cropBox).insetBy(dx: -0.5, dy: -0.5)
            guard crop.contains(drawn) else { return nil }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .jpegEncoded,
                  let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1 else {
                return nil
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            if let o = props?[kCGImagePropertyOrientation] as? Int, o != 1 { return nil }
            return data
        }
    }

    /// The rectangle the page's only `Do` of `name` covers, when the content is nothing but `q`, one upright scaling
    /// `cm`, that `Do` and `Q`; nil for anything else. Every operator that draws, clips or paints is registered so
    /// that its presence is seen (an unregistered operator would pass silently).
    private static func drawsOnlyImage(_ page: CGPDFPage, name: String) -> CGRect? {
        final class State {
            var matrix: [CGFloat]?
            var matrices = 0
            var dos: [String] = []
            var other = false
            var rects: [CGRect] = []
            var clips = 0
            /// The text render mode, saved and restored with the graphics state (`q`/`Q`); 3 paints nothing.
            var renderMode = 0
            var savedModes: [Int] = []
        }
        let state = State()
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var values: [CGFloat] = []
            for _ in 0..<6 {
                var v: CGPDFReal = 0
                guard CGPDFScannerPopNumber(scanner, &v) else { state.other = true; return }
                values.insert(v, at: 0)
            }
            state.matrix = values
            state.matrices += 1
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var n: UnsafePointer<CChar>?
            if CGPDFScannerPopName(scanner, &n), let n { state.dos.append(String(cString: n)) } else { state.other = true }
        }
        // A rectangle may only clip (`re W n`, as PDFKit writes around every page); it is checked below to hold the
        // whole image.
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var v = [CGPDFReal](repeating: 0, count: 4)
            for i in (0..<4).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { state.other = true; return } }
            state.rects.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).standardized)
        }
        CGPDFOperatorTableSetCallback(table, "W") { _, info in
            Unmanaged<State>.fromOpaque(info!).takeUnretainedValue().clips += 1
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, _ in }
        // W42.int-s5: the image page's searchable layer is text that paints nothing (render mode 3, invisible), so the
        // page still shows exactly the image. Text is allowed only in that mode; any text shown in another mode is
        // something drawn, and the page is rendered instead.
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            state.savedModes.append(state.renderMode)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            if let mode = state.savedModes.popLast() { state.renderMode = mode } else { state.other = true }
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { state.renderMode = mode } else { state.other = true }
        }
        for op in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                let state = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
                if state.renderMode != 3 { state.other = true }
            }
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, _ in }
        CGPDFOperatorTableSetCallback(table, "ET") { _, _ in }
        for op in ["m", "l", "c", "v", "y", "h", "S", "s", "f", "F", "f*", "B", "B*",
                   "b", "b*", "W*", "sh", "BI", "ID", "EI", "d0", "d1", "BDC", "BMC", "DP", "MP", "gs"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                Unmanaged<State>.fromOpaque(info!).takeUnretainedValue().other = true
            }
        }
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        let scanned = CGPDFScannerScan(scanner)
        guard scanned, !state.other, state.matrices == 1, state.dos == [name], let m = state.matrix,
              m[1] == 0, m[2] == 0, m[0] > 0, m[3] > 0, state.rects.count == state.clips else { return nil }
        let drawn = CGRect(x: m[4], y: m[5], width: m[0], height: m[3])
        // The clips are in the coordinates before the one `cm` (PDFKit writes them first); a clip after it would be in
        // image space and is refused by requiring every clip to hold the drawn rectangle in page space.
        guard state.rects.allSatisfy({ $0.insetBy(dx: -0.5, dy: -0.5).contains(drawn) }) else { return nil }
        return drawn
    }

    private static func render(_ page: CGPDFPage, to url: URL) -> Bool {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = 300.0 / 72.0
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, w * h <= 120_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0,
                                                 preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dest) && chmod(url.path, 0o600) == 0
    }
}
