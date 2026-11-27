import Foundation
import ArchiveCore

// MARK: - Document Segment

struct DocumentSegment {
    var pdfURLs: [URL]
    var isBox: Bool = false
    var isFolder: Bool = false
    var texts: [String] = []
    /// W37.dual-date — PROPOSED enclosure relation: the index (in the same `segment(...)` result array)
    /// of the covering-letter segment this document was sent with. `nil` = not an enclosure. Only set
    /// by `DocumentSegmenter` from the OCR model's explicit `[enclosure]` marker on this segment's
    /// start page — never inferred from adjacency, dates in body text, or a neighbour's format. The
    /// owner can clear it in manual review.
    var enclosureOf: Int? = nil
    /// W49.proc-s047-cover-select (owner call 33) — set only when the baseline check dropped this
    /// segment's OCR-proposed relation (a window split or a review edit changed its cover's pages): the
    /// indices of the document segments in the same collection before it that are not enclosures themselves
    /// (enclosures share one cover, as proposals chain), oldest first, any one of which document review may
    /// name as the actual cover. Empty everywhere else, so nothing is offered.
    var coverCandidates: [Int] = []
    var combinedText: String { texts.joined(separator: "\n\n") }
}

// MARK: - Segmenter

struct DocumentSegmenter {

    /// Segment files using LLM-provided classifications.
    /// Falls back to text heuristics for files without classifications.
    ///
    /// - Parameter enclosureFlags: W37 — `enclosureFlags[i]` is true when the OCR model marked file
    ///   `i` (a `[document_start]` page) as an enclosure of the covering letter before it. Missing →
    ///   false. A flag only becomes a relation when the page is a confirmed document START whose
    ///   immediately preceding unit in this run is a DOCUMENT segment (a box/folder label in between is
    ///   a collection boundary, which a relation never crosses). Several consecutive enclosures all
    ///   point at the same covering letter, never at each other.
    /// - Parameter expectedCoverPages: W37 — the proposal BASELINE (`coverPageSequences` of a
    ///   segmentation by the model's own OCR classifications). When supplied, a relation survives only if
    ///   the pages from its cover's first page up to the enclosure are EXACTLY the baseline's for that
    ///   enclosure's start page; any boundary change, removal or insertion around the cover drops it
    ///   (dropping is the safe direction — the owner can still type the date). `nil` = no baseline check
    ///   (used to compute the baseline itself).
    /// - Parameter chosenCovers: W49.proc-s047-cover-select — the cover a person named in document review
    ///   for an enclosure whose proposal the baseline check dropped, as enclosure first-page path → cover
    ///   first-page path. It restores the relation only when that cover is one of the segment's
    ///   `coverCandidates`; anything else is ignored, so a stale choice can never point across a
    ///   collection. Never consulted for a relation the baseline kept.
    /// - Parameter folderStarts: Page indices at tree-folder boundaries. These end the preceding
    ///   document and its enclosure context even when the next page is classified as a continuation.
    func segment(
        files: [URL],
        classifications: [DocumentClassification?],
        texts: [String],
        enclosureFlags: [Bool] = [],
        expectedCoverPages: [URL: [URL]]? = nil,
        chosenCovers: [String: String] = [:],
        folderStarts: Set<Int> = []
    ) -> [DocumentSegment] {
        guard !files.isEmpty else { return [] }

        var segments: [DocumentSegment] = []
        var currentFiles: [URL] = []
        var currentTexts: [String] = []
        var currentEnclosureOf: Int? = nil
        var firstSegmentInFolder = 0
        // The first segment of each segment's tree folder, aligned with `segments`.
        var folderFirst: [Int] = []

        func flush() {
            guard !currentFiles.isEmpty else { return }
            folderFirst.append(firstSegmentInFolder)
            segments.append(DocumentSegment(pdfURLs: currentFiles, texts: currentTexts,
                                            enclosureOf: currentEnclosureOf))
            currentFiles = []
            currentTexts = []
            currentEnclosureOf = nil
        }

        for index in files.indices {
            if folderStarts.contains(index) {
                flush()
                firstSegmentInFolder = segments.count
            }
            let file = files[index]
            let text = index < texts.count ? texts[index] : ""
            let classification = index < classifications.count ? classifications[index] : nil

            switch classification {
            case .boxLabel:
                flush()
                folderFirst.append(firstSegmentInFolder)
                segments.append(DocumentSegment(pdfURLs: [file], isBox: true, texts: [text]))

            case .folderLabel:
                flush()
                folderFirst.append(firstSegmentInFolder)
                segments.append(DocumentSegment(pdfURLs: [file], isFolder: true, texts: [text]))

            case .documentContinuation:
                // Add to current segment (or start new if nothing to continue). A continuation page
                // never starts or changes a relation — it inherits its segment's, nothing more.
                currentFiles.append(file)
                currentTexts.append(text)

            case .documentStart, .none:
                // Flush current segment and start a new one
                flush()
                // W37: only an explicit `.documentStart` carrying the model's marker proposes a relation
                // (an unclassified `.none` page is a guessed boundary, not a confirmed one).
                let flagged = classification == .documentStart
                    && index < enclosureFlags.count && enclosureFlags[index]
                if flagged, let previous = segments.indices.last, previous >= firstSegmentInFolder,
                   !segments[previous].isBox, !segments[previous].isFolder {
                    // Chain consecutive enclosures to the ONE covering letter.
                    currentEnclosureOf = segments[previous].enclosureOf ?? previous
                }
                currentFiles.append(file)
                currentTexts.append(text)
            }
        }

        // Flush final segment
        flush()

        if let expectedCoverPages {
            let actual = Self.coverPageSequences(segments)
            for i in segments.indices where segments[i].enclosureOf != nil {
                let start = segments[i].pdfURLs.first
                let matches = start.map { s in expectedCoverPages[s] != nil && actual[s] == expectedCoverPages[s] } ?? false
                guard !matches else { continue }
                segments[i].enclosureOf = nil
                // Owner call 33: the dropped relation may be restored only by a person naming the cover.
                // Offer the document segments back to the nearest box, folder label or tree folder start —
                // the same collection rule a proposal obeys — and never pick one from adjacency. An enclosure
                // (its relation already settled, as `i` runs forward) is never a cover.
                var candidates: [Int] = []
                var c = i - 1
                while c >= folderFirst[i], !segments[c].isBox, !segments[c].isFolder {
                    if segments[c].enclosureOf == nil { candidates.insert(c, at: 0) }
                    c -= 1
                }
                segments[i].coverCandidates = candidates
                if let start, let chosen = chosenCovers[start.path],
                   let cover = candidates.first(where: { segments[$0].pdfURLs.first?.path == chosen }) {
                    segments[i].enclosureOf = cover
                }
            }
        }

        return segments
    }

