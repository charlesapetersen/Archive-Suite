import Foundation
import ArchiveCore

// ============================================================================================
//  TagWriter — THE SINGLE AUDITED WRITE CHOKE-POINT.
//
//  This is the ENTIRE write surface of Archive Reader. Every tag mutation — Read/Unread triage,
//  subject/date/priority edits, group edits — goes through here. It edits ONLY Finder-tag metadata
//  (the tag-name array + optionally the color label). It NEVER touches file bytes, and there is no
//  move / rename / delete / content-write anywhere in this file. See CLAUDE.md → Safety Protocol.
//
//  Guarantees (per apply()):
//   §1 coordinated, metadata-only write (never .forReplacing).
//   §2 fresh read INSIDE the coordinated block (no TOCTOU).
//   §3 trustworthy-read guard — a read failure ABORTS; it is never coerced into "no tags".
//   §5 lossless compute: new = (fresh − remove) + add, every untouched token preserved verbatim.
//   §7 label written only when the delta changes color; drift otherwise restored.
//   §8 verify by re-read — multiset equality (order-independent) + label check.
//   §9 no blind rollback; undo is the INVERSE DELTA (re-read + reconcile), never a stale restore.
//  UI-free so it can move into the shared ArchiveCore package (Archive Suite convergence).
// ============================================================================================

/// A precise, reversible edit to a file's Finder tags — the only shape of mutation the app performs.
struct TagDelta: Sendable, Equatable {
    /// Tokens to add (skipped if already present). Order preserved; appended after existing tokens.
    var add: [String] = []
    /// Tokens to remove (exact whole-string match; Read/Unread also match case-insensitively).
    var remove: [String] = []
    /// Optional Finder color-label change. Keeps the color *token* and the label number consistent.
    var color: ColorChange? = nil

    enum ColorChange: Sendable, Equatable {
        case set(ArchiveColor)   // box = Red(6) / folder = Purple(3)
        case clear               // label 0, and drop the color token matching the current label
        case restoreLabel(Int?)  // undo only: set the label verbatim WITHOUT touching the tag array
                                 // (the delta's add/remove already carries the exact token changes)
    }

    var isEmpty: Bool { add.isEmpty && remove.isEmpty && color == nil }
}

/// The outcome of a successful write, including the inverse delta needed to undo it safely.
struct TagWriteResult: Sendable, Equatable {
    let url: URL
    let before: [String]
    let after: [String]
    let beforeLabel: Int?
    let afterLabel: Int?
    /// Applying this delta through `TagWriter.apply` undoes this edit while preserving any concurrent
    /// third-party tag changes (it re-reads and reconciles rather than restoring a stale array).
    let inverse: TagDelta

    /// True when nothing actually changed (idempotent no-op).
    var isNoOp: Bool { before.sorted() == after.sorted() && normalized(beforeLabel) == normalized(afterLabel) }
}

enum TagWriteError: Error, Sendable, Equatable {
    case unreadable(String)          // current tags could not be read — refused (Safety §3)
    case verificationFailed(String)  // post-write re-read did not match the intended result
    case coordinationFailed(String)  // NSFileCoordinator could not obtain access
}

enum TagWriter {

    // MARK: Public API

    /// Apply a delta to one file's tags, safely. Returns the result (with an inverse for undo), or
    /// throws having made no lasting unintended change. An empty or no-effect delta writes nothing.
    static func apply(_ delta: TagDelta, to url: URL) throws -> TagWriteResult {
        try mutate(url) { current, label in
            var removals = delta.remove
            var additions = delta.add
            var targetLabel = label

            switch delta.color {
            case .set(let c):
                additions.append(c.tokenName)                          // keep the color token present
                // Drop the PREVIOUS color's token only if there really is a color label now — so a
                // subject literally "Red"/"Purple" (with no label) is never stripped.
                if let current = ArchiveColor(labelNumber: label ?? 0), current != c {
                    removals.append(current.tokenName)
                }
                targetLabel = c.labelNumber
            case .clear:
                if let current = ArchiveColor(labelNumber: label ?? 0) {
                    removals.append(current.tokenName)                 // remove only the token matching the actual label
                }
                targetLabel = 0
            case .restoreLabel(let lbl):
                targetLabel = lbl                                      // undo: label only; never touch tokens
            case nil:
                break
            }

            // §5 lossless compute — remove matched tokens, keep the rest verbatim & in place.
            var newTags = current.filter { token in
                !removals.contains { shouldRemove(token, matching: $0) }
            }
            // Append additions not already present (case-insensitive for Read/Unread).
            for add in additions where !newTags.contains(where: { isSameTag($0, add) }) {
                newTags.append(add)
            }

            if newTags == current && normalized(targetLabel) == normalized(label) { return nil } // no-op
            return (newTags, targetLabel)
        }
    }

    /// Apply the same delta to a group of files. Each file is an INDEPENDENT, idempotent unit — never
    /// all-or-nothing. Returns a per-file Result so the caller can surface partial failures; a file's
    /// row should leave a filtered view only after its own `.success`.
    static func apply(_ delta: TagDelta, to urls: [URL]) -> [(url: URL, result: Result<TagWriteResult, Error>)] {
        urls.map { url in (url, Result { try apply(delta, to: url) }) }
    }

    /// Fast-path triage: set Read/Unread by swapping the existing token.
    /// By default does NOT add a read-state token to a file that has none (protects box/folder
    /// markers, Safety §10); pass `addIfMissing: true` for an explicit "mark Read" on such files.
    static func setReadState(_ target: ReadState, on url: URL, addIfMissing: Bool = false) throws -> TagWriteResult {
        try mutate(url) { current, label in
            let hasReadState = current.contains { isReadStateWord($0) }
            guard hasReadState || addIfMissing else { return nil }         // marker/neither → no-op
            let alreadyTarget = current.contains { isSameTag($0, target.rawValue) }
            let hasOpposite = current.contains { isReadStateWord($0) && !isSameTag($0, target.rawValue) }
            if alreadyTarget && !hasOpposite { return nil }                // already in desired state
            var newTags = current.filter { !isReadStateWord($0) }
            newTags.append(target.rawValue)
            if newTags == current { return nil }
            return (newTags, label)                                        // never touches color
        }
    }

