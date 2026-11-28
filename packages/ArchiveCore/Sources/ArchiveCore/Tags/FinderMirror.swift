import Foundation

/// The suite's own Finder-tag mirror of a catalogue record, for an archive that turns mirroring on
/// (`W49.storage-finder-reader-mirror`; owner, 2026-11-27, `W49.storage-finder-owner-ok`).
///
/// The record stays the only place a field lives. The mirror is a projection of it: a fixed set of
/// Finder tokens derived from the record's facts, written through `CoordinatedTagWriter`, beside
/// whatever other tags the file carries. What the suite wrote is kept in an ownership record on the
/// PDF itself (`FinderMirror.Ledger`, the extended attribute `com.archivesuite.finder-mirror`), so it
/// travels with the tags it describes and both apps read the same one:
///
/// - only a token the suite introduced is ever removed again (an existing token the projection also
///   wants is left unowned, and so is every hand-made tag);
/// - a mirrored tag changed in Finder is a *divergence*: it is shown, never adopted and never
///   overwritten silently (owner's answer 2b: Import or Re-publish);
/// - Remove Suite Tags (answer 3b) takes off only owned tokens, and can put them back.
///
/// SPEC: `SPEC/tag-format.md` §"The suite's Finder mirror".
public enum FinderMirror {
    /// The extended attribute holding the ownership record. Not copied by a filing that leaves the Finder
    /// tags behind (`CataloguePairFiler.finderTagAttributes`), so it never describes tags a file lacks.
    public static let ledgerAttribute = "com.archivesuite.finder-mirror"

    // MARK: Projection

    /// The tokens and colour a record projects to. The tokens are in the order Finder shows them.
    public struct Projection: Equatable, Sendable {
        public var tokens: [String]
        public var label: FinderLabel?

        public init(tokens: [String], label: FinderLabel?) {
            self.tokens = tokens
            self.label = label
        }
    }