    /// W37 — for each related segment, keyed by its first page: every page from its cover's first page
    /// up to (not including) the enclosure itself, in order. Two segmentations agree on a relation only
    /// when these sequences are identical.
    static func coverPageSequences(_ segments: [DocumentSegment]) -> [URL: [URL]] {
        var out: [URL: [URL]] = [:]
        for (i, seg) in segments.enumerated() {
            guard let c = seg.enclosureOf, c >= 0, c < i, let start = seg.pdfURLs.first else { continue }
            out[start] = segments[c..<i].flatMap { $0.pdfURLs }
        }
        return out
    }
}

// MARK: - Enclosure dates (W37.dual-date)

/// Pure derivation of an enclosure's `Sent With` date from its covering letter's OWN date. No LLM, no
/// I/O. The covering letter never receives the enclosure's date; an undated cover yields no sent-with
/// date (a neighbour's date is never borrowed).
enum EnclosureDates {

    /// The item's own date as one `ArchiveDate`, from the GeneratedTags date strings (`TypedDateTags.date`).
    /// `nil` when there is no year, the tags are OCR-failed, or a present component does not parse / does not
    /// form a real date (e.g. Feb 30) — a disputed cover date is left for review, not silently truncated.
    static func ownDate(of tags: GeneratedTags) -> ArchiveDate? {
        guard !tags.ocrFailed else { return nil }
        return TypedDateTags.date(year: tags.year, month: tags.month, day: tags.day)
    }

    /// Set (or clear) `tags.sentWith` / `sentWithUncertain` from the covering letter's final tags.
    /// `cover == nil` (no relation, or the cover was never tagged) or an undated cover → cleared.
    static func applySentWith(fromCover cover: GeneratedTags?, to tags: inout GeneratedTags) {
        guard let cover, let date = ownDate(of: cover) else {
            tags.sentWith = nil
            tags.sentWithUncertain = false
            return
        }
        tags.sentWith = date
        tags.sentWithUncertain = cover.dateUncertain
    }

    /// An operator-typed Sent-with value ("1958", "1958-03", "1958-03-12", "1950s").
    enum ManualEntry: Equatable {
        case empty
        case valid(ArchiveDate)
        case invalid
    }

    /// `.empty` for blank input, `.invalid` for anything `ArchiveDate.parse(wireValue:)` rejects —
    /// an invalid entry is never written.
    static func parseManual(_ text: String) -> ManualEntry {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .empty }
        if let d = ArchiveDate.parse(wireValue: t) { return .valid(d) }
        return .invalid
    }

    /// Resolve a manual card's sent-with value. An explicit valid entry wins (with the card's own
    /// uncertain toggle); an empty entry falls back to the (owner-reviewed) relation's cover date, where
    /// the toggle can only ADD uncertainty; an invalid entry writes nothing.
    static func resolveManual(entry: String, uncertain: Bool, cover: GeneratedTags?, into tags: inout GeneratedTags) {
        switch parseManual(entry) {
        case .valid(let d):
            tags.sentWith = d
            tags.sentWithUncertain = uncertain
        case .invalid:
            tags.sentWith = nil
            tags.sentWithUncertain = false
        case .empty:
            applySentWith(fromCover: cover, to: &tags)
            if tags.sentWith != nil && uncertain { tags.sentWithUncertain = true }
        }
    }

    /// The source-date lines for a newly generated PDF's OCR-text header, from the tags known at
    /// render time. `nil` when neither date is known.
    static func pdfSourceDates(for tags: GeneratedTags) -> PDFSourceDates? {
        let lines = PDFSourceDates(documentDate: ownDate(of: tags)?.display, sentWith: tags.sentWith?.display)
        return lines.isEmpty ? nil : lines
    }
}