    // MARK: Core coordinated mutation

    /// The one place that writes tags. `transform` receives the FRESHLY-READ current state (inside the
    /// coordination block) and returns the intended new state, or nil for a no-op. Everything else —
    /// the trustworthy-read guard, the write, verification, drift restore, and inverse derivation —
    /// is enforced here so no caller can bypass it.
    private static func mutate(
        _ url: URL,
        transform: ([String], Int?) -> ([String], Int?)?
    ) throws -> TagWriteResult {
        let box = ResultBox()
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .contentIndependentMetadataOnly, error: &coordError) { writeURL in
            do {
                // §2/§3 fresh read inside coordination; a read FAILURE aborts (never treated as empty).
                let before: [String]
                let beforeLabel: Int?
                do {
                    let rv = try writeURL.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
                    before = rv.tagNames ?? []
                    beforeLabel = rv.labelNumber
                } catch {
                    throw TagWriteError.unreadable(error.localizedDescription)
                }

                guard let (intendedTags, intendedLabel) = transform(before, beforeLabel) else {
                    box.result = TagWriteResult(url: url, before: before, after: before,
                                                beforeLabel: beforeLabel, afterLabel: beforeLabel,
                                                inverse: TagDelta())
                    return
                }

                // Write the tag array. Write the label ONLY when we intend to change it (§7).
                try (writeURL as NSURL).setResourceValue(intendedTags, forKey: .tagNamesKey)
                if normalized(intendedLabel) != normalized(beforeLabel) {
                    try (writeURL as NSURL).setResourceValue(intendedLabel ?? 0, forKey: .labelNumberKey)
                }

                // §8 verify by re-read.
                var (after, afterLabel) = try readPair(writeURL)

                // §7 label-drift defense: if we did NOT intend a color change but the label drifted
                // (e.g. from rewriting the tag array), restore the original label.
                if normalized(intendedLabel) == normalized(beforeLabel), normalized(afterLabel) != normalized(beforeLabel) {
                    try (writeURL as NSURL).setResourceValue(beforeLabel ?? 0, forKey: .labelNumberKey)
                    (after, afterLabel) = try readPair(writeURL)
                }

                guard multisetEqual(after, intendedTags) else {
                    throw TagWriteError.verificationFailed("tag mismatch — expected \(intendedTags.sorted()) got \(after.sorted())")
                }
                let expectedLabel = normalized(intendedLabel) != normalized(beforeLabel) ? intendedLabel : beforeLabel
                guard normalized(afterLabel) == normalized(expectedLabel) else {
                    throw TagWriteError.verificationFailed("label mismatch — expected \(String(describing: expectedLabel)) got \(String(describing: afterLabel))")
                }

                // §9 inverse delta (re-adds what we removed, removes what we added, restores color).
                let beforeSet = Set(before), afterSet = Set(after)
                // The token diff alone carries token changes; color is restored as a LABEL-ONLY op so
                // undo can never add/remove a token the forward op didn't touch (Safety §9), and any
                // original label value (not just 0/3/6) is restored verbatim.
                let inverse = TagDelta(
                    add: Array(beforeSet.subtracting(afterSet)),
                    remove: Array(afterSet.subtracting(beforeSet)),
                    color: normalized(afterLabel) != normalized(beforeLabel) ? .restoreLabel(beforeLabel) : nil
                )
                box.result = TagWriteResult(url: url, before: before, after: after,
                                            beforeLabel: beforeLabel, afterLabel: afterLabel, inverse: inverse)
            } catch {
                box.error = error
            }
        }
        if let coordError { throw TagWriteError.coordinationFailed(coordError.localizedDescription) }
        if let error = box.error { throw error }
        guard let result = box.result else { throw TagWriteError.coordinationFailed("coordination block did not run") }
        return result
    }

    // MARK: Helpers

    private static func readPair(_ url: URL) throws -> ([String], Int?) {
        let rv = try url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
        return (rv.tagNames ?? [], rv.labelNumber)
    }

    private static func isReadStateWord(_ s: String) -> Bool {
        s.caseInsensitiveCompare(ReadState.read.rawValue) == .orderedSame
            || s.caseInsensitiveCompare(ReadState.unread.rawValue) == .orderedSame
    }

    /// Two tokens are "the same" for add-dedup: exact match, or case-insensitive for Read/Unread only.
    private static func isSameTag(_ a: String, _ b: String) -> Bool {
        a == b || (isReadStateWord(b) && a.caseInsensitiveCompare(b) == .orderedSame)
    }

    /// A token should be removed if it exactly equals the target, or (for Read/Unread) matches it
    /// case-insensitively. Never substring — removing "Unread" never disturbs a subject "Read later".
    private static func shouldRemove(_ token: String, matching target: String) -> Bool {
        token == target || (isReadStateWord(target) && token.caseInsensitiveCompare(target) == .orderedSame)
    }

    private static func multisetEqual(_ a: [String], _ b: [String]) -> Bool { a.sorted() == b.sorted() }

    /// A small reference box so the synchronous coordination closure can hand results back out.
    private final class ResultBox { var result: TagWriteResult?; var error: Error? }
}

/// nil and 0 both mean "no color label"; normalize so they compare equal.
private func normalized(_ label: Int?) -> Int { label ?? 0 }