    /// The Finder vocabulary (`SPEC/tag-format.md`) for one occurrence's file fields and the fields of the
    /// document it shows. A cleared or unassessed field projects nothing. Subjects are written verbatim.
    public static func projection(file: CatalogueRecord.FileFields?,
                                  document: CatalogueRecord.DocumentFields?) -> Projection {
        var tokens: [String] = []
        if let date = value(document?.documentDate) {
            tokens += TagEditing.dateTokens(for: date.date)
            if date.uncertain { tokens.append("Date Uncertain") }
        }
        if let sentWith = value(document?.sentWith) {
            tokens.append(SentWithTag.token(for: sentWith.date))
            if sentWith.uncertain { tokens.append(SentWithTag.uncertainToken) }
        }
        for subject in value(document?.subjects) ?? [] where !subject.isEmpty && !tokens.contains(subject) {
            tokens.append(subject)
        }
        if let quality = DocumentTags.qualityTag(for: value(file?.quality)) { tokens.append(quality) }
        if let read = value(file?.readState),
           let state = ReadState.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(read) == .orderedSame }) {
            tokens.append(state.rawValue)
        }
        if let type = value(document?.itemType),
           let item = ItemType.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(type) == .orderedSame }) {
            tokens.append(item.tokenName)
        }
        if value(file?.ocrPoor) == true { tokens.append(DocumentTags.poorOCRTag) }
        if value(file?.ocrFailed) == true { tokens.append("OCR Failed") }
        let checks: [(CheckableField, Bool?)] = [
            (.date, document?.documentDate?.isChecked), (.sentWith, document?.sentWith?.isChecked),
            (.documentKind, document?.documentKind?.isChecked), (.title, document?.title?.isChecked),
            (.byline, document?.byline?.isChecked), (.publication, document?.publication?.isChecked),
            (.publicationDate, document?.publicationDate?.isChecked),
            (.recipientPlace, document?.recipientPlaces?.isChecked), (.sender, document?.senders?.isChecked),
            (.recipient, document?.recipients?.isChecked), (.sendingPlace, document?.sendingPlaces?.isChecked)
        ]
        tokens += checks.compactMap { $0.1 == true ? $0.0.token : nil }
        let label = value(file?.colour).flatMap { colour in
            FinderLabel.allCases.first { $0.tokenName.caseInsensitiveCompare(colour) == .orderedSame }
        }
        return Projection(tokens: tokens, label: label)
    }

    private static func value<V>(_ field: CatalogueRecord.Field<V>?) -> V? {
        if case .value(let value)? = field?.current { return value }
        return nil
    }

    // MARK: Ownership record

    /// What the suite wrote to one file's Finder tags, kept on the file.
    public struct Ledger: Codable, Equatable, Sendable {
        public static let version = 1
        /// `1`. A larger number is a newer build's record: read as unknown, never overwritten.
        public var v: Int
        /// Tokens the suite introduced and still answers for, with multiplicity.
        public var owned: [String]
        /// The colour label the suite set, if it set one.
        public var ownedLabel: Int?
        /// The file's whole tag list right after the suite's last write: what a Finder edit is measured against.
        public var baseline: [String]
        public var baselineLabel: Int?

        public init(owned: [String], ownedLabel: Int?, baseline: [String], baselineLabel: Int?) {
            v = Self.version
            self.owned = owned
            self.ownedLabel = ownedLabel
            self.baseline = baseline
            self.baselineLabel = baselineLabel
        }
    }

    /// Reading a file's ownership record.
    public enum LedgerState: Equatable, Sendable {
        /// The file carries none: nothing on it is the suite's.
        case none
        case recorded(Ledger)
        /// Present but not readable or not understood (a newer build's, or damaged). Nothing counts as owned,
        /// and nothing replaces it without a deliberate Re-publish.
        case unknown(String)

        public var ledger: Ledger? {
            if case .recorded(let ledger) = self { return ledger }
            return nil
        }
    }

    public static func readLedger(_ url: URL) -> LedgerState {
        switch FinderMirrorLedgerXattr.read(url) {
        case .absent: return .none
        case .failure(let why): return .unknown(why)
        case .data(let data):
            guard let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else {
                return .unknown("the ownership record is not readable")
            }
            guard ledger.v <= Ledger.version else { return .unknown("the ownership record is from a newer build") }
            return .recorded(ledger)
        }
    }

    // MARK: Divergence

    /// A mirrored tag changed outside the suite since its last write.
    public struct Divergence: Equatable, Sendable {
        /// Tokens the suite's last write left that are gone now.
        public var removed: [String]
        /// Vocabulary tokens that appeared since (a date, a rating, Read/Unread, a check…). Re-publish removes them.
        public var added: [String]
        /// Tags that appeared since and read as subjects: a subject typed in Finder or the user's own tag, which the
        /// suite cannot tell apart. Import adds them as subjects; Re-publish keeps them as the user's own tags.
        public var addedOther: [String] = []
        public var labelBefore: Int?
        public var labelAfter: Int?
        public var labelChanged: Bool { normalizedLabel(labelBefore) != normalizedLabel(labelAfter) }
        public var isEmpty: Bool { removed.isEmpty && added.isEmpty && addedOther.isEmpty && !labelChanged }
    }

    /// Whether `token` is one of the vocabulary's own facets rather than something a person might type.
    public static func isFacetToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if FinderLabel.isColourName(trimmed) { return true }
        if trimmed.caseInsensitiveCompare("OCR Failed") == .orderedSame { return true }
        if trimmed.caseInsensitiveCompare(DocumentTags.poorOCRTag) == .orderedSame { return true }
        return DocumentTags.parse(raw: [trimmed], labelNumber: nil).subjects.isEmpty
    }

    /// The divergence of `current` from the ledger's baseline. Nil when nothing the mirror answers for moved.
    /// A file with no ledger has no baseline, so it never diverges.
    public static func divergence(current: [String], label: Int?, ledger: Ledger?) -> Divergence? {
        guard let ledger else { return nil }
        let owned = ledger.owned
        let removed = multisetDifference(ledger.baseline, minus: current).filter { token in
            owned.contains(token) || isFacetToken(token)
        }
        let appeared = multisetDifference(current, minus: ledger.baseline)
        let added = appeared.filter(isFacetToken)
        let ownedLabelMoved = ledger.ownedLabel != nil
            && normalizedLabel(label) != normalizedLabel(ledger.baselineLabel)
        let divergence = Divergence(removed: removed, added: added, addedOther: appeared.filter { !isFacetToken($0) },
                                    labelBefore: ownedLabelMoved ? ledger.baselineLabel : nil,
                                    labelAfter: ownedLabelMoved ? label : nil)
        return divergence.isEmpty ? nil : divergence
    }

    // MARK: Applying a projection

    /// The tag list, label and ledger after projecting `projection` onto a file that carries `current`.
    /// Removes owned tokens the projection no longer wants (and, for Re-publish, `alsoRemove`), adds projected
    /// tokens the file lacks, and keeps everything else. A projected token already on the file stays unowned.
    /// A colour label the file already has and the suite did not set is always left; Re-publish replaces a label only
    /// when the suite had set it. A wanted token already on the file in another case keeps its ownership.
    public static func plan(current: [String], label: Int?, ledger: Ledger?, projection: Projection,
                            alsoRemove: [String] = [], republishing: Bool = false)
        -> (tags: [String], label: Int?, ledger: Ledger) {
        let suiteLabel = ledger?.ownedLabel
        let labelIsOurs = normalizedLabel(label) == 0
            || suiteLabel.map { normalizedLabel($0) == normalizedLabel(label) } == true
            || (republishing && suiteLabel != nil)
        let setsLabel = labelIsOurs ? projection.label : nil
        let clearsLabel = labelIsOurs && projection.label == nil && suiteLabel != nil && normalizedLabel(label) != 0
        let wanted = projection.tokens + (setsLabel.map { [$0.tokenName] } ?? [])
        var tags = current
        var owned: [String] = []
        for token in ledger?.owned ?? [] {
            guard let index = tags.firstIndex(of: token) else { continue }
            if wanted.contains(where: { isSameTag($0, token) }) { owned.append(token) } else { tags.remove(at: index) }
        }
        for token in alsoRemove where !wanted.contains(where: { isSameTag($0, token) }) {
            if let index = tags.firstIndex(of: token) { tags.remove(at: index) }
        }
        if labelIsOurs, setsLabel != nil || clearsLabel, let old = FinderLabel(labelNumber: label), old != setsLabel,
           let index = tags.firstIndex(of: old.tokenName) {
            tags.remove(at: index)
            owned.removeAll { $0 == old.tokenName }
        }
        for token in wanted where !tags.contains(where: { isSameTag($0, token) }) {
            tags.append(token)
            owned.append(token)
        }
        var newLabel = label
        var ownedLabel: Int?
        if let setsLabel {
            newLabel = setsLabel.rawValue
            ownedLabel = setsLabel.rawValue
        } else if clearsLabel {
            newLabel = nil
        }
        return (tags, newLabel, Ledger(owned: owned, ownedLabel: ownedLabel, baseline: tags, baselineLabel: newLabel))
    }

    // MARK: Writing

    public enum Outcome: Equatable, Sendable {
        /// The file now carries the projection; the result undoes the tag change.
        case published(TagWriteResult)
        /// A mirrored tag was changed outside the suite; nothing was written. Import or Re-publish decides.
        case diverged(Divergence)
        /// The ownership record is a newer build's or unreadable; nothing was written.
        case unknownLedger(String)
    }

    /// Project the record onto the file. Refuses, writing nothing, when the file diverged since the suite's
    /// last write, unless `republishing` (the user chose Re-publish, which puts the record's value back).
    public static func publish(_ url: URL, projection: Projection, expectedIdentity: FileIdentity? = nil,
                               republishing: Bool = false) throws -> Outcome {
        var refusal: Outcome?
        let result = try CoordinatedTagWriter.writeMirror(url, expectedIdentity: expectedIdentity) { current, label, state in
            let ledger: Ledger?
            switch state {
            case .recorded(let recorded): ledger = recorded
            case .none: ledger = nil
            case .unknown(let why):
                guard republishing else { refusal = .unknownLedger(why); return nil }
                ledger = nil
            }
            let divergence = divergence(current: current, label: label, ledger: ledger)
            if let divergence, !republishing {
                refusal = .diverged(divergence)
                return nil
            }
            // Re-publish removes the facet tokens that appeared, but a colour name only when the suite had set the label:
            // a colour the user chose in Finder over no colour of the suite's is theirs.
            let appeared = (divergence?.added ?? []).filter { !FinderLabel.isColourName($0) || ledger?.ownedLabel != nil }
            let planned = plan(current: current, label: label, ledger: ledger, projection: projection,
                               alsoRemove: republishing ? appeared : [], republishing: republishing)
            return .write(tags: planned.tags, label: planned.label, ledger: planned.ledger)
        }
        return refusal ?? .published(result)
    }

    /// What Remove Suite Tags took off one file, enough to put it back.
    public struct Removal: Codable, Equatable, Sendable {
        public let ledger: Ledger
        public let removed: [String]
        public let removedLabel: Int?
    }

    /// Remove only the tokens (and colour) this file's ledger says the suite wrote, then drop the ledger.
    /// Hand-made tags, and every tag on a file with no readable ledger, stay. Nil when nothing was the suite's.
    public static func removeSuiteTags(_ url: URL, expectedIdentity: FileIdentity? = nil) throws -> Removal? {
        var removal: Removal?
        _ = try CoordinatedTagWriter.writeMirror(url, expectedIdentity: expectedIdentity) { current, label, state in
            guard let ledger = state.ledger else { return nil }
            var tags = current
            var removed: [String] = []
            for token in ledger.owned {
                if let index = tags.firstIndex(of: token) { tags.remove(at: index); removed.append(token) }
            }
            var newLabel = label
            var removedLabel: Int?
            if let mine = ledger.ownedLabel, normalizedLabel(mine) == normalizedLabel(label) {
                newLabel = nil
                removedLabel = mine
            }
            removal = Removal(ledger: ledger, removed: removed, removedLabel: removedLabel)
            return .write(tags: tags, label: newLabel, ledger: nil)
        }
        return removal
    }

    /// Undo Remove Suite Tags on one file: put back each removed token the file lacks, and the colour if the
    /// file has none, and restore the ledger for what is back. Tags added since are kept.
    public static func restoreSuiteTags(_ url: URL, removal: Removal, expectedIdentity: FileIdentity? = nil) throws {
        _ = try CoordinatedTagWriter.writeMirror(url, expectedIdentity: expectedIdentity) { current, label, state in
            guard case .none = state else { return nil }
            var tags = current
            var owned: [String] = []
            let restoresLabel = removal.removedLabel != nil && normalizedLabel(label) == 0
            let colourToken = removal.removedLabel.flatMap { FinderLabel(labelNumber: $0) }?.tokenName
            for token in removal.removed where !tags.contains(where: { isSameTag($0, token) }) {
                if token == colourToken && !restoresLabel { continue }
                tags.append(token)
                owned.append(token)
            }
            var newLabel = label
            var ownedLabel: Int?
            if restoresLabel, let colour = removal.removedLabel {
                newLabel = colour
                ownedLabel = colour
            }
            return .write(tags: tags, label: newLabel,
                          ledger: Ledger(owned: owned, ownedLabel: ownedLabel, baseline: tags, baselineLabel: newLabel))
        }
    }

    /// Record the tags on a freshly produced file as the suite's own, except `excluding` (with multiplicity): for the
    /// Processor's working copy just before a mirrored filing, whose tags it wrote itself, less any its sources already
    /// carried. A file with an unknown ownership record is left alone. Tags are not changed.
    public static func claim(_ url: URL, excluding: [String]) throws {
        _ = try CoordinatedTagWriter.writeMirror(url) { current, label, state in
            if case .unknown = state { return nil }
            let owned = multisetDifference(current, minus: excluding)
            return .write(tags: current, label: label,
                          ledger: Ledger(owned: owned, ownedLabel: FinderLabel(labelNumber: label)
                                            .flatMap { owned.contains($0.tokenName) ? $0.rawValue : nil },
                                         baseline: current, baselineLabel: label))
        }
    }
}
